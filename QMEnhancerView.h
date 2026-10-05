#import <UIKit/UIKit.h>
#import <CoreVideo/CoreVideo.h>

// 由 Tweak.xm 提供，UI 层调用以弹出原版面板
#ifdef __cplusplus
extern "C" {
#endif
void VCamShowSettingsPanel(void);
#ifdef __cplusplus
}
#endif

@interface QMEnhancerView : UIView

// 由 Tweak.xm 挂载面板时设置，指向原版 VC
@property (nonatomic, weak) UIViewController *panelVC;

+ (instancetype)sharedInstance;

+ (void)processFrame:(CVPixelBufferRef)pixelBuffer;

- (void)showInWindow:(UIWindow *)window;
- (void)toggleVisibility;

@end
