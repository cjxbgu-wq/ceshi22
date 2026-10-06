#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>
#import <VideoToolbox/VideoToolbox.h>
#import <QuartzCore/QuartzCore.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <math.h>
#import <string.h>
#import <stdlib.h>
#import <pthread.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>
#import "QMEnhancerView.h"

// ============================================================
//  日志（保持原样）
// ============================================================
static NSString *gVLOGPath = nil;
static pthread_mutex_t gVLOGLock = PTHREAD_MUTEX_INITIALIZER;

static void VLOGInit(void) {
    if (gVLOGPath) return;
    NSString *proc = [[NSProcessInfo processInfo] processName];
    gVLOGPath = [[NSString alloc] initWithFormat:@"/tmp/vcam_enhancer_%@.log", proc];
    [@"" writeToFile:gVLOGPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

#define VLOG(fmt, ...) do { \
    NSString *__s = [NSString stringWithFormat:(fmt), ##__VA_ARGS__]; \
    NSLog(@"[VCamEnhancer] %@", __s); \
    pthread_mutex_lock(&gVLOGLock); \
    if (!gVLOGPath) VLOGInit(); \
    NSString *__old = [NSString stringWithContentsOfFile:gVLOGPath encoding:NSUTF8StringEncoding error:nil]; \
    NSString *__new = [NSString stringWithFormat:@"%@%@\n", __old ?: @"", __s]; \
    [__new writeToFile:gVLOGPath atomically:YES encoding:NSUTF8StringEncoding error:nil]; \
    pthread_mutex_unlock(&gVLOGLock); \
} while(0)

// ============ 路径常量（保持原样）============
static NSString *const VPMSharedSettingsPath = @"/var/mobile/Media/DCIM/vc.plist";
static NSString *const VPMMediaDir           = @"/var/mobile/Media/DCIM";
static NSString *const VPMRotationKey        = @"videoRotationLV";
static NSString *const VPMScaleKey           = @"videoScaleLV";
static NSString *const VPMEnabledKey         = @"enabled";
static NSString *const VPMMediaPathKey       = @"mediaPath";

static void VPMEnsureDir(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:VPMMediaDir]) {
        NSError *err = nil;
        [fm createDirectoryAtPath:VPMMediaDir
      withIntermediateDirectories:YES attributes:nil error:&err];
        if (err) VLOG(@"建目录失败: %@", err);
    }
}

static NSDictionary *VPMReadSettings(void) {
    @try {
        NSDictionary *s = [NSDictionary dictionaryWithContentsOfFile:VPMSharedSettingsPath];
        return s ?: @{};
    } @catch (NSException *e) {}
    return @{};
}
static NSInteger VPMReadRotation(void) {
    NSInteger r = [[VPMReadSettings() objectForKey:VPMRotationKey] integerValue];
    return (r == 90 || r == 180 || r == 270) ? r : 0;
}
static CGFloat VPMReadScale(void) {
    CGFloat s = [[VPMReadSettings() objectForKey:VPMScaleKey] floatValue];
    return (s > 0.05f && s < 20.0f) ? s : 1.0f;
}

// ============================================================
//  【新增】LocalVideoPlayer — VCam 底座（内嵌，不新增文件）
//  提供 Tweak 里的帧钩子/桥接所需的类与方法
// ============================================================
@interface LocalVideoPlayer : NSObject
@property (nonatomic, copy)   NSString *mediaPath;
@property (nonatomic, strong) AVAssetReader *reader;
@property (nonatomic, strong) AVAssetReaderTrackOutput *output;
@property (nonatomic)         CVBufferRef currentPixelBuffer;
@property (nonatomic, strong) NSLock *lock;
@property (nonatomic, strong) dispatch_queue_t decodeQueue;
@property (nonatomic)         BOOL playing;
@property (nonatomic)         BOOL isVideo;
@property (nonatomic)         BOOL shouldStop;
@end

