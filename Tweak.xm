#pragma clang diagnostic ignored "-Wunguarded-availability-new"

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>
#import <VideoToolbox/VideoToolbox.h>
#import <QuartzCore/QuartzCore.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
#import <math.h>
#import <string.h>
#import <stdlib.h>
#import <pthread.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>
#import "QMEnhancerView.h"

// ============================================================
//  日志
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

// ============ 路径 ============
static NSString *const VPMSharedSettingsPath = @"/var/mobile/Library/Caches/com.apple.mediaserverd/vc.plist";
static NSString *const VPMMediaDir           = @"/var/mobile/Library/Caches/com.apple.mediaserverd";
static NSString *const VPMRotationKey        = @"videoRotationLV";
static NSString *const VPMScaleKey           = @"videoScaleLV";
static NSString *const VPMEnabledKey         = @"enabled";
static NSString *const VPMMediaPathKey       = @"mediaPath";

static void VPMEnsureDir(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:VPMMediaDir]) {
        [fm createDirectoryAtPath:VPMMediaDir withIntermediateDirectories:YES attributes:nil error:nil];
    }
    [fm setAttributes:@{NSFilePosixPermissions: @0777} ofItemAtPath:VPMMediaDir error:nil];
}

static NSDictionary *VPMReadSettings(void) {
    @try {
        NSDictionary *s = [NSDictionary dictionaryWithContentsOfFile:VPMSharedSettingsPath];
        return s ?: @{};
    } @catch (NSException *e) {}
    return @{};
}

// ★ 缓存 enabled（每 0.5s 刷新），避免每帧读文件
static BOOL gCachedEnabled = YES;
static double gLastEnabledRead = 0;
static BOOL VPMReadEnabled(void) {
    double now = [NSDate timeIntervalSinceReferenceDate];
    if (now - gLastEnabledRead > 0.5) {
        NSNumber *n = VPMReadSettings()[VPMEnabledKey];
        gCachedEnabled = n ? [n boolValue] : YES;
        gLastEnabledRead = now;
    }
    return gCachedEnabled;
}

static NSInteger VPMReadRotation(void) {
    NSInteger r = [VPMReadSettings()[VPMRotationKey] integerValue];
    return (r == 90 || r == 180 || r == 270) ? r : 0;
}
static CGFloat VPMReadScale(void) {
    CGFloat s = [VPMReadSettings()[VPMScaleKey] floatValue];
    return (s > 0.05f && s < 20.0f) ? s : 1.0f;
}

// ============================================================
//  【内嵌】LocalVideoPlayer
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

+ (instancetype)shared;
- (void)updateCurrentBuffer:(CVBufferRef)buffer;
- (void)clearCurrentBuffer;
- (void)loadMediaAtPath:(NSString *)path completion:(void (^)(BOOL success))completion;
- (void)loadVideoAtPath:(NSString *)path completion:(void (^)(BOOL success))completion;
- (void)loadImageAtPath:(NSString *)path completion:(void (^)(BOOL success))completion;
- (void)play;
- (void)pause;
- (void)stop;
- (CVBufferRef)currentFrame;
- (void)setupVideoReader:(NSString *)path;
- (BOOL)decodeOneFrame;
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
    }
    return self;
}

- (void)dealloc {
    [self stop];
    if (_currentPixelBuffer) { CVPixelBufferRelease(_currentPixelBuffer); _currentPixelBuffer = NULL; }
}

#pragma mark - 加载

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
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!fh) { if (completion) completion(NO); return; }
    NSData *head = [fh readDataOfLength:12];
    [fh closeFile];
    const uint8_t *b = (const uint8_t *)head.bytes;
    if (head.length >= 12) {
        if (b[4]=='f'&&b[5]=='t'&&b[6]=='y'&&b[7]=='p') { [self loadVideoAtPath:path completion:completion]; return; }
        if (b[0]==0xFF&&b[1]==0xD8&&b[2]==0xFF)          { [self loadImageAtPath:path completion:completion]; return; }
        if (b[0]==0x89&&b[1]==0x50&&b[2]==0x4E&&b[3]==0x47){ [self loadImageAtPath:path completion:completion]; return; }
    }
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
    if (!reader || err) { VLOG(@"reader 失败: %@", err); return; }
    NSArray *tracks = [asset tracksWithMediaType:AVMediaTypeVideo];
    if (!tracks.count) { VLOG(@"无视频轨"); return; }
    AVAssetTrack *track = tracks.firstObject;

    NSDictionary *settings = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
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
                [ss setupVideoReader:ss.mediaPath];
                if (!ss.reader) { ss.playing = NO; break; }
            }
        }
    });
}

