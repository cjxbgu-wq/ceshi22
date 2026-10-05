#import "QMEnhancerView.h"
#import <QuartzCore/QuartzCore.h>

static NSString *const kQMSharedSettingsPath = @"/tmp/vcam_enhancer_settings.plist";
static NSString *const kQMRotationKey        = @"videoRotationLV";
static NSString *const kQMLegacyRotationKey  = @"videoRotation";
static NSString *const kQMScaleKey           = @"videoScaleLV";
static const CGFloat kQMScaleSteps[4] = {1.0f, 1.5f, 2.0f, 0.8f};
static NSString *const kQMFoxBallPath = @"/var/mobile/Library/VCamEnhancer/fox_ball.png";

@interface VPMPressButton : UIButton @end
@implementation VPMPressButton
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesBegan:touches withEvent:event];
    [UIView animateWithDuration:0.08 animations:^{
        self.transform = CGAffineTransformMakeScale(0.94, 0.94);
        self.alpha = 0.8;
    }];
}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesEnded:touches withEvent:event];
    [UIView animateWithDuration:0.18 delay:0 usingSpringWithDamping:0.55 initialSpringVelocity:0.8
                        options:UIViewAnimationOptionCurveEaseOut animations:^{
        self.transform = CGAffineTransformIdentity;
        self.alpha = 1.0;
    } completion:nil];
}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesCancelled:touches withEvent:event];
    self.transform = CGAffineTransformIdentity;
    self.alpha = 1.0;
}
@end

@interface QMEnhancerView ()

// 悬浮球模式（在 SpringBoard 上）
@property (nonatomic, strong) UIView *ball;

// 面板模式（被挂到 VCamSettingsViewController 上时用）
@property (nonatomic, strong) UIButton *tabControl;
@property (nonatomic, strong) UIButton *tabCardkey;
@property (nonatomic, strong) UIButton *tabNumeric;
@property (nonatomic, assign) NSInteger currentTab;
@property (nonatomic, strong) UIView *pageControl;
@property (nonatomic, strong) UIButton *pickBtn;
@property (nonatomic, strong) UIButton *banBtn;
@property (nonatomic, strong) UIButton *rotBtn;
@property (nonatomic, strong) UIButton *scaleBtn;
@property (nonatomic, strong) UIButton *closeBtn;
@property (nonatomic, strong) UIView *pageCardkey;
@property (nonatomic, strong) UIView *pageNumeric;

@property (nonatomic, assign) BOOL isBallMode;
@property (nonatomic, assign) CGPoint dragStart;

@end

@implementation QMEnhancerView

+ (instancetype)sharedInstance {
    static QMEnhancerView *inst = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        inst = [[QMEnhancerView alloc] initWithFrame:CGRectMake(0, 0, 60, 60)];
        inst.isBallMode = YES;
    });
    return inst;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        // 悬浮球模式默认只显示球
        if (self.isBallMode || frame.size.width <= 60) {
            [self buildBall];
        } else {
            [self buildPanel];
        }
    }
    return self;
}

#pragma mark - 悬浮球 UI