@implementation LocalVideoPlayer

+ (instancetype)shared {
    static LocalVideoPlayer *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [LocalVideoPlayer new]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _lock = [NSLock new];
        _decodeQueue = dispatch_queue_create("com.qianmian.vcam.decode", DISPATCH_QUEUE_SERIAL);
        _playing = NO;
        _shouldStop = NO;
    }
    return self;
}

- (void)dealloc {
    [self stop];
    if (_currentPixelBuffer) { CVPixelBufferRelease(_currentPixelBuffer); _currentPixelBuffer = NULL; }
}

#pragma mark - 加载入口（桥接调用）

- (void)loadMediaAtPath:(NSString *)path completion:(void (^)(BOOL))completion {
    if (!path.length) { if (completion) completion(NO); return; }
    NSString *ext = path.pathExtension.lowercaseString;

    if ([ext isEqualToString:@"jpg"] || [ext isEqualToString:@"jpeg"] ||
        [ext isEqualToString:@"png"] || [ext isEqualToString:@"gif"] ||
        [ext isEqualToString:@"heic"]) {
        [self loadImageAtPath:path completion:completion];
        return;
    }
    if ([ext isEqualToString:@"mp4"] || [ext isEqualToString:@"mov"] ||
        [ext isEqualToString:@"m4v"]) {
        [self loadVideoAtPath:path completion:completion];
        return;
    }

    // 无扩展名（vcam_slot_N）: 读文件头判断
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!fh) { VLOG(@"媒体文件不存在: %@", path); if (completion) completion(NO); return; }
    NSData *head = [fh readDataOfLength:12];
    [fh closeFile];
    const uint8_t *b = head.bytes;
    if (head.length >= 12) {
        if (b[4]=='f'&&b[5]=='t'&&b[6]=='y'&&b[7]=='p') { [self loadVideoAtPath:path completion:completion]; return; }
        if (b[0]==0xFF&&b[1]==0xD8&&b[2]==0xFF)          { [self loadImageAtPath:path completion:completion]; return; }
        if (b[0]==0x89&&b[1]==0x50&&b[2]==0x4E&&b[3]==0x47){ [self loadImageAtPath:path completion:completion]; return; }
    }
    VLOG(@"不支持的媒体格式: %@", path);
    if (completion) completion(NO);
}

- (void)loadVideoAtPath:(NSString *)path completion:(void (^)(BOOL))completion {
    VLOG(@"loadVideoAtPath: %@", path);
    [self stop];
    _mediaPath = [path copy];
    _isVideo = YES;

    __weak typeof(self) ws = self;
    dispatch_async(_decodeQueue, ^{
        typeof(ws) ss = ws;
        if (!ss) { if (completion) completion(NO); return; }
        [ss setupVideoReader:ss.mediaPath];
        BOOL ok = (ss.reader != nil);
        if (ok) [ss play];
        VLOG(@"视频加载完成: %@ -> %@", path, ok ? @"OK" : @"FAIL");
        if (completion) completion(ok);
    });
}

- (void)setupVideoReader:(NSString *)path {
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path]
                                            options:@{AVURLAssetPreferPreciseDurationAndTimingKey: @YES}];
    NSError *err = nil;
    AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset error:&err];
    if (!reader || err) { VLOG(@"reader 创建失败: %@", err); return; }
    NSArray *tracks = [asset tracksWithMediaType:AVMediaTypeVideo];
    if (!tracks.count) { VLOG(@"无视频轨"); return; }
    AVAssetTrack *track = tracks.firstObject;

    NSDictionary *settings = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
    AVAssetReaderTrackOutput *output =
        [[AVAssetReaderTrackOutput alloc] initWithTrack:track outputSettings:settings];
    output.alwaysCopiesSampleData = YES;
    if (![reader canAddOutput:output]) return;
    [reader addOutput:output];
    if (![reader startReading]) return;

    _reader = reader;
    _output = output;
}

