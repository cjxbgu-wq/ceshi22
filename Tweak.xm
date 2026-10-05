// ============================================================
// QianmianEnhancer · 主 Tweak
// 完全照抄老代码 VCamExtraKeys.xm 机制：
//   ① %hook VCamSettingsViewController.viewDidLoad
//      → 清空原版 UI，挂我们的简化面板
//      → 面板按钮 target = 原版 VC（self）
//   ② %hook LocalVideoPlayer.updateCurrentBuffer:
//      → 帧处理（旋转 + 缩放）
//   ③ %ctor 里 1 秒延迟装帧钩子
// 不 hook SpringBoard，不加悬浮球，不改任何原版入口。
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

// ============ 帧处理：旋转 + 缩放（照抄老代码）============
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

// ============ 帧钩子（照抄老代码）============
static void (*origUpdateCurrentBuffer)(id, SEL, CVBufferRef) = NULL;
static volatile int64_t VPMFramesSeen = 0;

static void VPMUpdateCurrentBufferHook(id self, SEL _cmd, CVBufferRef buffer) {
    @try {
        int64_t seen = __sync_add_and_fetch(&VPMFramesSeen, 1);
        if (seen == 1 && buffer) {
            NSLog(@"[VCamEnhancer] 首帧 %zux%zu",
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
        if (!lvp) return;
        Method m = class_getInstanceMethod(lvp, @selector(updateCurrentBuffer:));
        if (!m) return;
        IMP orig = method_getImplementation(m);
        if (orig == (IMP)VPMUpdateCurrentBufferHook) { VPMFrameInstalled = YES; return; }
        origUpdateCurrentBuffer = (void (*)(id, SEL, CVBufferRef))orig;
        method_setImplementation(m, (IMP)VPMUpdateCurrentBufferHook);
        VPMFrameInstalled = YES;
        NSLog(@"[VCamEnhancer] 帧钩子已安装");
    } @catch (NSException *e) {}
}

// ============ 接管原版面板 UI（照抄老代码核心）============
@interface VCamSettingsViewController : UIViewController
- (void)switchVideoTapped;
- (void)restoreCameraTapped;
- (void)toggleFloatingBallTapped;
- (void)dismissPanel;
@end

%hook VCamSettingsViewController

- (void)viewDidLoad {
    %orig;
    NSLog(@"[VCamEnhancer] ✅ viewDidLoad 已捕获，接管 UI");

    // 照抄老代码：清空原版 UI
    for (UIView *v in [self.view.subviews copy]) [v removeFromSuperview];

    // 挂我们的简化面板，把 self（原版 VC）传给面板，用作按钮 target
    QMEnhancerView *panel = [[QMEnhancerView alloc] initWithFrame:self.view.bounds];
    panel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    panel.panelVC = self;
    [self.view addSubview:panel];
    NSLog(@"[VCamEnhancer] ✅ 简化面板已挂载，按钮 target = %@", [self class]);
}

%end

// ============ %hook LocalVideoPlayer ============
@interface LocalVideoPlayer : NSObject
- (void)updateCurrentBuffer:(CVPixelBufferRef)buffer;
@end

%hook LocalVideoPlayer
- (void)updateCurrentBuffer:(CVPixelBufferRef)buffer {
    if (buffer) {
        @try { [QMEnhancerView processFrame:buffer]; } @catch (NSException *e) {}
    }
    %orig;
}
%end

// ============ %ctor ============
%ctor {
    @autoreleasepool {
        @try {
            [@"ok" writeToFile:@"/tmp/vcam_enhancer_injected.txt"
                    atomically:YES encoding:NSUTF8StringEncoding error:nil];
        } @catch (NSException *e) {}
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            VPMInstallFrameHook();
        });
    }
}
