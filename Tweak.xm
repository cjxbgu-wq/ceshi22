//
//  Tweak.xm — 原版 VCam 入口 + 替换链路 (反编译重建 + 替换逻辑补全)
//

#import <Foundation/Foundation.h>
#import <substrate.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>
#import <VideoToolbox/VideoToolbox.h>
#import <notify.h>
#import <UIKit/UIKit.h>

#import "src/VCamCore.h"
#import "src/LocalVideoPlayer.h"
#import "src/GPUImageProcessor.h"
#import "src/VCamNotify.h"
#import "src/VCamFloatingBall.h"
#import "src/VCamSettingsViewController.h"

// ===== 常量 (字符串事实) =====
static NSString *const kVCamVideoPath  = @"/var/mobile/Media/DCIM/vcam.mp4";
static NSString *const kVCamMediaDir   = @"/var/mobile/Media/DCIM";
static NSString *const kVCamStatePath  = @"/var/mobile/vc.plist";
static NSString *const kVCamLiveChanged = @"com.vcam.ios.live.changed";
static NSString *const kVCamMediaReload = @"com.vcam.ios.media.reload";

// ===== 引擎全局 (mediaserverd 侧) =====
static VCamCore *gCore = nil;
static LocalVideoPlayer *gPlayer = nil;
static GPUImageProcessor *gProcessor = nil;
static VCamNotify *gNotify = nil;

// ===== SpringBoard 侧全局 =====
static VCamFloatingBall *gFloatBall = nil;
static double gLastVolUpTs = 0;

// ===== hook 原实现 =====
static void (*origEmitSampleBuffer)(id, SEL, CMSampleBufferRef) = NULL;
static void (*origRenderSBForInput)(id, SEL, CMSampleBufferRef, id) = NULL;
static void (*origHandlePhysicalButtonEvent)(id, SEL, id) = NULL;
static void (*origApplicationDidFinishLaunching)(id, SEL, id) = NULL;
static void (*origIncreaseVolume)(id, SEL) = NULL;

#pragma mark - 替换链路 (核心)

// ===== BWNodeOutput.emitSampleBuffer: — 相机视频管线入口 =====
static void hookEmitSampleBuffer(id self, SEL _cmd, CMSampleBufferRef sb) {
    @autoreleasepool {
        @try {
            if (gCore && gCore.isEnabled && sb && [gCore hasReplacementFrame]) {
                CVImageBufferRef cameraBuffer = CMSampleBufferGetImageBuffer(sb);
                if (cameraBuffer) {
                    // 就地替换: 把 replacementPixelBuffer transfer 进相机当前帧
                    [gCore renderReplacementToPixelBuffer:cameraBuffer];
                }
            }
        } @catch (NSException *e) {
            NSLog(@"[vcam] emit hook exception: %@", e);
        }
        if (origEmitSampleBuffer) origEmitSampleBuffer(self, _cmd, sb);
    }
}

// ===== BWStillImageScalerNode / BWPhotoEncoderNode.renderSampleBuffer:forInput: — 照片管线 =====
static void hookRenderSBForInput(id self, SEL _cmd, CMSampleBufferRef sb, id input) {
    @autoreleasepool {
        @try {
            if (gCore && gCore.isEnabled && sb && [gCore hasReplacementFrame]) {
                CVImageBufferRef cameraBuffer = CMSampleBufferGetImageBuffer(sb);
                if (cameraBuffer) {
                    [gCore renderReplacementToPixelBuffer:cameraBuffer];
                }
            }
        } @catch (NSException *e) {
            NSLog(@"[vcam] render hook exception: %@", e);
        }
        if (origRenderSBForInput) origRenderSBForInput(self, _cmd, sb, input);
    }
}

#pragma mark - SpringBoard 侧 hook

// ===== 双击音量上键 -> 显隐悬浮球 =====
static void hookHandlePhysicalButtonEvent(id self, SEL _cmd, id event) {
    if (origHandlePhysicalButtonEvent) origHandlePhysicalButtonEvent(self, _cmd, event);
}

static void hookIncreaseVolume(id self, SEL _cmd) {
    double now = [NSDate timeIntervalSinceReferenceDate];
    if (now - gLastVolUpTs < 0.5) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (gFloatBall) {
                gFloatBall.hidden = !gFloatBall.hidden;
                NSLog(@"[vcam] Double click volume UP detected!");
            }
        });
        gLastVolUpTs = 0;
    } else {
        gLastVolUpTs = now;
    }
    if (origIncreaseVolume) origIncreaseVolume(self, _cmd);
}

// ===== 创建悬浮球 =====
static void hookApplicationDidFinishLaunching(id self, SEL _cmd, id application) {
    if (origApplicationDidFinishLaunching) origApplicationDidFinishLaunching(self, _cmd, application);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        @try {
            if (gFloatBall) return;
            UIWindow *kw = [UIApplication sharedApplication].keyWindow;
            if (!kw) kw = [UIApplication sharedApplication].windows.lastObject;
            if (!kw) return;
            CGFloat W = kw.bounds.size.width;
            CGFloat H = kw.bounds.size.height;
            CGRect f = CGRectMake(W - 70, H / 2.0 - 30, 60, 60);
            gFloatBall = [[VCamFloatingBall alloc] initWithFrame:f];
            gFloatBall.hidden = YES;   // 默认隐藏, 双击音量上键显示
            [kw addSubview:gFloatBall];
            NSLog(@"[vcam] Floating window created");
        } @catch (NSException *e) {
            NSLog(@"[vcam] floating ball exception: %@", e);
        }
    });
}