- (void)loadImageAtPath:(NSString *)path completion:(void (^)(BOOL))completion {
    VLOG(@"loadImageAtPath: %@", path);
    [self stop];
    _mediaPath = [path copy];
    _isVideo = NO;

    CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], NULL);
    if (!src) { if (completion) completion(NO); return; }
    CGImageRef img = CGImageSourceCreateImageAtIndex(src, 0, NULL);
    CFRelease(src);
    if (!img) { if (completion) completion(NO); return; }

    size_t w = CGImageGetWidth(img), h = CGImageGetHeight(img);
    NSDictionary *attrs = @{
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (id)kCVPixelBufferMetalCompatibilityKey: @YES,
    };
    CVPixelBufferRef pb = NULL;
    CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA,
                        (__bridge CFDictionaryRef)attrs, &pb);
    if (pb) {
        CVPixelBufferLockBaseAddress(pb, 0);
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGContextRef ctx = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(pb), w, h, 8,
                                                 CVPixelBufferGetBytesPerRow(pb), cs,
                                                 kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
        if (ctx) {
            CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), img);
            CGContextRelease(ctx);
        }
        CGColorSpaceRelease(cs);
        CVPixelBufferUnlockBaseAddress(pb, 0);
        [self updateCurrentBuffer:pb];
        CVPixelBufferRelease(pb);
    }
    CGImageRelease(img);
    VLOG(@"图片加载完成: %@ (%zux%zu)", path, w, h);
    if (completion) completion(YES);
}

#pragma mark - 播放

- (void)play {
    if (!_isVideo || !_reader) return;
    if (_playing) return;
    _playing = YES;
    _shouldStop = NO;

    __weak typeof(self) ws = self;
    dispatch_async(_decodeQueue, ^{
        typeof(ws) ss = ws;
        if (!ss) return;
        while (ss.playing && !ss.shouldStop) {
            if (![ss decodeOneFrame]) {
                VLOG(@"视频循环播放");
                [ss setupVideoReader:ss.mediaPath];
                if (!ss.reader) { ss.playing = NO; break; }
            }
        }
        VLOG(@"解码线程退出");
    });
}

- (void)pause {
    _playing = NO;
}

- (void)stop {
    _playing = NO;
    _shouldStop = YES;
    if (_reader) {
        if (_reader.status == AVAssetReaderStatusReading) [_reader cancelReading];
        _reader = nil;
    }
    _output = nil;
}

- (BOOL)decodeOneFrame {
    if (!_output) return NO;
    CMSampleBufferRef sb = [_output copyNextSampleBuffer];
    if (!sb) return NO;
    CVImageBufferRef pb = CMSampleBufferGetImageBuffer(sb);
    if (pb) [self updateCurrentBuffer:pb];
    CFRelease(sb);
    return YES;
}

// 帧钩子挂载点（会被本文件的 VPMUpdateCurrentBufferHook 包裹）
- (void)updateCurrentBuffer:(CVBufferRef)buffer {
    if (!buffer) return;
    [_lock lock];
    if (buffer != _currentPixelBuffer) {
        CVPixelBufferRetain(buffer);
        if (_currentPixelBuffer) CVPixelBufferRelease(_currentPixelBuffer);
        _currentPixelBuffer = buffer;
    }
    [_lock unlock];
}

- (CVBufferRef)currentFrame {
    [_lock lock];
    CVBufferRef f = _currentPixelBuffer;
    [_lock unlock];
    return f;
}

@end

// ============================================================
//  【新增】相机管线替换（内嵌，不新增文件）
//  在 mediaserverd 里 hook BWNodeOutput.emitSampleBuffer:
//  把 LocalVideoPlayer.currentFrame 就地 transfer 进相机 buffer
// ============================================================
static VTPixelTransferSessionRef gQMPipelineTransfer = NULL;
static void (*origQMEmitSampleBuffer)(id, SEL, CMSampleBufferRef) = NULL;
static volatile int64_t gQMPipelineFrames = 0;