- (void)buildBall {
    _ball = [[UIView alloc] initWithFrame:self.bounds];
    _ball.backgroundColor = [UIColor clearColor];
    _ball.userInteractionEnabled = YES;
    _ball.layer.cornerRadius = self.bounds.size.width / 2;
    _ball.layer.masksToBounds = NO;
    _ball.layer.shadowColor = [UIColor colorWithRed:0.3 green:0.75 blue:1.0 alpha:1.0].CGColor;
    _ball.layer.shadowRadius = 10.0;
    _ball.layer.shadowOpacity = 0.7;
    _ball.layer.shadowOffset = CGSizeZero;
    [self addSubview:_ball];

    UIImage *foxImg = [UIImage imageWithContentsOfFile:kQMFoxBallPath];
    if (!foxImg) foxImg = [UIImage imageNamed:@"fox_ball"];
    if (foxImg) {
        UIImageView *iv = [[UIImageView alloc] initWithFrame:_ball.bounds];
        iv.image = foxImg;
        iv.contentMode = UIViewContentModeScaleAspectFill;
        iv.layer.cornerRadius = _ball.bounds.size.width / 2;
        iv.layer.masksToBounds = YES;
        [_ball addSubview:iv];
    } else {
        CAGradientLayer *grad = [CAGradientLayer layer];
        grad.frame = _ball.bounds;
        grad.cornerRadius = _ball.bounds.size.width / 2;
        grad.colors = @[
            (id)[UIColor colorWithRed:0.70 green:0.92 blue:1.00 alpha:1].CGColor,
            (id)[UIColor colorWithRed:0.35 green:0.70 blue:0.95 alpha:1].CGColor,
            (id)[UIColor colorWithRed:0.10 green:0.35 blue:0.70 alpha:1].CGColor
        ];
        grad.startPoint = CGPointMake(0.3, 0.1);
        grad.endPoint   = CGPointMake(0.7, 1.0);
        [_ball.layer addSublayer:grad];

        UILabel *fox = [[UILabel alloc] initWithFrame:_ball.bounds];
        fox.text = @"🦊";
        fox.font = [UIFont systemFontOfSize:28];
        fox.textAlignment = NSTextAlignmentCenter;
        [_ball addSubview:fox];
    }

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
                                   initWithTarget:self action:@selector(onBallTapped)];
    [_ball addGestureRecognizer:tap];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
                                   initWithTarget:self action:@selector(onDrag:)];
    [_ball addGestureRecognizer:pan];
}

- (void)onBallTapped {
    NSLog(@"[VCamEnhancer] 悬浮球被点击，弹出原版面板");
    VCamShowSettingsPanel();
}

- (void)onDrag:(UIPanGestureRecognizer *)pan {
    UIView *sv = self.superview;
    if (!sv) return;
    CGPoint t = [pan translationInView:sv];
    if (pan.state == UIGestureRecognizerStateBegan) _dragStart = self.center;
    CGPoint c = CGPointMake(_dragStart.x + t.x, _dragStart.y + t.y);
    CGFloat m = 30;
    c.x = MAX(m, MIN(sv.bounds.size.width  - m, c.x));
    c.y = MAX(m, MIN(sv.bounds.size.height - m, c.y));
    self.center = c;
}

#pragma mark - 面板 UI（挂到 VCamSettingsViewController 上时）

- (void)buildPanel {
    self.backgroundColor = [UIColor colorWithWhite:0.08 alpha:1.0];
    _currentTab = 0;

    CGFloat pw = 320, ph = 300;
    CGFloat sx = (self.bounds.size.width  - pw) / 2.0;
    CGFloat sy = (self.bounds.size.height - ph) / 2.0;
    if (sx < 10) sx = 10;
    if (sy < 60) sy = 60;

    UIView *panel = [[UIView alloc] initWithFrame:CGRectMake(sx, sy, pw, ph)];
    panel.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.98];
    panel.layer.cornerRadius = 12;
    panel.layer.borderWidth = 1;
    panel.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.18].CGColor;
    [self addSubview:panel];

    UIView *tabBar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, pw, 36)];
    tabBar.backgroundColor = [UIColor colorWithWhite:0.14 alpha:1.0];
    tabBar.layer.cornerRadius = 12;
    tabBar.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
    [panel addSubview:tabBar];

    _tabControl = [self makeTab:@"控制" x:0 tag:0];
    _tabCardkey = [self makeTab:@"卡密" x:pw/3.0 tag:1];
    _tabNumeric = [self makeTab:@"数字" x:2*pw/3.0 tag:2];
    [tabBar addSubview:_tabControl];
    [tabBar addSubview:_tabCardkey];
    [tabBar addSubview:_tabNumeric];

    CGRect pageFrame = CGRectMake(0, 36, pw, ph - 36);
    _pageControl = [[UIView alloc] initWithFrame:pageFrame];
    _pageCardkey = [[UIView alloc] initWithFrame:pageFrame];
    _pageNumeric = [[UIView alloc] initWithFrame:pageFrame];
    _pageControl.hidden = NO;
    _pageCardkey.hidden = YES;
    _pageNumeric.hidden = YES;
    [panel addSubview:_pageControl];
    [panel addSubview:_pageCardkey];
    [panel addSubview:_pageNumeric];

    [self buildControlPage:pw];
    [self selectTab:0];
}

