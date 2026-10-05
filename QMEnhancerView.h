#import <UIKit/UIKit.h>
#import <CoreVideo/CoreVideo.h>

// 由 Tweak.xm 提供，返回原版 VCamSettingsViewController 实例
#ifdef __cplusplus
extern "C" {
#endif
UIViewController *VCamGetSettingsVC(void);
#ifdef __cplusplus
}
#endif

@interface QMEnhancerView : UIView

@property (nonatomic, assign) NSInteger rotation;
@property (nonatomic, assign) CGFloat zoomScale;

+ (instancetype)sharedInstance;

+ (void)processFrame:(CVPixelBufferRef)pixelBuffer;

- (void)showInWindow:(UIWindow *)window;
- (void)toggleVisibility;

@end
