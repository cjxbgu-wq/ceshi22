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
//  【内嵌】LocalVideoPlayer（★ 解码输出 420v，与原版一致）
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
@property (nonatomic)         double startTime;
@property (nonatomic)         double videoStartPTS;

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
        _videoStartPTS = -1;
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
    _videoStartPTS = -1;
    _startTime = 0;

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

    // ★★★ 关键修复：解码输出 420v，与原版完全一致
    //   这样视频帧和相机 buffer 都是 YUV，VT 做 YUV→YUV 同格式传输
    //   完全不涉及 RGB→YUV 转换，永远不会绿屏
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

    // ★ 图片也改成 420v，和相机同格式
    NSDictionary *attrs = @{
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (id)kCVPixelBufferMetalCompatibilityKey: @YES,
    };
    CVPixelBufferRef pb = NULL;
    CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                        (__bridge CFDictionaryRef)attrs, &pb);
    if (pb) {
        // 用 CIImage 渲染到 YUV buffer
        CIImage *ci = [CIImage imageWithCGImage:img];
        static CIContext *ciCtx = nil;
        static dispatch_once_t onceCtx;
        dispatch_once(&onceCtx, ^{
            ciCtx = [CIContext contextWithOptions:nil];
        });
        if (ciCtx) {
            [ciCtx render:ci toCVPixelBuffer:pb];
            [self updateCurrentBuffer:pb];
        }
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
    _startTime = [NSDate timeIntervalSinceReferenceDate];
    _videoStartPTS = -1;

    __weak typeof(self) ws = self;
    dispatch_async(_decodeQueue, ^{
        typeof(ws) ss = ws;
        if (!ss) return;
        while (ss.playing && !ss.shouldStop) {
            @autoreleasepool {
                CMSampleBufferRef sb = [ss.output copyNextSampleBuffer];
                if (!sb) {
                    ss.videoStartPTS = -1;
                    ss.startTime = [NSDate timeIntervalSinceReferenceDate];
                    [ss setupVideoReader:ss.mediaPath];
                    if (!ss.reader) { ss.playing = NO; break; }
                    continue;
                }

                CMTime pts = CMSampleBufferGetPresentationTimeStamp(sb);
                double t = CMTimeGetSeconds(pts);
                if (ss.videoStartPTS < 0) ss.videoStartPTS = t;
                double videoElapsed = t - ss.videoStartPTS;
                double wallElapsed = [NSDate timeIntervalSinceReferenceDate] - ss.startTime;
                double wait = videoElapsed - wallElapsed;
                if (wait > 0.001 && wait < 1.0) {
                    [NSThread sleepForTimeInterval:wait];
                }

                CVImageBufferRef pb = CMSampleBufferGetImageBuffer(sb);
                if (pb) [ss updateCurrentBuffer:pb];
                CFRelease(sb);
            }
        }
        VLOG(@"解码线程退出");
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

- (BOOL)decodeOneFrame { return YES; }

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
//  VT transfer session（按原版：只设 ScalingMode）
// ============================================================
static VTPixelTransferSessionRef gQMTransfer = NULL;
static NSLock *gQMTransferLock = nil;

static void QMInitTransfer(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gQMTransferLock = [NSLock new];
        VTPixelTransferSessionCreate(kCFAllocatorDefault, &gQMTransfer);
        if (gQMTransfer) {
            VTSessionSetProperty(gQMTransfer,
                kVTPixelTransferPropertyKey_ScalingMode, kVTScalingMode_Trim);
        }
    });
}

// ============================================================
//  ★ 核心：YUV → 同格式 transfer（修复视频/慢动作/延时摄影绿屏）
// ============================================================
static int64_t gQMSub = 0, gQMKeep = 0, gQMFail = 0, gQMDis = 0, gQMLast = 0;

// 独立的格式转换 session（只用于格式不匹配时的一次性重建）
static VTPixelTransferSessionRef gQMConvTransfer = NULL;
static dispatch_once_t gQMConvOnce;

static BOOL QMReplaceInPlace(CVImageBufferRef cameraBuf, CVBufferRef replaceBuf) {
    if (!cameraBuf || !replaceBuf) return NO;

    QMInitTransfer();
    if (!gQMTransfer) return NO;

    // ★★★ 关键修复：检测格式是否一致
    //   视频/慢动作/延时摄影 模式下相机可能是 420f（FullRange）或 x420（10bit HDR）
    //   而本地解码/加载的替换帧是 420v。直接把 420v 搬到 420f/x420 上会绿屏。
    //   对策：格式不一致时，先把替换帧重建为相机格式，再做 transfer。
    OSType camFmt = CVPixelBufferGetPixelFormatType(cameraBuf);
    OSType repFmt = CVPixelBufferGetPixelFormatType(replaceBuf);

    CVPixelBufferRef usable = replaceBuf;

    if (camFmt != repFmt) {
        size_t w = CVPixelBufferGetWidth(cameraBuf);
        size_t h = CVPixelBufferGetHeight(cameraBuf);
        if (w == 0 || h == 0) return NO;

        NSDictionary *attrs = @{
            (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
            (id)kCVPixelBufferMetalCompatibilityKey: @YES,
        };
        CVPixelBufferRef conv = NULL;
        CVReturn cr = CVPixelBufferCreate(kCFAllocatorDefault, w, h, camFmt,
                                          (__bridge CFDictionaryRef)attrs, &conv);
        if (cr == kCVReturnSuccess && conv) {
            // 用独立 VT session 做纯格式转换
            dispatch_once(&gQMConvOnce, ^{
                VTPixelTransferSessionCreate(kCFAllocatorDefault, &gQMConvTransfer);
            });
            if (gQMConvTransfer) {
                OSStatus cs = VTPixelTransferSessionTransferImage(gQMConvTransfer, replaceBuf, conv);
                if (cs == noErr) {
                    usable = conv;
                } else {
                    VLOG(@"⚠️ 格式转换失败 camFmt=0x%X repFmt=0x%X os=%d", camFmt, repFmt, (int)cs);
                    CVPixelBufferRelease(conv);
                    conv = NULL;
                }
            } else {
                CVPixelBufferRelease(conv);
                conv = NULL;
            }
        }

        // 转换失败时，直接保留相机原始帧（宁可透传也不绿屏）
        if (usable == replaceBuf) {
            return NO;
        }
    }

    [gQMTransferLock lock];
    OSStatus s = VTPixelTransferSessionTransferImage(gQMTransfer, usable, cameraBuf);
    [gQMTransferLock unlock];

    if (usable != replaceBuf) CVPixelBufferRelease(usable);

    return (s == noErr);
}

static void QMProcessAndModify(CMSampleBufferRef sb, const char *node) {
    if (!sb) return;

    if (!VPMReadEnabled()) { gQMDis++; return; }

    LocalVideoPlayer *p = [LocalVideoPlayer shared];
    CVBufferRef replaceBuf = p ? [p currentFrame] : NULL;
    if (!replaceBuf) { gQMKeep++; return; }

    CVImageBufferRef cameraBuf = CMSampleBufferGetImageBuffer(sb);
    if (!cameraBuf) { CVPixelBufferRelease(replaceBuf); gQMKeep++; return; }

    BOOL ok = QMReplaceInPlace(cameraBuf, replaceBuf);
    CVPixelBufferRelease(replaceBuf);

    if (ok) gQMSub++; else gQMFail++;

    int64_t total = gQMSub + gQMKeep + gQMFail + gQMDis;
    if (total - gQMLast >= 60) {
        gQMLast = total;
        // ★ 增补诊断信息：把相机/替换帧的像素格式也打出来，便于排查
        CVImageBufferRef cb = CMSampleBufferGetImageBuffer(sb);
        VLOG(@"📊 [%s] 替换 %lld / 透传 %lld / 失败 %lld / 禁用 %lld | camFmt=0x%X repFmt=0x%X",
             node ?: "?", gQMSub, gQMKeep, gQMFail, gQMDis,
             cb ? CVPixelBufferGetPixelFormatType(cb) : 0,
             replaceBuf ? CVPixelBufferGetPixelFormatType(replaceBuf) : 0);
    }
}

// ============================================================
//  Hook：只 BWNodeOutput
// ============================================================
static void (*origQMEmit)(id, SEL, CMSampleBufferRef) = NULL;

static void QMEmitHook(id self, SEL _cmd, CMSampleBufferRef sb) {
    @try {
        QMProcessAndModify(sb, "emit");
    } @catch (NSException *e) {
        VLOG(@"emit 异常: %@", e);
    }
    if (origQMEmit) origQMEmit(self, _cmd, sb);
}

static BOOL gQMEmitInstalled = NO;

static void QMInstallHooks(void) {
    @try {
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

        if (!gQMEmitInstalled) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                           dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                QMInstallHooks();
            });
        }
    } @catch (NSException *e) { VLOG(@"安装异常: %@", e); }
}