static void QMPipelineEmitHook(id self, SEL _cmd, CMSampleBufferRef sb) {
    @try {
        if (sb) {
            CVImageBufferRef cameraBuf = CMSampleBufferGetImageBuffer(sb);
            LocalVideoPlayer *p = [LocalVideoPlayer shared];
            CVBufferRef replaceBuf = p ? [p currentFrame] : NULL;
            if (cameraBuf && replaceBuf) {
                if (!gQMPipelineTransfer) {
                    VTPixelTransferSessionCreate(kCFAllocatorDefault, &gQMPipelineTransfer);
                    if (gQMPipelineTransfer) {
                        VTSessionSetProperty(gQMPipelineTransfer,
                            kVTPixelTransferPropertyKey_ScalingMode, kVTScalingMode_Trim);
                    }
                }
                if (gQMPipelineTransfer) {
                    OSStatus s = VTPixelTransferSessionTransferImage(gQMPipelineTransfer,
                                                                     replaceBuf, cameraBuf);
                    int64_t n = __sync_add_and_fetch(&gQMPipelineFrames, 1);
                    if (n == 1) {
                        VLOG(@"✅ 相机管线首帧替换 (%zux%zu)",
                             CVPixelBufferGetWidth(cameraBuf), CVPixelBufferGetHeight(cameraBuf));
                    }
                    if (s != noErr && n <= 5) {
                        uint32_t sf = CVPixelBufferGetPixelFormatType(replaceBuf);
                        uint32_t df = CVPixelBufferGetPixelFormatType(cameraBuf);
                        VLOG(@"⚠️ transfer 失败 %d (src 0x%X dst 0x%X)", (int)s, sf, df);
                    }
                }
            }
        }
    } @catch (NSException *e) {
        VLOG(@"相机管线异常: %@", e);
    }
    if (origQMEmitSampleBuffer) origQMEmitSampleBuffer(self, _cmd, sb);
}

static BOOL gQMPipelineInstalled = NO;
static void QMPipelineInstall(void) {
    if (gQMPipelineInstalled) return;
    @try {
        Class cls = NSClassFromString(@"BWNodeOutput");
        if (!cls) {
            VLOG(@"⚠️ BWNodeOutput 类未出现，10s 后重试");
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)),
                           dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                QMPipelineInstall();
            });
            return;
        }
        Method m = class_getInstanceMethod(cls, @selector(emitSampleBuffer:));
        if (!m) {
            VLOG(@"⚠️ emitSampleBuffer: 方法未找到");
            return;
        }
        IMP orig = method_getImplementation(m);
        if (orig == (IMP)QMPipelineEmitHook) { gQMPipelineInstalled = YES; return; }
        origQMEmitSampleBuffer = (void (*)(id, SEL, CMSampleBufferRef))orig;
        method_setImplementation(m, (IMP)QMPipelineEmitHook);
        gQMPipelineInstalled = YES;
        VLOG(@"✅ 相机管线钩子已安装 (BWNodeOutput.emitSampleBuffer:)");
    } @catch (NSException *e) {
        VLOG(@"❌ 相机管线安装异常: %@", e);
    }
}

// ============================================================
//  帧处理（保持原样，一行不动）
// ============================================================
static uint8_t *gRotSnap = NULL;
static size_t   gRotSnapCap = 0;

