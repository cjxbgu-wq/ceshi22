#import "QMEnhancerView.h"
#import <QuartzCore/QuartzCore.h>

#pragma mark - 常量

static NSString *const kQMSharedSettingsPath = @"/tmp/vcam_enhancer_settings.plist";
static NSString *const kQMRotationKey        = @"videoRotationLV";
static NSString *const kQMLegacyRotationKey  = @"videoRotation";
static NSString *const kQMScaleKey           = @"videoScaleLV";

static const CGFloat kQMScaleSteps[4] = {1.0f, 1.5f, 2.0f, 0.8f};

static const CGFloat kQMPanelW = 240.0;
static const CGFloat kQMPanelH = 284.0;
static const CGFloat kQMTabH   = 36.0;
static const CGFloat kQMPad    = 10.0;
static const CGFloat kQMRowH   = 40.0;
static const CGFloat kQMGap    = 6.0;

// 图片路径改到 /var/mobile（rootless 下可写）
static NSString *const kQMFoxBallPath =
    @"/var/mobile/Library/VCamEnhancer/fox_ball.png";

#pragma mark - QMEnhancerView

@interface QMEnhancerView ()

@property (nonatomic, strong) UIView   *ball;
@property (nonatomic, strong) UIView   *panel;

@property (nonatomic, strong) UIButton *tabControl;
@property (nonatomic, strong) UIButton *tabCardkey;
@property (nonatomic, strong) UIButton *tabNumeric;
@property (nonatomic, assign) NSInteger currentTab;

@property (nonatomic, strong) UIView   *pageControl;
@property (nonatomic, strong) UIButton *pickBtn;
@property (nonatomic, strong) UIButton *banBtn;
@property (nonatomic, strong) UIButton *rotBtn;
@property (nonatomic, strong) UIButton *scaleBtn;
@property (nonatomic, strong) UIButton *closeBtn;

@property (nonatomic, strong) UIView   *pageCardkey;
@property (nonatomic, strong) UIView   *pageNumeric;

@property (nonatomic, assign) BOOL    panelOpen;
@property (nonatomic, assign) CGPoint dragStart;

@end

@implementation QMEnhancerView

#pragma mark - 单例

+ (instancetype)sharedInstance {
    static QMEnhancerView *inst = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        inst = [[QMEnhancerView alloc] initWithFrame:CGRectMake(0, 0, 60, 60)];
    });
    return inst;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        _currentTab = 0;
        _panelOpen  = NO;
        [self buildUI];
    }
    return self;
}

#pragma mark - 构建 UI

- (void)buildUI {
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
                                   initWithTarget:self action:@selector(togglePanel)];
    [_ball addGestureRecognizer:tap];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
                                   initWithTarget:self action:@selector(onDrag:)];
    [_ball addGestureRecognizer:pan];

    _panel = [[UIView alloc] initWithFrame:CGRectMake(70, -kQMPanelH / 2, kQMPanelW, kQMPanelH)];
    _panel.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.95];
    _panel.layer.cornerRadius = 12;
    _panel.layer.borderWidth = 1;
    _panel.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.18].CGColor;
    _panel.hidden = YES;
    [self addSubview:_panel];

    UIView *tabBar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, kQMPanelW, kQMTabH)];
    tabBar.backgroundColor = [UIColor colorWithWhite:0.14 alpha:1.0];
    tabBar.layer.cornerRadius = 12;
    tabBar.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
    [_panel addSubview:tabBar];

    _tabControl = [self makeTab:@"控制" x:0             tag:0];
    _tabCardkey = [self makeTab:@"卡密" x:kQMPanelW/3.0 tag:1];
    _tabNumeric = [self makeTab:@"数字" x:2*kQMPanelW/3.0 tag:2];
    [tabBar addSubview:_tabControl];
    [tabBar addSubview:_tabCardkey];
    [tabBar addSubview:_tabNumeric];

    UIView *tabLine = [[UIView alloc] initWithFrame:CGRectMake(0, kQMTabH - 1, kQMPanelW, 1)];
    tabLine.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    [tabBar addSubview:tabLine];

    CGRect pageFrame = CGRectMake(0, kQMTabH, kQMPanelW, kQMPanelH - kQMTabH);
    _pageControl = [[UIView alloc] initWithFrame:pageFrame];
    _pageCardkey = [[UIView alloc] initWithFrame:pageFrame];
    _pageNumeric = [[UIView alloc] initWithFrame:pageFrame];
    _pageControl.hidden = NO;
    _pageCardkey.hidden = YES;
    _pageNumeric.hidden = YES;
    [_panel addSubview:_pageControl];
    [_panel addSubview:_pageCardkey];
    [_panel addSubview:_pageNumeric];

    [self buildControlPage];

    [self selectTab:0];
    [self refreshAll];
}

