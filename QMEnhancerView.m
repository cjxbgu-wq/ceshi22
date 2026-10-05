#import "QMEnhancerView.h"
#import <QuartzCore/QuartzCore.h>

static NSString *const kQMSharedSettingsPath = @"/tmp/vcam_enhancer_settings.plist";
static NSString *const kQMRotationKey        = @"videoRotationLV";
static NSString *const kQMLegacyRotationKey  = @"videoRotation";
static NSString *const kQMScaleKey           = @"videoScaleLV";

static const CGFloat kQMScaleSteps[4] = {1.0f, 1.5f, 2.0f, 0.8f};

#pragma mark - 按压反馈按钮

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

#pragma mark - QMEnhancerView

@interface QMEnhancerView ()

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

@end

@implementation QMEnhancerView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor colorWithWhite:0.08 alpha:1.0];
        _currentTab = 0;
        [self buildUI];
    }
    return self;
}

- (void)buildUI {
    CGFloat pw = 320, ph = 300;
    CGFloat sx = (self.bounds.size.width  - pw) / 2.0;
    CGFloat sy = (self.bounds.size.height - ph) / 2.0;
    if (sx < 10) sx = 10;
    if (sy < 60) sy = 60;

    UIView *panel = [[UIView alloc] initWithFrame:CGRectMake(sx, sy, pw, ph)];
    panel.backgroundColor = [UIColor colorWithWhite:0.10 alpha:0.98];
    panel.layer.cornerRadius = 12;
    panel.layer.borderWidth = 1;
    panel.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.18].CGColor;
    [self addSubview:panel];

    UIView *tabBar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, pw, 36)];
    tabBar.backgroundColor = [UIColor colorWithWhite:0.14 alpha:1.0];
    tabBar.layer.cornerRadius = 12;
    tabBar.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
    [panel addSubview:tabBar];

    _tabControl = [self makeTab:@"控制" x:0        tag:0 pw:pw];
    _tabCardkey = [self makeTab:@"卡密" x:pw/3.0   tag:1 pw:pw];
    _tabNumeric = [self makeTab:@"数字" x:2*pw/3.0 tag:2 pw:pw];
    [tabBar addSubview:_tabControl];
    [tabBar addSubview:_tabCardkey];
    [tabBar addSubview:_tabNumeric];

    UIView *tabLine = [[UIView alloc] initWithFrame:CGRectMake(0, 35, pw, 1)];
    tabLine.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    [tabBar addSubview:tabLine];

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

- (UIButton *)makeTab:(NSString *)title x:(CGFloat)x tag:(NSInteger)tag pw:(CGFloat)pw {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.frame = CGRectMake(x, 0, pw / 3.0, 36);
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
    _tabControl.titleLabel.font = [UIFont systemFontOfSize:13 weight:(idx == 0 ? UIFontWeightBold : UIFontWeightMedium)];
    _tabCardkey.titleLabel.font = [UIFont systemFontOfSize:13 weight:(idx == 1 ? UIFontWeightBold : UIFontWeightMedium)];
    _tabNumeric.titleLabel.font = [UIFont systemFontOfSize:13 weight:(idx == 2 ? UIFontWeightBold : UIFontWeightMedium)];
}

- (void)buildControlPage:(CGFloat)pw {
    CGFloat w = pw - 20;
    CGFloat y = 10;
    CGFloat rowH = 44;
    CGFloat gap = 6;
    CGFloat x = 10;

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

#pragma mark - 转发到原版 VC（照抄老代码）

- (void)callPanelSelector:(SEL)sel title:(NSString *)title {
    UIViewController *vc = self.panelVC;
    if (!vc) { NSLog(@"[VCamEnhancer] ❌ %@: panelVC nil", title); return; }
    if (![vc respondsToSelector:sel]) {
        NSLog(@"[VCamEnhancer] ❌ %@: 原版 VC 无方法 %@", title, NSStringFromSelector(sel));
        return;
    }
    @try {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [vc performSelector:sel];
#pragma clang diagnostic pop
        NSLog(@"[VCamEnhancer] ✅ %@ 已转发到原版 VC", title);
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
    NSInteger next = (idx + 1) % 4;
    s[kQMScaleKey] = @(kQMScaleSteps[next]);
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

@end