static void VPMRotateDirectionInPlace(CVBufferRef buf, NSInteger rot, CGFloat scale) {
    if (!buf || (rot == 0 && fabs(scale - 1.0f) < 0.01f)) return;
    @try {
        size_t w = CVPixelBufferGetWidth(buf);
        size_t h = CVPixelBufferGetHeight(buf);
        if (w == 0 || h == 0) return;
        if (CVPixelBufferGetPixelFormatType(buf) != kCVPixelFormatType_32BGRA) return;
        CVPixelBufferLockBaseAddress(buf, 0);
        uint8_t *base = (uint8_t *)CVPixelBufferGetBaseAddress(buf);
        size_t bpr = CVPixelBufferGetBytesPerRow(buf);
        if (!base || bpr == 0) { CVPixelBufferUnlockBaseAddress(buf, 0); return; }

        size_t need = h * bpr;
        static dispatch_once_t lockOnce;
        static id rotLock = nil;
        dispatch_once(&lockOnce, ^{ rotLock = [NSObject new]; });
        @synchronized (rotLock) {
            if (gRotSnapCap < need) {
                free(gRotSnap);
                gRotSnap = (uint8_t *)malloc(need);
                gRotSnapCap = gRotSnap ? need : 0;
            }
            if (!gRotSnap) { CVPixelBufferUnlockBaseAddress(buf, 0); return; }
            memcpy(gRotSnap, base, need);

            CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
            CGDataProviderRef prov = CGDataProviderCreateWithData(NULL, gRotSnap, need, NULL);
            CGImageRef img = CGImageCreate((size_t)w, (size_t)h, 8, 32, bpr, cs,
                                           kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little,
                                           prov, NULL, false, kCGRenderingIntentDefault);
            CGContextRef ctx = CGBitmapContextCreate(base, (size_t)w, (size_t)h, 8, bpr, cs,
                                                     kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
            if (img && ctx) {
                CGFloat ww = (CGFloat)w, hh = (CGFloat)h;
                CGContextSetRGBFillColor(ctx, 0, 0, 0, 1);
                CGContextFillRect(ctx, CGRectMake(0, 0, ww, hh));
                CGContextTranslateCTM(ctx, 0, hh);
                CGContextScaleCTM(ctx, 1, -1);
                CGContextTranslateCTM(ctx, ww / 2.0, hh / 2.0);
                NSInteger rr = ((rot % 360) + 360) % 360;
                if (rr) CGContextRotateCTM(ctx, -(CGFloat)rr * (CGFloat)M_PI / 180.0f);
                if (scale > 0 && fabs(scale - 1.0f) > 0.01f)
                    CGContextScaleCTM(ctx, scale, scale);
                CGFloat ew = (rr == 90 || rr == 270) ? hh : ww;
                CGFloat eh = (rr == 90 || rr == 270) ? ww : hh;
                CGFloat vw = ww, vh = hh;
                CGFloat s = MIN(ew / vw, eh / vh);
                CGFloat dw = vw * s, dh = vh * s;
                CGContextDrawImage(ctx, CGRectMake(-dw / 2.0, -dh / 2.0, dw, dh), img);
                CGContextFlush(ctx);
            }
            if (ctx) CFRelease(ctx);
            if (img) CFRelease(img);
            if (prov) CFRelease(prov);
            CFRelease(cs);
        }
        CVPixelBufferUnlockBaseAddress(buf, 0);
    } @catch (NSException *e) {}
}

// ============================================================
//  帧钩子（保持原样）
// ============================================================
static void (*origUpdateCurrentBuffer)(id, SEL, CVBufferRef) = NULL;
static volatile int64_t VPMFramesSeen = 0;

static void VPMUpdateCurrentBufferHook(id self, SEL _cmd, CVBufferRef buffer) {
    @try {
        int64_t seen = __sync_add_and_fetch(&VPMFramesSeen, 1);
        if (seen == 1 && buffer) {
            VLOG(@"帧钩子首帧 %zux%zu",
                 CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer));
        }
        static NSInteger cachedRot = -1;
        static CGFloat   cachedScale = -1.0;
        static double    lastRead = 0;
        double now = [NSDate timeIntervalSinceReferenceDate];
        if (cachedRot < 0 || cachedScale < 0 || (now - lastRead) > 0.5) {
            cachedRot   = VPMReadRotation();
            cachedScale = VPMReadScale();
            lastRead    = now;
        }
        if ((cachedRot != 0 || fabs(cachedScale - 1.0f) > 0.01f) && buffer) {
            VPMRotateDirectionInPlace(buffer, cachedRot, cachedScale);
        }
        if (origUpdateCurrentBuffer) origUpdateCurrentBuffer(self, _cmd, buffer);
    } @catch (NSException *e) {
        if (origUpdateCurrentBuffer) origUpdateCurrentBuffer(self, _cmd, buffer);
    }
}