#pragma mark - 状态轮询 (mediaserverd 侧)

static void startStatePolling(void) {
    dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                              1 * NSEC_PER_SEC, NSEC_PER_MSEC * 100);
    dispatch_source_set_event_handler(timer, ^{
        @autoreleasepool {
            @try {
                NSDictionary *state = [NSDictionary dictionaryWithContentsOfFile:kVCamStatePath];
                if (!state) return;
                BOOL enabled = state[@"enabled"] ? [state[@"enabled"] boolValue] : YES;
                BOOL rtmpOn  = state[@"rtmpEnabled"] ? [state[@"rtmpEnabled"] boolValue] : NO;
                NSString *url = state[@"rtmpUrl"];

                gCore.isEnabled = enabled;

                static BOOL lastRtmp = NO;
                static NSString *lastUrl = nil;
                if (rtmpOn && (!lastRtmp || ![url isEqualToString:lastUrl ?: @""])) {
                    [[RtmpPullClient sharedClient] connectToUrl:url];
                } else if (!rtmpOn && lastRtmp) {
                    [[RtmpPullClient sharedClient] disconnect];
                }
                lastRtmp = rtmpOn;
                lastUrl = [url copy];
            } @catch (NSException *e) {}
        }
    });
    dispatch_resume(timer);
    NSLog(@"[vcam] State polling timer started");
}

#pragma mark - 入口

__attribute__((constructor))
static void vcamInit(void) {
    @autoreleasepool {
        NSString *proc = [[NSProcessInfo processInfo] processName];
        NSLog(@"[vcam] Loading in process: %@", proc);

        if ([proc isEqualToString:@"SpringBoard"]) {
            // ===== SB 分支: UI + 音量键 hook =====
            Class sbClass = NSClassFromString(@"SpringBoard");
            Class vcClass = NSClassFromString(@"VolumeControl");
            if (sbClass) {
                MSHookMessageEx(sbClass, @selector(_handlePhysicalButtonEvent:),
                                (IMP)hookHandlePhysicalButtonEvent,
                                (IMP *)&origHandlePhysicalButtonEvent);
            }
            if (vcClass) {
                MSHookMessageEx(vcClass, @selector(applicationDidFinishLaunching:),
                                (IMP)hookApplicationDidFinishLaunching,
                                (IMP *)&origApplicationDidFinishLaunching);
                MSHookMessageEx(vcClass, @selector(increaseVolume),
                                (IMP)hookIncreaseVolume,
                                (IMP *)&origIncreaseVolume);
            }
            NSLog(@"[vcam] SpringBoard hooks initialized");
        }
        else if ([proc isEqualToString:@"mediaserverd"]) {
            // ===== mediaserverd 分支: 引擎 + BW hook =====
            NSLog(@"[vcam] Initializing in mediaserverd...");

            gCore      = [VCamCore sharedCore];
            gPlayer    = [LocalVideoPlayer sharedPlayer];
            gProcessor = gCore.gpuProcessor;
            gNotify    = [VCamNotify new];

            // 注册跨进程 notify
            [gNotify registerForNotification:kVCamLiveChanged callback:^(uint32_t token) {
                NSDictionary *state = [NSDictionary dictionaryWithContentsOfFile:kVCamStatePath];
                gCore.isEnabled = state[@"enabled"] ? [state[@"enabled"] boolValue] : YES;
                NSLog(@"[vcam] Live state changed to: %@", gCore.isEnabled ? @"ON" : @"OFF");
            }];
            [gNotify registerForNotification:kVCamMediaReload callback:^(uint32_t token) {
                [gPlayer loadMediaAtPath:kVCamVideoPath completion:nil];
                NSLog(@"[vcam] Media reload triggered");
            }];

            // 初始加载媒体
            [gPlayer loadMediaAtPath:kVCamVideoPath completion:^(BOOL ok) {
                NSLog(@"[vcam] Initial media load: %@", ok ? @"OK" : @"FAIL");
            }];

            startStatePolling();

            // BW 管线 hook (3 处)
            Class outCls   = NSClassFromString(@"BWNodeOutput");
            Class stillCls = NSClassFromString(@"BWStillImageScalerNode");
            Class encCls   = NSClassFromString(@"BWPhotoEncoderNode");

            if (outCls) {
                MSHookMessageEx(outCls, @selector(emitSampleBuffer:),
                                (IMP)hookEmitSampleBuffer,
                                (IMP *)&origEmitSampleBuffer);
            }
            if (stillCls) {
                MSHookMessageEx(stillCls, @selector(renderSampleBuffer:forInput:),
                                (IMP)hookRenderSBForInput,
                                (IMP *)&origRenderSBForInput);
            }
            if (encCls) {
                MSHookMessageEx(encCls, @selector(renderSampleBuffer:forInput:),
                                (IMP)hookRenderSBForInput,
                                (IMP *)&origRenderSBForInput);
            }

            NSLog(@"[vcam] MediaServerd hooks initialized");
        }
    }
}