// ============================================================
//  旋转/缩放（★ 改用 CIImage，支持 YUV）
// ============================================================
static CIContext *gQMCIContext = nil;

static void VPMRotateDirectionInPlace(CVBufferRef buf, NSInteger rot, CGFloat userScale) {
    if (!buf || (rot == 0 && fabs(userScale - 1.0f) < 0.01f)) return;

    static dispatch_once_t onceCI;
    dispatch_once(&onceCI, ^{
        gQMCIContext = [CIContext contextWithOptions:@{
            kCIContextUseSoftwareRenderer: @NO,
        }];
    });
    if (!gQMCIContext) return;

    @try {
        size_t w = CVPixelBufferGetWidth(buf);
        size_t h = CVPixelBufferGetHeight(buf);
        if (w == 0 || h == 0) return;

        CIImage *src = [CIImage imageWithCVPixelBuffer:buf];
        if (!src) return;

        CGFloat W = (CGFloat)w, H = (CGFloat)h;

        // 1. 中心旋转
        CGAffineTransform t = CGAffineTransformIdentity;
        t = CGAffineTransformTranslate(t, W / 2.0, H / 2.0);
        t = CGAffineTransformRotate(t, -(CGFloat)rot * M_PI / 180.0);
        t = CGAffineTransformTranslate(t, -W / 2.0, -H / 2.0);
        CIImage *rotated = [src imageByApplyingTransform:t];
        if (!rotated) return;

        // 2. aspectFill 缩放到原尺寸
        CGFloat ew = (rot == 90 || rot == 270) ? H : W;
        CGFloat eh = (rot == 90 || rot == 270) ? W : H;
        CGRect ext = rotated.extent;
        CGFloat sx = ew / ext.size.width;
        CGFloat sy = eh / ext.size.height;
        CGFloat fillScale = MAX(sx, sy);
        CGFloat totalScale = fillScale * userScale;

        CGAffineTransform scale = CGAffineTransformMakeScale(totalScale, totalScale);
        CIImage *scaled = [rotated imageByApplyingTransform:scale];

        // 3. 平移居中
        CGRect se = scaled.extent;
        CGAffineTransform trans = CGAffineTransformMakeTranslation(
            (W - se.size.width) / 2.0 - se.origin.x,
            (H - se.size.height) / 2.0 - se.origin.y);
        CIImage *final = [scaled imageByApplyingTransform:trans];

        // 4. 裁剪到原 buffer 尺寸
        final = [final imageByCroppingToRect:CGRectMake(0, 0, W, H)];

        // 5. 渲染回 YUV buffer
        [gQMCIContext render:final toCVPixelBuffer:buf];
    } @catch (NSException *e) {}
}

// ============================================================
//  帧钩子（旋转/缩放）
// ============================================================
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
    } @catch (NSException *e) { VLOG(@"❌ 帧钩子安装异常: %@", e); }
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
    dispatch_once(&once, ^{ gNoopCompletion = [^(BOOL ok){ (void)ok; } copy]; });
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
        VLOG(@"🔇 已禁用");
    } @catch (NSException *e) { VLOG(@"禁用异常: %@", e); }
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
        } @catch (NSException *e) { VLOG(@"❌ 桥接 %@ 异常: %@", name, e); }
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
    if (attempt > 60) { VLOG(@"⚠️ 引导超时"); return; }
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
            VPMScheduleBootstrap(0);
        }
    }
}
