#import <UIKit/UIKit.h>
#import <CoreVideo/CoreVideo.h>

@interface QMEnhancerView : UIView

@property (nonatomic, assign) NSInteger rotation;
@property (nonatomic, assign) CGFloat zoomScale;

+ (instancetype)sharedInstance;

+ (void)processFrame:(CVPixelBufferRef)pixelBuffer;

- (void)showInWindow:(UIWindow *)window;
- (void)toggleVisibility;

@end