- (UIButton *)makeTab:(NSString *)title x:(CGFloat)x tag:(NSInteger)tag {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.frame = CGRectMake(x, 0, 320.0/3.0, 36);
    b.tag = tag;
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:[UIColor colorWithWhite:0.7 alpha:1] forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    [b addTarget:self action:@selector(onTabTapped:) forControlEvents:UIControlEventTouchUpInside];
    return b;
}
- (void)onTabTapped:(UIButton *)sender { [self selectTab:sender.tag]; }

- (void)selectTab:(NSInteger)idx {
    _currentTab = idx;
    _pageControl.hidden = (idx != 0);
    _pageCardkey.hidden = (idx != 1);
    _pageNumeric.hidden = (idx != 2);
    UIColor *on  = [UIColor colorWithRed:0.2 green:0.7 blue:1.0 alpha:1];
    UIColor *off = [UIColor colorWithWhite:0.7 alpha:1];
    [_tabControl setTitleColor:(idx == 0 ? on : off) forState:UIControlStateNormal];
    [_tabCardkey setTitleColor:(idx == 1 ? on : off) forState:UIControlStateNormal];
    [_tabNumeric setTitleColor:(idx == 2 ? on : off) forState:UIControlStateNormal];
}

- (void)buildControlPage:(CGFloat)pw {
    CGFloat w = pw - 20, y = 10, rowH = 44, gap = 6, x = 10;
    _pickBtn = [self makeRow:@"📁   选择内容" color:[UIColor colorWithRed:0.2 green:0.8 blue:0.4 alpha:1]
                       frame:CGRectMake(x, y, w, rowH) selector:@selector(onPickVideo)];
    y += rowH + gap;
    _banBtn = [self makeRow:@"⏸️   暂停显示" color:[UIColor colorWithRed:1.0 green:0.35 blue:0.35 alpha:1]
                      frame:CGRectMake(x, y, w, rowH) selector:@selector(onBanVideo)];
    y += rowH + gap;
    _rotBtn = [self makeRow:@"↻   调整方向" color:[UIColor colorWithRed:0.3 green:0.75 blue:1.0 alpha:1]
                      frame:CGRectMake(x, y, w, rowH) selector:@selector(onRotate)];
    y += rowH + gap;
    _scaleBtn = [self makeRow:@"⇲   适配大小" color:[UIColor colorWithRed:0.7 green:0.4 blue:1.0 alpha:1]
                        frame:CGRectMake(x, y, w, rowH) selector:@selector(onScale)];
    y += rowH + gap;
    _closeBtn = [self makeRow:@"▾   收起菜单" color:[UIColor colorWithRed:0.55 green:0.5 blue:0.7 alpha:1]
                        frame:CGRectMake(x, y, w, rowH) selector:@selector(onHideFloatingBall)];
    [_pageControl addSubview:_pickBtn];
    [_pageControl addSubview:_banBtn];
    [_pageControl addSubview:_rotBtn];
    [_pageControl addSubview:_scaleBtn];
    [_pageControl addSubview:_closeBtn];
}

