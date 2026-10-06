#import <UIKit/UIKit.h>

@interface QMFloatBall : NSObject
+ (instancetype)shared;
- (void)show;
- (void)hide;
@end

@interface QMEnhancerView : UIView
// 由 QMFloatBall 注入，用于 present PHPicker
@property (nonatomic, weak) UIWindow *hostWindow;
// 兼容旧接口（保留，勿删）
@property (nonatomic, weak) UIViewController *panelVC;
@end