static BOOL VPMClassOwnsMethod(Class cls, SEL sel) {
    if (!cls || !sel) return NO;
    unsigned int count = 0;
    Method *list = class_copyMethodList(cls, &count);
    BOOL owns = NO;
    for (unsigned int i = 0; i < count; i++) {
        if (sel_isEqual(method_getName(list[i]), sel)) { owns = YES; break; }
    }
    if (list) free(list);
    return owns;
}

static BOOL VPMFrameInstalled = NO;
static void VPMInstallFrameHook(void) {
    if (VPMFrameInstalled) return;
    @try {
        Class lvp = NSClassFromString(@"LocalVideoPlayer");
        if (!lvp) { VLOG(@"⚠️ LocalVideoPlayer 类不存在，等下次"); return; }
        if (!VPMClassOwnsMethod(lvp, @selector(updateCurrentBuffer:))) {
            VLOG(@"⚠️ LocalVideoPlayer 未直接实现 updateCurrentBuffer:，跳过");
            return;
        }
        Method m = class_getInstanceMethod(lvp, @selector(updateCurrentBuffer:));
        if (!m) { VLOG(@"⚠️ updateCurrentBuffer: 方法不存在"); return; }
        IMP orig = method_getImplementation(m);
        if (orig == (IMP)VPMUpdateCurrentBufferHook) { VPMFrameInstalled = YES; return; }
        origUpdateCurrentBuffer = (void (*)(id, SEL, CVBufferRef))orig;
        method_setImplementation(m, (IMP)VPMUpdateCurrentBufferHook);
        VPMFrameInstalled = YES;
        VLOG(@"✅ 帧钩子已安装");
    } @catch (NSException *e) {
        VLOG(@"❌ 帧钩子安装异常: %@", e);
    }
}

// ============================================================
//  桥接（保持原样）
// ============================================================
typedef void (^VLCompletion)(BOOL);
static VLCompletion gNoopCompletion = NULL;
static dispatch_source_t gBridgeTimer = NULL;
static NSString *gLastBridgedPath = nil;
static BOOL gLastEnabled = YES;
static BOOL gHasLastEnabled = NO;

static void VPMEnsureNoopBlock(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gNoopCompletion = [^(BOOL ok){ (void)ok; } copy];
    });
}

static void VPMPlayerStop(void) {
    Class cls = NSClassFromString(@"LocalVideoPlayer");
    if (!cls || ![cls respondsToSelector:@selector(shared)]) return;
    id player = ((id(*)(id,SEL))objc_msgSend)(cls, @selector(shared));
    if (!player) return;
    if ([player respondsToSelector:@selector(stop)]) {
        ((void(*)(id,SEL))objc_msgSend)(player, @selector(stop));
        VLOG(@"🔇 桥接: 已调原版 stop");
    }
}

