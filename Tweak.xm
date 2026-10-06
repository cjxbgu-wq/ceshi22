#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreVideo/CoreVideo.h>
#import <QuartzCore/QuartzCore.h>
#import <math.h>
#import <string.h>
#import <stdlib.h>
#import <pthread.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "QMEnhancerView.h"

// ============================================================
//  日志（★ 第六轮：进程名区分 + pthread 锁）
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

// ============ 路径常量（跨进程共享）============
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

// ============ 帧处理（核心，一行不动）============
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

// ============ 帧钩子（核心，一行不动）============
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

// ★ 第五轮：类直接拥有该方法校验
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
//  桥接（跨进程轮询 → 调原版加载）
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
//  引导（轮询 LocalVideoPlayer 出现）
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
//  SpringBoard 启动后 → 显示悬浮球
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

        VPMScheduleBootstrap(0);
    }
}
