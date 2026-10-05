#import <UIKit/UIKit.h>
#import <CoreVideo/CoreVideo.h>

@interface QMEnhancerView : UIView

// 由 Tweak.xm 挂载时设置，指向原版 VCamSettingsViewController
@property (nonatomic, weak) UIViewController *panelVC;

+ (void)processFrame:(CVPixelBufferRef)pixelBuffer;

@end