- (void)pause { _playing = NO; }

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

#pragma mark - 帧

- (void)updateCurrentBuffer:(CVBufferRef)buffer {
    [_lock lock];
    if (buffer == NULL) {
        if (_currentPixelBuffer) { CVPixelBufferRelease(_currentPixelBuffer); _currentPixelBuffer = NULL; }
        [_lock unlock];
        return;
    }
    if (buffer != _currentPixelBuffer) {
        CVPixelBufferRetain(buffer);
        if (_currentPixelBuffer) CVPixelBufferRelease(_currentPixelBuffer);
        _currentPixelBuffer = buffer;
    }
    [_lock unlock];
}

- (void)clearCurrentBuffer {
    [self updateCurrentBuffer:NULL];
}

- (CVBufferRef)currentFrame {
    [_lock lock];
    CVBufferRef f = _currentPixelBuffer;
    if (f) CVPixelBufferRetain(f);
    [_lock unlock];
    return f;
}

@end

// ============================================================
//  VTPixelTransfer 会话（不设色彩属性，靠 attachments 传递）
// ============================================================
static VTPixelTransferSessionRef gQMTransfer = NULL;

static void QMInitTransfer(void) {
    if (gQMTransfer) return;
    VTPixelTransferSessionCreate(kCFAllocatorDefault, &gQMTransfer);
    if (!gQMTransfer) return;
    VTSessionSetProperty(gQMTransfer,
        kVTPixelTransferPropertyKey_ScalingMode, kVTScalingMode_Trim);
    // ★ 不设置 ColorPrimaries/YCbCrMatrix/TransferFunction
    //   让 VT 从 buffer attachments 自动推断（相机用的通常是 BT.601）
}

// ============================================================
//  Pixel Buffer Pool（目标格式 = 相机格式）
// ============================================================
static CVPixelBufferPoolRef gQMPool = NULL;
static size_t gQMPoolW = 0, gQMPoolH = 0;
static uint32_t gQMPoolFmt = 0;

static CVPixelBufferPoolRef QMGetPool(size_t w, size_t h, uint32_t fmt) {
    if (gQMPool && gQMPoolW == w && gQMPoolH == h && gQMPoolFmt == fmt) return gQMPool;
    if (gQMPool) { CVPixelBufferPoolRelease(gQMPool); gQMPool = NULL; }

    NSDictionary *poolAttrs = @{
        (id)kCVPixelBufferPoolMinimumBufferCountKey: @3,
    };
    NSDictionary *bufAttrs = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(fmt),
        (id)kCVPixelBufferWidthKey: @(w),
        (id)kCVPixelBufferHeightKey: @(h),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (id)kCVPixelBufferMetalCompatibilityKey: @YES,
    };
    CVPixelBufferPoolRef pool = NULL;
    if (CVPixelBufferPoolCreate(kCFAllocatorDefault,
                                (__bridge CFDictionaryRef)poolAttrs,
                                (__bridge CFDictionaryRef)bufAttrs,
                                &pool) != kCVReturnSuccess) return NULL;
    gQMPool = pool;
    gQMPoolW = w;
    gQMPoolH = h;
    gQMPoolFmt = fmt;
    return pool;
}

static CVBufferRef QMGetPooledBuffer(size_t w, size_t h, uint32_t fmt) {
    CVPixelBufferPoolRef pool = QMGetPool(w, h, fmt);
    if (!pool) return NULL;
    CVPixelBufferRef pb = NULL;
    if (CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pb) != kCVReturnSuccess) return NULL;
    return pb;
}