- (VPMPressButton *)makeRow:(NSString *)title color:(UIColor *)color frame:(CGRect)frame selector:(SEL)sel {
    VPMPressButton *b = [VPMPressButton buttonWithType:UIButtonTypeCustom];
    b.frame = frame;
    b.backgroundColor = [color colorWithAlphaComponent:0.22];
    b.layer.cornerRadius = 8;
    b.layer.borderWidth = 1;
    b.layer.borderColor = [color colorWithAlphaComponent:0.9].CGColor;
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    b.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    b.titleEdgeInsets = UIEdgeInsetsMake(0, 12, 0, 0);
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (void)callPanelSelector:(SEL)sel title:(NSString *)title {
    UIViewController *vc = self.panelVC;
    if (!vc) { NSLog(@"[VCamEnhancer] ❌ %@: panelVC nil", title); return; }
    if (![vc respondsToSelector:sel]) { NSLog(@"[VCamEnhancer] ❌ %@: 无方法", title); return; }
    @try {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [vc performSelector:sel];
#pragma clang diagnostic pop
        NSLog(@"[VCamEnhancer] ✅ %@ 已调用", title);
    } @catch (NSException *e) {
        NSLog(@"[VCamEnhancer] ❌ %@ 异常: %@", title, e);
    }
}

- (void)onPickVideo        { [self callPanelSelector:@selector(switchVideoTapped)   title:@"选择内容"]; }
- (void)onBanVideo         { [self callPanelSelector:@selector(restoreCameraTapped) title:@"暂停显示"]; }
- (void)onHideFloatingBall { [self callPanelSelector:@selector(dismissPanel)        title:@"收起菜单"]; }

- (void)onRotate {
    NSMutableDictionary *s = [NSMutableDictionary dictionaryWithDictionary:[self readSettings]];
    NSInteger next = ([self currentRotation] + 90) % 360;
    s[kQMRotationKey]       = @(next);
    s[kQMLegacyRotationKey] = @(0);
    [self writeSettings:s];
}
- (void)onScale {
    NSMutableDictionary *s = [NSMutableDictionary dictionaryWithDictionary:[self readSettings]];
    CGFloat cur = [self currentScale];
    NSInteger idx = 0;
    for (NSInteger i = 0; i < 4; i++)
        if (fabs(kQMScaleSteps[i] - cur) < 0.01f) { idx = i; break; }
    s[kQMScaleKey] = @(kQMScaleSteps[(idx + 1) % 4]);
    [self writeSettings:s];
}

- (NSDictionary *)readSettings {
    NSDictionary *s = [NSDictionary dictionaryWithContentsOfFile:kQMSharedSettingsPath];
    return s ?: @{};
}
- (void)writeSettings:(NSDictionary *)s {
    [s writeToFile:kQMSharedSettingsPath atomically:YES];
}
- (NSInteger)currentRotation {
    NSInteger r = [[self readSettings][kQMRotationKey] integerValue];
    return (r == 90 || r == 180 || r == 270) ? r : 0;
}
- (CGFloat)currentScale {
    CGFloat s = [[self readSettings][kQMScaleKey] floatValue];
    return (s > 0.05f && s < 20.0f) ? s : 1.0f;
}

+ (void)processFrame:(CVPixelBufferRef)pixelBuffer { (void)pixelBuffer; }

- (void)showInWindow:(UIWindow *)window {
    if (self.superview) [self removeFromSuperview];
    self.frame = CGRectMake(15, window.bounds.size.height / 2, 60, 60);
    [window addSubview:self];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(reAdd)
                                                 name:UIApplicationDidBecomeActiveNotification
                                               object:nil];
    [NSTimer scheduledTimerWithTimeInterval:5.0 target:self
                                   selector:@selector(reAdd) userInfo:nil repeats:YES];
}
- (void)reAdd {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *w = nil;
        for (UIWindow *x in [UIApplication sharedApplication].windows) {
            if (x.isKeyWindow) { w = x; break; }
        }
        if (!w) return;
        if (self.superview != w) {
            [self removeFromSuperview];
            [w addSubview:self];
        }
        [w bringSubviewToFront:self];
    });
}

- (void)toggleVisibility { self.hidden = !self.hidden; }

@end