#pragma mark - Tab

- (UIButton *)makeTab:(NSString *)title x:(CGFloat)x tag:(NSInteger)tag {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.frame = CGRectMake(x, 0, kQMPanelW / 3.0, kQMTabH);
    b.tag = tag;
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:[UIColor colorWithWhite:0.7 alpha:1] forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    [b addTarget:self action:@selector(onTabTapped:) forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (void)onTabTapped:(UIButton *)sender {
    [self selectTab:sender.tag];
}

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

    _tabControl.titleLabel.font = [UIFont systemFontOfSize:13
                                       weight:(idx == 0 ? UIFontWeightBold : UIFontWeightMedium)];
    _tabCardkey.titleLabel.font = [UIFont systemFontOfSize:13
                                       weight:(idx == 1 ? UIFontWeightBold : UIFontWeightMedium)];
    _tabNumeric.titleLabel.font = [UIFont systemFontOfSize:13
                                       weight:(idx == 2 ? UIFontWeightBold : UIFontWeightMedium)];
}

#pragma mark - 页 1 · 控制

- (void)buildControlPage {
    CGFloat w = kQMPanelW - kQMPad * 2;
    CGFloat y = kQMPad;

    _pickBtn = [self makeRow:@"📁   选择内容"
                       color:[UIColor colorWithRed:0.2 green:0.8 blue:0.4 alpha:1]
                         frame:CGRectMake(kQMPad, y, w, kQMRowH)
                      selector:@selector(onPickVideo)];
    y += kQMRowH + kQMGap;

    _banBtn = [self makeRow:@"⏸️   暂停显示"
                      color:[UIColor colorWithRed:1.0 green:0.35 blue:0.35 alpha:1]
                        frame:CGRectMake(kQMPad, y, w, kQMRowH)
                     selector:@selector(onBanVideo)];
    y += kQMRowH + kQMGap;

    _rotBtn = [self makeRow:@"↻   调整方向"
                      color:[UIColor colorWithRed:0.3 green:0.75 blue:1.0 alpha:1]
                        frame:CGRectMake(kQMPad, y, w, kQMRowH)
                     selector:@selector(onRotate)];
    y += kQMRowH + kQMGap;

    _scaleBtn = [self makeRow:@"⇲   适配大小"
                        color:[UIColor colorWithRed:0.7 green:0.4 blue:1.0 alpha:1]
                          frame:CGRectMake(kQMPad, y, w, kQMRowH)
                       selector:@selector(onScale)];
    y += kQMRowH + kQMGap;

    _closeBtn = [self makeRow:@"▾   收起菜单"
                        color:[UIColor colorWithRed:0.55 green:0.5 blue:0.7 alpha:1]
                          frame:CGRectMake(kQMPad, y, w, kQMRowH)
                       selector:@selector(onHideFloatingBall)];

    [_pageControl addSubview:_pickBtn];
    [_pageControl addSubview:_banBtn];
    [_pageControl addSubview:_rotBtn];
    [_pageControl addSubview:_scaleBtn];
    [_pageControl addSubview:_closeBtn];
}

- (UIButton *)makeRow:(NSString *)title color:(UIColor *)color frame:(CGRect)frame selector:(SEL)sel {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
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

#pragma mark - 面板开关

- (void)togglePanel {
    _panelOpen = !_panelOpen;
    _panel.hidden = !_panelOpen;
    if (_panelOpen) [self refreshAll];
}

#pragma mark - 调用原 VCam 面板 VC

- (UIViewController *)findPanelVC {
    Class cls = NSClassFromString(@"VCamSettingsViewController");
    if (!cls) return nil;
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        UIViewController *root = w.rootViewController;
        if (!root) continue;
        UIViewController *vc = root;
        while (vc) {
            if ([vc isKindOfClass:cls]) return vc;
            if (vc.presentedViewController) vc = vc.presentedViewController;
            else break;
        }
        UIViewController *f = [self findInChildren:root class:cls];
        if (f) return f;
    }
    return nil;
}

- (UIViewController *)findInChildren:(UIViewController *)parent class:(Class)cls {
    for (UIViewController *c in parent.childViewControllers) {
        if ([c isKindOfClass:cls]) return c;
        UIViewController *r = [self findInChildren:c class:cls];
        if (r) return r;
    }
    return nil;
}

- (void)callPanelSelector:(SEL)sel title:(NSString *)title {
    UIViewController *vc = [self findPanelVC];
    if (!vc || ![vc respondsToSelector:sel]) {
        NSLog(@"[VCamEnhancer] 面板 VC 未找到或无方法: %@", title);
        return;
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    [vc performSelector:sel];
#pragma clang diagnostic pop
}

#pragma mark - 控制页动作

- (void)onPickVideo        { [self callPanelSelector:@selector(switchVideoTapped)        title:@"选择内容"]; }
- (void)onBanVideo         { [self callPanelSelector:@selector(restoreCameraTapped)      title:@"暂停显示"]; }
- (void)onHideFloatingBall { [self callPanelSelector:@selector(toggleFloatingBallTapped) title:@"收起菜单"]; }

- (void)onRotate {
    NSMutableDictionary *s = [NSMutableDictionary dictionaryWithDictionary:[self readSettings]];
    NSInteger next = ([self currentRotation] + 90) % 360;
    s[kQMRotationKey]       = @(next);
    s[kQMLegacyRotationKey] = @(0);
    [self writeSettings:s];
    [self refreshAll];
}

- (void)onScale {
    NSMutableDictionary *s = [NSMutableDictionary dictionaryWithDictionary:[self readSettings]];
    CGFloat cur = [self currentScale];
    NSInteger idx = 0;
    for (NSInteger i = 0; i < 4; i++)
        if (fabs(kQMScaleSteps[i] - cur) < 0.01f) { idx = i; break; }
    NSInteger next = (idx + 1) % 4;
    s[kQMScaleKey] = @(kQMScaleSteps[next]);
    [self writeSettings:s];
    [self refreshAll];
}

#pragma mark - 设置读写

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

#pragma mark - 刷新 UI

- (void)refreshAll {
    // 按钮名字固定，不随旋转/缩放数值变化
}

#pragma mark - 点击修复

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *result = [super hitTest:point withEvent:event];
    if (result) return result;
    for (UIView *sub in self.subviews) {
        CGPoint p = [sub convertPoint:point fromView:self];
        if (CGRectContainsPoint(sub.bounds, p)) {
            UIView *r = [sub hitTest:p withEvent:event];
            if (r) return r;
        }
    }
    return nil;
}

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    if ([super pointInside:point withEvent:event]) return YES;
    if (!_panel.hidden) {
        CGPoint p = [_panel convertPoint:point fromView:self];
        if (CGRectContainsPoint(_panel.bounds, p)) return YES;
    }
    return NO;
}

#pragma mark - 拖动

- (void)onDrag:(UIPanGestureRecognizer *)pan {
    UIView *sv = self.superview;
    if (!sv) return;
    CGPoint t = [pan translationInView:sv];

    if (pan.state == UIGestureRecognizerStateBegan) {
        _dragStart = self.center;
    }

    CGPoint c = CGPointMake(_dragStart.x + t.x, _dragStart.y + t.y);
    CGFloat m = 30;
    c.x = MAX(m, MIN(sv.bounds.size.width  - m, c.x));
    c.y = MAX(m, MIN(sv.bounds.size.height - m, c.y));
    self.center = c;
}

#pragma mark - 帧处理（保留调用链，空实现）

+ (void)processFrame:(CVPixelBufferRef)pixelBuffer {
    (void)pixelBuffer;
}

#pragma mark - 显示 + 自动重挂

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

- (void)toggleVisibility {
    self.hidden = !self.hidden;
}

@end