// ============================================================
//  ★ 核心：造新 sample buffer（不修改相机 buffer）
// ============================================================
static CMSampleBufferRef QMCreateReplacementSB(CVImageBufferRef cameraBuf,
                                                CVBufferRef replaceBuf,
                                                CMSampleBufferRef origSb) {
    if (!cameraBuf || !replaceBuf || !origSb) return NULL;

    size_t w = CVPixelBufferGetWidth(cameraBuf);
    size_t h = CVPixelBufferGetHeight(cameraBuf);
    uint32_t fmt = CVPixelBufferGetPixelFormatType(cameraBuf);
    if (w == 0 || h == 0) return NULL;

    // 1. 从 pool 拿目标格式 buffer（尺寸/格式和相机一致）
    CVBufferRef targetBuf = QMGetPooledBuffer(w, h, fmt);
    if (!targetBuf) return NULL;

    // ★★★ 2. 关键：从相机 buffer 复制 attachments（色彩空间/矩阵/范围）
    //          这一步决定是否绿屏
    CFDictionaryRef camAttach = CVBufferGetAttachments(cameraBuf, kCVAttachmentMode_ShouldPropagate);
    if (camAttach) {
        CVBufferSetAttachments(targetBuf, camAttach, kCVAttachmentMode_ShouldPropagate);
    }

    // 3. transfer 替换帧 → 目标 buffer
    QMInitTransfer();
    if (!gQMTransfer) { CVPixelBufferRelease(targetBuf); return NULL; }
    OSStatus s = VTPixelTransferSessionTransferImage(gQMTransfer, replaceBuf, targetBuf);
    if (s != noErr) {
        CVPixelBufferRelease(targetBuf);
        return NULL;
    }

    // 4. 造 fd
    CMVideoFormatDescriptionRef fd = NULL;
    s = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, targetBuf, &fd);
    if (s != noErr || !fd) {
        CVPixelBufferRelease(targetBuf);
        return NULL;
    }

    // 5. 造 sb，继承原时间戳
    CMTime pts = CMSampleBufferGetPresentationTimeStamp(origSb);
    CMTime dur = CMSampleBufferGetDuration(origSb);
    if (CMTIME_IS_INVALID(dur)) dur = CMTimeMake(1, 30);
    CMSampleTimingInfo timing = {
        .duration = dur,
        .presentationTimeStamp = pts,
        .decodeTimeStamp = kCMTimeInvalid,
    };

    CMSampleBufferRef newSb = NULL;
    s = CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, targetBuf, TRUE, NULL, NULL,
                                           fd, &timing, &newSb);
    CFRelease(fd);
    CVPixelBufferRelease(targetBuf);

    if (s != noErr || !newSb) return NULL;
    return newSb;
}

// ============================================================
//  ★ 统一处理入口
// ============================================================
static int64_t gQMSub = 0, gQMKeep = 0, gQMFail = 0, gQMDis = 0, gQMLast = 0;

static CMSampleBufferRef QMProcessSB(CMSampleBufferRef sb, const char *node) {
    if (!sb) return NULL;

    if (!VPMReadEnabled()) { gQMDis++; return NULL; }

    LocalVideoPlayer *p = [LocalVideoPlayer shared];
    CVBufferRef replaceBuf = p ? [p currentFrame] : NULL;
    if (!replaceBuf) { gQMKeep++; return NULL; }

    CVImageBufferRef cameraBuf = CMSampleBufferGetImageBuffer(sb);
    if (!cameraBuf) { CVPixelBufferRelease(replaceBuf); gQMKeep++; return NULL; }

    CMSampleBufferRef newSb = QMCreateReplacementSB(cameraBuf, replaceBuf, sb);
    CVPixelBufferRelease(replaceBuf);

    if (newSb) gQMSub++; else gQMFail++;

    int64_t total = gQMSub + gQMKeep + gQMFail + gQMDis;
    if (total - gQMLast >= 60) {
        gQMLast = total;
        VLOG(@"📊 [%s] 替换 %lld / 透传 %lld / 失败 %lld / 禁用 %lld",
             node ?: "?", gQMSub, gQMKeep, gQMFail, gQMDis);
    }
    return newSb;
}

