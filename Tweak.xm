// ============================================================
// QianmianEnhancer · 主 Tweak
// 完全照抄老代码 VCamExtraKeys.xm 的面板接管机制：
//   ① VPMSchedulePanelInstall 轮询（每秒 1 次，最多 60 次）
//   ② VPMInstallPanelHooks 用 method_setImplementation 装 hook
//   ③ VPMSettingsViewDidLoad 里清空原版 UI，挂我们的面板
//   ④ 面板按钮 target = 原版 VC（self），转发原版 SEL
//   ⑤ 帧钩子（旋转 + 缩放）
// ============================================================

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreVideo/CoreVideo.h>
#import <QuartzCore/QuartzCore.h>
#import <math.h>
#import <string.h>
#import <stdlib.h>
#import <objc/runtime.h>
#import "QMEnhancerView.h"

// ============ 日志宏 ============
#define VLOG(fmt, ...) do { \
    NSString *__s = [NSString stringWithFormat:(fmt), ##__VA_ARGS__]; \
    NSLog(@"[VCamEnhancer] %@", __s); \
    NSString *__old = [NSString stringWithContentsOfFile:@"/tmp/vcam_enhancer.log" encoding:NSUTF8StringEncoding error:nil]; \
    NSString *__new = [NSString stringWithFormat:@"%@%@\n", __old ?: @"", __s]; \
    [__new writeToFile:@"/tmp/vcam_enhancer.log" atomically:YES encoding:NSUTF8StringEncoding error:nil]; \
} while(0)

static NSString *const VPMSharedSettingsPath = @"/tmp/vcam_enhancer_settings.plist";
static NSString *const VPMRotationKey        = @"videoRotationLV";
static NSString *const VPMScaleKey           = @"videoScaleLV";

// ============ 设置读写 ============
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

// ============ 帧处理（照抄）============
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

// ============ 帧钩子（照抄）============
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

static BOOL VPMFrameInstalled = NO;
static void VPMInstallFrameHook(void) {
    if (VPMFrameInstalled) return;
    @try {
        Class lvp = NSClassFromString(@"LocalVideoPlayer");
        if (!lvp) { VLOG(@"⚠️ LocalVideoPlayer 类不存在，等下次"); return; }
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
// 面板接管（完全照抄老代码的机制）
// ============================================================
static void (*origSettingsViewDidLoad)(id, SEL) = NULL;

// 照抄老代码 VPMSettingsViewDidLoad
static void VPMSettingsViewDidLoad(id self, SEL _cmd) {
    @try {
        VLOG(@"🟢 VCamSettingsViewController.viewDidLoad 被调用");

        // 先跑原逻辑
        if (origSettingsViewDidLoad) origSettingsViewDidLoad(self, _cmd);

        UIViewController *vc = (UIViewController *)self;
        UIView *root = vc.view;
        if (!root) { VLOG(@"❌ root view 为 nil"); return; }

        VLOG(@"   原版 view 有 %lu 个子视图", (unsigned long)root.subviews.count);

        // 清空原版 UI
        for (UIView *v in [root.subviews copy]) [v removeFromSuperview];

        // 挂我们的面板
        QMEnhancerView *panel = [[QMEnhancerView alloc] initWithFrame:root.bounds];
        panel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        panel.panelVC = vc;
        [root addSubview:panel];
        VLOG(@"✅ 简化面板已挂载到原版 VC");
    } @catch (NSException *e) {
        VLOG(@"❌ viewDidLoad 异常: %@", e);
        if (origSettingsViewDidLoad) origSettingsViewDidLoad(self, _cmd);
    }
}

// 照抄老代码 VPMInstallPanelHooks
static BOOL VPMPanelHooked = NO;
static void VPMInstallPanelHooks(void) {
    if (VPMPanelHooked) return;
    @try {
        Class settings = NSClassFromString(@"VCamSettingsViewController");
        if (!settings) return;  // 类还没加载，等下次轮询

        Method m = class_getInstanceMethod(settings, @selector(viewDidLoad));
        if (!m) { VLOG(@"⚠️ viewDidLoad 方法不存在"); return; }

        IMP orig = method_getImplementation(m);
        if (orig == (IMP)VPMSettingsViewDidLoad) {
            VPMPanelHooked = YES;
            return;
        }
        origSettingsViewDidLoad = (void (*)(id, SEL))orig;
        method_setImplementation(m, (IMP)VPMSettingsViewDidLoad);
        VPMPanelHooked = YES;
        VLOG(@"✅ 面板 hook 已安装 (method_setImplementation)");
    } @catch (NSException *e) {
        VLOG(@"❌ 面板 hook 安装异常: %@", e);
    }
}

// 照抄老代码 VPMSchedulePanelInstall
static void VPMSchedulePanelInstall(void) {
    VPMInstallPanelHooks();

    dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
    dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    dispatch_source_set_timer(src,
                              dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC),
                              1 * NSEC_PER_SEC,
                              NSEC_PER_SEC);
    __block int tries = 0;
    dispatch_source_set_event_handler(src, ^{
        @autoreleasepool {
            @try {
                if (VPMPanelHooked) {
                    dispatch_source_cancel(src);
                    return;
                }
                if (++tries >= 60) {
                    VLOG(@"❌ 面板 hook 60 秒内未装成");
                    dispatch_source_cancel(src);
                    return;
                }
                VPMInstallPanelHooks();
            } @catch (NSException *e) {}
        }
    });
    dispatch_resume(src);
}

// ============================================================
// SpringBoard 启动完成后开始轮询安装面板 hook
// ============================================================
%hook SpringBoard

- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    VLOG(@"SpringBoard 启动完成，开始轮询面板 hook");
    VPMSchedulePanelInstall();
}

%end

// ============================================================
// %ctor
// ============================================================
%ctor {
    @autoreleasepool {
        [@"" writeToFile:@"/tmp/vcam_enhancer.log" atomically:YES
                encoding:NSUTF8StringEncoding error:nil];

        NSString *proc = [[NSProcessInfo processInfo] processName];
        VLOG(@"========================================");
        VLOG(@"VCamEnhancer dylib 已加载，进程=%@", proc);

        Class vcClass = NSClassFromString(@"VCamSettingsViewController");
        Class lvClass = NSClassFromString(@"LocalVideoPlayer");
        VLOG(@"VCamSettingsViewController: %@", vcClass ? @"存在" : @"不存在（稍后轮询）");
        VLOG(@"LocalVideoPlayer: %@", lvClass ? @"存在" : @"不存在（稍后轮询）");
        VLOG(@"========================================");

        // 帧钩子：1 秒后装
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            VPMInstallFrameHook();
        });

        // 面板 hook：立即尝试一次（SpringBoard 里有效）
        if ([proc isEqualToString:@"SpringBoard"]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                VPMSchedulePanelInstall();
            });
        }
    }
}