static void VPMBridgeTryLoad(NSString *path) {
    if (!path.length) return;
    Class cls = NSClassFromString(@"LocalVideoPlayer");
    if (!cls) { VLOG(@"⚠️ 桥接: LocalVideoPlayer 类不存在"); return; }

    id player = nil;
    if ([cls respondsToSelector:@selector(shared)]) {
        player = ((id(*)(id,SEL))objc_msgSend)(cls, @selector(shared));
    }
    if (!player) { VLOG(@"⚠️ 桥接: shared 返回 nil"); return; }

    VPMEnsureNoopBlock();

    NSArray<NSString *> *candidates = @[
        @"loadMediaAtPath:completion:",
        @"loadVideoAtPath:completion:",
        @"loadImageAtPath:completion:"
    ];

    for (NSString *name in candidates) {
        SEL sel = NSSelectorFromString(name);
        if (![player respondsToSelector:sel]) continue;
        @try {
            ((void(*)(id, SEL, NSString*, VLCompletion))objc_msgSend)(player, sel, path, gNoopCompletion);
            VLOG(@"📤 桥接已调用 %@ -> %@", name, path);
            if ([player respondsToSelector:@selector(play)]) {
                ((void(*)(id,SEL))objc_msgSend)(player, @selector(play));
            }
            return;
        } @catch (NSException *e) {
            VLOG(@"❌ 桥接 %@ 异常: %@", name, e);
        }
    }
    VLOG(@"⚠️ 桥接: LocalVideoPlayer 上没有可用的 loadXXX 方法");
}

static void VPMStartBridgePolling(void) {
    if (gBridgeTimer) return;
    VPMEnsureDir();
    dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
    gBridgeTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    dispatch_source_set_timer(gBridgeTimer,
                              dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC),
                              1 * NSEC_PER_SEC,
                              (uint64_t)(0.2 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(gBridgeTimer, ^{
        @autoreleasepool {
            NSDictionary *s = VPMReadSettings();

            NSNumber *en = s[VPMEnabledKey];
            BOOL enabled = en ? [en boolValue] : YES;
            if (!gHasLastEnabled) {
                gHasLastEnabled = YES;
                gLastEnabled = enabled;
            } else if (enabled != gLastEnabled) {
                gLastEnabled = enabled;
                if (!enabled) {
                    VPMPlayerStop();
                } else {
                    gLastBridgedPath = nil;
                }
            }

            NSString *path = s[VPMMediaPathKey];
            if (!path.length) return;
            if ([path isEqualToString:gLastBridgedPath ?: @""]) return;
            gLastBridgedPath = [path copy];
            VPMBridgeTryLoad(path);
        }
    });
    dispatch_resume(gBridgeTimer);
    VLOG(@"✅ 桥接轮询已启动");
}

// ============================================================
//  引导（保持原样）
// ============================================================
static void VPMScheduleBootstrap(int attempt) {
    if (VPMFrameInstalled) return;
    if (attempt > 60) {
        VLOG(@"⚠️ 引导超时：LocalVideoPlayer 60 秒内未出现");
        return;
    }
    Class lvClass = NSClassFromString(@"LocalVideoPlayer");
    if (lvClass) {
        VLOG(@"✅ 引导成功（第 %d 次）", attempt);
        VPMInstallFrameHook();
        VPMStartBridgePolling();
        return;
    }
    if (attempt == 0 || attempt % 10 == 0) {
        VLOG(@"⏳ 引导第 %d 次：类未出现", attempt);
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        VPMScheduleBootstrap(attempt + 1);
    });
}

// ============================================================
//  SpringBoard 启动后 → 显示悬浮球（保持原样）
// ============================================================
%hook SpringBoard

- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    VLOG(@"SpringBoard 启动完成");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [[QMFloatBall shared] show];
    });
}

%end

// ============================================================
//  %ctor
// ============================================================
%ctor {
    @autoreleasepool {
        VLOGInit();

        NSString *proc = [[NSProcessInfo processInfo] processName];
        VLOG(@"========================================");
        VLOG(@"VCamEnhancer dylib 已加载，进程=%@", proc);

        VPMEnsureDir();

        Class lvClass = NSClassFromString(@"LocalVideoPlayer");
        VLOG(@"LocalVideoPlayer: %@", lvClass ? @"存在" : @"不存在");
        VLOG(@"========================================");

        // 【新增】mediaserverd 内安装相机管线替换 hook
        if ([proc isEqualToString:@"mediaserverd"]) {
            QMPipelineInstall();
        }

        VPMScheduleBootstrap(0);
    }
}