// ============================================================
//  Hook 节点 1：BWNodeOutput.emitSampleBuffer:
// ============================================================
static void (*origQMEmit)(id, SEL, CMSampleBufferRef) = NULL;

static void QMEmitHook(id self, SEL _cmd, CMSampleBufferRef sb) {
    @try {
        CMSampleBufferRef newSb = QMProcessSB(sb, "emit");
        if (newSb) {
            if (origQMEmit) origQMEmit(self, _cmd, newSb);
            CFRelease(newSb);
        } else {
            if (origQMEmit) origQMEmit(self, _cmd, sb);
        }
    } @catch (NSException *e) {
        VLOG(@"emit 异常: %@", e);
        if (origQMEmit) origQMEmit(self, _cmd, sb);
    }
}

// ============================================================
//  Hook 节点 2/3：BWStillImageScalerNode / BWPhotoEncoderNode
// ============================================================
static void (*origQMRender)(id, SEL, CMSampleBufferRef, id) = NULL;

static void QMRenderHook(id self, SEL _cmd, CMSampleBufferRef sb, id input) {
    @try {
        CMSampleBufferRef newSb = QMProcessSB(sb, "render");
        if (newSb) {
            if (origQMRender) origQMRender(self, _cmd, newSb, input);
            CFRelease(newSb);
        } else {
            if (origQMRender) origQMRender(self, _cmd, sb, input);
        }
    } @catch (NSException *e) {
        VLOG(@"render 异常: %@", e);
        if (origQMRender) origQMRender(self, _cmd, sb, input);
    }
}

// ============================================================
//  ★ 安装 hook：3 个节点独立 + 持续重试
// ============================================================
static BOOL gQMEmitInstalled = NO;
static BOOL gQMRenderInstalled = NO;

static void QMInstallHooks(void) {
    @try {
        // 节点 1：BWNodeOutput
        if (!gQMEmitInstalled) {
            Class c = NSClassFromString(@"BWNodeOutput");
            if (c) {
                Method m = class_getInstanceMethod(c, @selector(emitSampleBuffer:));
                if (m) {
                    IMP cur = method_getImplementation(m);
                    if (cur != (IMP)QMEmitHook) {
                        origQMEmit = (void (*)(id, SEL, CMSampleBufferRef))cur;
                        method_setImplementation(m, (IMP)QMEmitHook);
                    }
                    gQMEmitInstalled = YES;
                    VLOG(@"✅ BWNodeOutput.emitSampleBuffer: 已钩");
                }
            }
        }

        // 节点 2/3：BWStillImageScalerNode / BWPhotoEncoderNode（同签名，共用一个 orig）
        if (!gQMRenderInstalled) {
            BOOL anyInstalled = NO;
            Class c2 = NSClassFromString(@"BWStillImageScalerNode");
            if (c2) {
                Method m = class_getInstanceMethod(c2, @selector(renderSampleBuffer:forInput:));
                if (m) {
                    IMP cur = method_getImplementation(m);
                    if (cur != (IMP)QMRenderHook) {
                        if (!origQMRender) origQMRender = (void (*)(id, SEL, CMSampleBufferRef, id))cur;
                        method_setImplementation(m, (IMP)QMRenderHook);
                    }
                    anyInstalled = YES;
                    VLOG(@"✅ BWStillImageScalerNode.renderSampleBuffer:forInput: 已钩");
                }
            }
            Class c3 = NSClassFromString(@"BWPhotoEncoderNode");
            if (c3) {
                Method m = class_getInstanceMethod(c3, @selector(renderSampleBuffer:forInput:));
                if (m) {
                    IMP cur = method_getImplementation(m);
                    if (cur != (IMP)QMRenderHook) {
                        if (!origQMRender) origQMRender = (void (*)(id, SEL, CMSampleBufferRef, id))cur;
                        method_setImplementation(m, (IMP)QMRenderHook);
                    }
                    anyInstalled = YES;
                    VLOG(@"✅ BWPhotoEncoderNode.renderSampleBuffer:forInput: 已钩");
                }
            }
            if (anyInstalled) gQMRenderInstalled = YES;
        }

        // 未完成 → 持续每 2 秒重试
        if (!gQMEmitInstalled || !gQMRenderInstalled) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                           dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                QMInstallHooks();
            });
        }
    } @catch (NSException *e) {
        VLOG(@"安装异常: %@", e);
    }
}

