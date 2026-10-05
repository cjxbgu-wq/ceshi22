#import <UIKit/UIKit.h>
#import <CoreVideo/CoreVideo.h>

@interface QMEnhancerView : UIView

@property (nonatomic, assign) NSInteger rotation;
@property (nonatomic, assign) CGFloat zoomScale;

+ (instancetype)sharedInstance;

// 保留调用链，内部空实现（旋转/缩放由 Tweak.xm 帧钩子完成）
+ (void)processFrame:(CVPixelBufferRef)pixelBuffer;

- (void)showInWindow:(UIWindow *)window;
- (void)toggleVisibility;

@end