// ============================================================
//  帧钩子（旋转/缩放，仅 BGRA）
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

static void (*origUpdateCurrentBuffer)(id, SEL, CVBufferRef) = NULL;
static volatile int64_t VPMFramesSeen = 0;

static void VPMUpdateCurrentBufferHook(id self, SEL _cmd, CVBufferRef buffer) {
    @try {
        int64_t seen = __sync_add_and_fetch(&VPMFramesSeen, 1);
        if (seen == 1 && buffer) {
            VLOG(@"帧钩子首帧 %zux%zu fmt 0x%X",
                 CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer),
                 CVPixelBufferGetPixelFormatType(buffer));
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
        if (!lvp) return;
        if (!VPMClassOwnsMethod(lvp, @selector(updateCurrentBuffer:))) return;
        Method m = class_getInstanceMethod(lvp, @selector(updateCurrentBuffer:));
        if (!m) return;
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
//  桥接
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

static void VPMPlayerDisable(void) {
    @try {
        Class cls = NSClassFromString(@"LocalVideoPlayer");
        if (!cls || ![cls respondsToSelector:@selector(shared)]) return;
        id player = ((id(*)(id,SEL))objc_msgSend)(cls, @selector(shared));
        if (!player) return;
        if ([player respondsToSelector:@selector(clearCurrentBuffer)]) {
            ((void(*)(id,SEL))objc_msgSend)(player, @selector(clearCurrentBuffer));
        }
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            @try {
                if ([player respondsToSelector:@selector(stop)]) {
                    ((void(*)(id,SEL))objc_msgSend)(player, @selector(stop));
                }
            } @catch (NSException *e) {}
        });
        VLOG(@"🔇 已禁用：currentFrame 清空 + stop");
    } @catch (NSException *e) {
        VLOG(@"禁用异常: %@", e);
    }
}

static void VPMBridgeTryLoad(NSString *path) {
    if (!path.length) return;
    Class cls = NSClassFromString(@"LocalVideoPlayer");
    if (!cls) return;

    id player = nil;
    if ([cls respondsToSelector:@selector(shared)]) {
        player = ((id(*)(id,SEL))objc_msgSend)(cls, @selector(shared));
    }
    if (!player) return;

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
            BOOL enabled = VPMReadEnabled();

            if (!gHasLastEnabled) {
                gHasLastEnabled = YES;
                gLastEnabled = enabled;
            } else if (enabled != gLastEnabled) {
                gLastEnabled = enabled;
                if (!enabled) {
                    VPMPlayerDisable();
                } else {
                    gLastBridgedPath = nil;
                }
                VLOG(@"状态切换: enabled=%d", enabled);
            }

            if (!enabled) return;

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
//  引导
// ============================================================
static void VPMScheduleBootstrap(int attempt) {
    if (VPMFrameInstalled) return;
    if (attempt > 60) {
        VLOG(@"⚠️ 引导超时");
        return;
    }
    Class lvClass = NSClassFromString(@"LocalVideoPlayer");
    if (lvClass) {
        VLOG(@"✅ 引导成功（第 %d 次）", attempt);
        VPMInstallFrameHook();
        VPMStartBridgePolling();
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        VPMScheduleBootstrap(attempt + 1);
    });
}

// ============================================================
//  SpringBoard
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
        [LocalVideoPlayer class];
        VLOGInit();
        NSString *proc = [[NSProcessInfo processInfo] processName];
        VLOG(@"VCamEnhancer 已加载，进程=%@", proc);
        VPMEnsureDir();
        if ([proc isEqualToString:@"mediaserverd"]) {
            QMInstallHooks();
        }
        VPMScheduleBootstrap(0);
    }
}
