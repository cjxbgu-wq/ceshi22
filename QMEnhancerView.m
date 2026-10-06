#import "QMEnhancerView.h"
#import <QuartzCore/QuartzCore.h>
#import <PhotosUI/PhotosUI.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>
#import <stdlib.h>

// ============================================================
//  路径（mediaserverd 容器，沙盒可读写）
// ============================================================
static NSString *const kQMSharedSettingsPath = @"/var/mobile/Library/Caches/com.apple.mediaserverd/vc.plist";
static NSString *const kQMMediaDir            = @"/var/mobile/Library/Caches/com.apple.mediaserverd";
static NSString *const kQMRotationKey         = @"videoRotationLV";
static NSString *const kQMScaleKey            = @"videoScaleLV";
static NSString *const kQMEnabledKey          = @"enabled";
static NSString *const kQMActiveSlotKey       = @"activeSlot";
static NSString *const kQMMediaPathKey        = @"mediaPath";
static const char *const kQMNotifyName        = "com.vcam.enhancer.changed";

static const NSInteger kQMSlotCount = 3;
static NSString *const kQMUTIMovie = @"public.movie";
static NSString *const kQMUTIImage = @"public.image";

// ============================================================
//  目录确保
// ============================================================
static void QMEnsureDir(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:kQMMediaDir]) {
        NSError *err = nil;
        [fm createDirectoryAtPath:kQMMediaDir
      withIntermediateDirectories:YES attributes:nil error:&err];
        if (err) NSLog(@"[QMEnhancer] 建目录失败: %@", err);
    }
    // 0777：mediaserverd 沙盒可读写
    [fm setAttributes:@{NSFilePosixPermissions: @0777}
         ofItemAtPath:kQMMediaDir error:nil];
}

// ============================================================
//  设置读写（含原子读改写）
// ============================================================
static NSDictionary *QMReadSettings(void) {
    @try {
        NSDictionary *s = [NSDictionary dictionaryWithContentsOfFile:kQMSharedSettingsPath];
        return s ?: @{};
    } @catch (NSException *e) {}
    return @{};
}

static void QMWriteSettingsLocked(NSDictionary *d) {
    QMEnsureDir();
    BOOL ok = [d writeToFile:kQMSharedSettingsPath atomically:YES];
    if (!ok) {
        NSLog(@"[QMEnhancer] 写 plist 失败");
        return;
    }
    // 0666：mediaserverd 可读
    [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @0666}
                                     ofItemAtPath:kQMSharedSettingsPath error:nil];
    notify_post(kQMNotifyName);
}

static void QMWriteSettings(NSDictionary *d) {
    @synchronized (@"QMSettingsLock") {
        QMWriteSettingsLocked(d);
    }
}

static void QMUpdateSettings(void (^mutator)(NSMutableDictionary *s)) {
    @synchronized (@"QMSettingsLock") {
        NSMutableDictionary *s = [NSMutableDictionary dictionaryWithDictionary:QMReadSettings()];
        mutator(s);
        QMWriteSettingsLocked(s);
    }
}

static NSInteger QMReadRotation(void) {
    NSInteger r = [QMReadSettings()[kQMRotationKey] integerValue];
    return (r == 90 || r == 180 || r == 270) ? r : 0;
}
static CGFloat QMReadScale(void) {
    CGFloat s = [QMReadSettings()[kQMScaleKey] floatValue];
    return (s > 0.05f && s < 20.0f) ? s : 1.0f;
}
static BOOL QMReadEnabled(void) {
    NSDictionary *s = QMReadSettings();
    return s[kQMEnabledKey] ? [s[kQMEnabledKey] boolValue] : YES;
}

// ============================================================
//  槽位路径（多扩展名搜索）
// ============================================================
static NSString *QMSlotPath(NSInteger slot) {
    NSString *base = [kQMMediaDir stringByAppendingPathComponent:
                      [NSString stringWithFormat:@"vcam_slot_%ld", (long)slot]];
    NSArray *exts = @[@"mov", @"mp4", @"png", @"jpg", @"jpeg", @"heic"];
    for (NSString *e in exts) {
        NSString *p = [base stringByAppendingPathExtension:e];
        if ([[NSFileManager defaultManager] fileExistsAtPath:p]) return p;
    }
    return [base stringByAppendingPathExtension:@"mov"];
}

static NSString *QMSlotPathLegacy(NSInteger slot) {
    return [kQMMediaDir stringByAppendingPathComponent:
            [NSString stringWithFormat:@"vcam_slot_%ld", (long)slot]];
}

// 返回槽位文件对应的扩展名（如果存在），否则 nil
static NSString *QMSlotExistingExt(NSInteger slot) {
    NSString *base = [kQMMediaDir stringByAppendingPathComponent:
                      [NSString stringWithFormat:@"vcam_slot_%ld", (long)slot]];
    NSArray *exts = @[@"mov", @"mp4", @"png", @"jpg", @"jpeg", @"heic"];
    for (NSString *e in exts) {
        NSString *p = [base stringByAppendingPathExtension:e];
        if ([[NSFileManager defaultManager] fileExistsAtPath:p]) return e;
    }
    return nil;
}

// ============================================================
//  文件头类型检测
// ============================================================
static BOOL QMPathLooksLikeImage(NSString *path) {
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!fh) return NO;
    NSData *head = [fh readDataOfLength:16];
    [fh closeFile];
    if (head.length < 12) return NO;
    const uint8_t *b = (const uint8_t *)head.bytes;
    if (b[0]==0xFF && b[1]==0xD8 && b[2]==0xFF) return YES;
    if (b[0]==0x89 && b[1]==0x50 && b[2]==0x4E && b[3]==0x47) return YES;
    if (b[0]==0x47 && b[1]==0x49 && b[2]==0x46 && b[3]==0x38) return YES;
    if (b[0]==0x42 && b[1]==0x4D) return YES;
    if (b[0]==0x49 && b[1]==0x49 && b[2]==0x2A && b[3]==0x00) return YES;
    if (b[0]==0x4D && b[1]==0x4D && b[2]==0x00 && b[3]==0x2A) return YES;
    if (b[0]==0x52 && b[1]==0x49 && b[2]==0x46 && b[3]==0x46 &&
        b[8]==0x57 && b[9]==0x45 && b[10]==0x42 && b[11]==0x50) return YES;
    if (b[4]==0x66 && b[5]==0x74 && b[6]==0x79 && b[7]==0x70) {
        if ((b[8]==0x68 && b[9]==0x65 && b[10]==0x69 && b[11]==0x63) ||
            (b[8]==0x6D && b[9]==0x69 && b[10]==0x66 && b[11]==0x31) ||
            (b[8]==0x61 && b[9]==0x76 && b[10]==0x69 && b[11]==0x66) ||
            (b[8]==0x6D && b[9]==0x73 && b[10]==0x66 && b[11]==0x31)) return YES;
    }
    return NO;
}

#pragma mark - 穿透窗口

@interface QMFloatWindow : UIWindow @end
@implementation QMFloatWindow
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)e {
    UIView *hit = [super hitTest:p withEvent:e];
    UIViewController *rvc = self.rootViewController;
    UIView *rview = rvc ? rvc.view : nil;
    if (hit == self || (rview && hit == rview)) return nil;
    return hit;
}
@end

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
    [UIView animateWithDuration:0.18 delay:0 usingSpringWithDamping:0.55
         initialSpringVelocity:0.8 options:UIViewAnimationOptionCurveEaseOut
                     animations:^{ self.transform = CGAffineTransformIdentity; self.alpha = 1.0; }
                     completion:nil];
}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesCancelled:touches withEvent:event];
    self.transform = CGAffineTransformIdentity;
    self.alpha = 1.0;
}
@end

#pragma mark - QMEnhancerView（面板）

@interface QMEnhancerView () <PHPickerViewControllerDelegate>
@property (nonatomic, strong) UIView   *panelView;
@property (nonatomic, strong) UIButton *tabSettingsBtn;
@property (nonatomic, strong) UIButton *tabSlotsBtn;
@property (nonatomic, strong) UIView   *pageSettings;
@property (nonatomic, strong) UIView   *pageSlots;
@property (nonatomic, strong) UILabel  *statusLabel;
@property (nonatomic, strong) NSMutableArray<UIButton *> *slotButtons;
@property (nonatomic, strong) UILabel  *slotHintLabel;
@property (nonatomic, assign) NSInteger selectingSlot;
@property (nonatomic, assign) BOOL isPresentingPicker;
@end

@implementation QMEnhancerView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        QMEnsureDir();
        self.backgroundColor = [UIColor clearColor];
        _selectingSlot = 0;
        _isPresentingPicker = NO;
        [self buildUI];
    }
    return self;
}

- (void)buildUI {
    CGFloat pw = self.bounds.size.width;
    CGFloat ph = self.bounds.size.height;

    UIView *panel = [[UIView alloc] initWithFrame:CGRectMake(0, 0, pw, ph)];
    panel.backgroundColor = [UIColor colorWithRed:0.24 green:0.25 blue:0.27 alpha:0.96];
    panel.layer.cornerRadius = 12;
    panel.layer.masksToBounds = YES;
    [self addSubview:panel];
    self.panelView = panel;

    CGFloat pad = 10, tabH = 36, tabGap = 6;

    CGFloat tabW = (pw - 2*pad - tabGap) / 2.0;
    _tabSettingsBtn = [self makeTabBtn:@"设置" x:pad y:pad w:tabW h:tabH tag:0];
    _tabSlotsBtn    = [self makeTabBtn:@"多槽位" x:pad + tabW + tabGap y:pad w:tabW h:tabH tag:1];
    [panel addSubview:_tabSettingsBtn];
    [panel addSubview:_tabSlotsBtn];

    _statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(pad, pad + tabH + 4, pw - 2*pad, 14)];
    _statusLabel.textAlignment = NSTextAlignmentCenter;
    _statusLabel.font = [UIFont systemFontOfSize:11];
    _statusLabel.textColor = [UIColor colorWithRed:0.6 green:0.95 blue:1.0 alpha:1.0];
    [panel addSubview:_statusLabel];

    CGFloat contentY = pad + tabH + 4 + 14 + 4;
    CGFloat contentH = ph - contentY - pad;
    CGRect contentFrame = CGRectMake(pad, contentY, pw - 2*pad, contentH);
    _pageSettings = [[UIView alloc] initWithFrame:contentFrame];
    _pageSlots    = [[UIView alloc] initWithFrame:contentFrame];
    [panel addSubview:_pageSettings];
    [panel addSubview:_pageSlots];

    [self buildSettingsPage:contentFrame.size];
    [self buildSlotsPage:contentFrame.size];
    [self switchToTab:0];
    [self updateStatusLabel];
}

- (UIButton *)makeTabBtn:(NSString *)title x:(CGFloat)x y:(CGFloat)y w:(CGFloat)w h:(CGFloat)h tag:(NSInteger)tag {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.frame = CGRectMake(x, y, w, h);
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    b.backgroundColor = [UIColor colorWithRed:0.32 green:0.33 blue:0.35 alpha:1];
    b.layer.cornerRadius = 7;
    b.tag = tag;
    [b addTarget:self action:@selector(onTabTapped:) forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (UIButton *)makeRowBtn:(NSString *)title frame:(CGRect)frame color:(UIColor *)color {
    VPMPressButton *b = [VPMPressButton buttonWithType:UIButtonTypeCustom];
    b.frame = frame;
    b.backgroundColor = color ? color : [UIColor colorWithRed:0.42 green:0.43 blue:0.45 alpha:1];
    b.layer.cornerRadius = 8;
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    return b;
}

- (void)buildSettingsPage:(CGSize)size {
    CGFloat w = size.width, gap = 6, y = 0, rowH = 38;
    CGFloat halfW = (w - gap) / 2.0;

    UIButton *toggle = [self makeRowBtn:(QMReadEnabled() ? @"关闭替换" : @"开启替换")
                                  frame:CGRectMake(0, y, halfW, rowH) color:nil];
    toggle.tag = 100;
    [toggle addTarget:self action:@selector(onToggleEnabled:) forControlEvents:UIControlEventTouchUpInside];
    [_pageSettings addSubview:toggle];

    UIButton *disable = [self makeRowBtn:@"禁用替换"
                                   frame:CGRectMake(halfW + gap, y, halfW, rowH)
                                   color:[UIColor colorWithRed:0.55 green:0.30 blue:0.30 alpha:1]];
    [disable addTarget:self action:@selector(onDisable) forControlEvents:UIControlEventTouchUpInside];
    [_pageSettings addSubview:disable];
    y += rowH + gap;

    UIButton *rot = [self makeRowBtn:@"旋转 +90°" frame:CGRectMake(0, y, halfW, rowH) color:nil];
    [rot addTarget:self action:@selector(onRotate) forControlEvents:UIControlEventTouchUpInside];
    [_pageSettings addSubview:rot];

    UIButton *scale = [self makeRowBtn:@"切换缩放" frame:CGRectMake(halfW + gap, y, halfW, rowH) color:nil];
    [scale addTarget:self action:@selector(onScale) forControlEvents:UIControlEventTouchUpInside];
    [_pageSettings addSubview:scale];
    y += rowH + gap;

    UIButton *pick = [self makeRowBtn:@"选择图片 / 视频"
                                frame:CGRectMake(0, y, w, rowH)
                                color:[UIColor colorWithRed:0.2 green:0.6 blue:0.9 alpha:1]];
    [pick addTarget:self action:@selector(onPickMedia) forControlEvents:UIControlEventTouchUpInside];
    [_pageSettings addSubview:pick];
}

- (void)buildSlotsPage:(CGSize)size {
    CGFloat w = size.width, gap = 8, y = 0;
    _slotButtons = [NSMutableArray arrayWithCapacity:kQMSlotCount];
    CGFloat btnW = (w - gap * (kQMSlotCount - 1)) / (CGFloat)kQMSlotCount;
    for (int i = 1; i <= (int)kQMSlotCount; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        b.frame = CGRectMake((i-1) * (btnW + gap), y, btnW, 56);
        [b setTitle:[NSString stringWithFormat:@"%d", i] forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont boldSystemFontOfSize:22];
        b.layer.cornerRadius = 10;
        b.layer.borderWidth = 1.5;
        b.layer.borderColor = [UIColor colorWithRed:0 green:1 blue:1 alpha:1].CGColor;
        b.tag = i;
        [b addTarget:self action:@selector(onSlotTapped:) forControlEvents:UIControlEventTouchUpInside];
        [_pageSlots addSubview:b];
        [_slotButtons addObject:b];
    }
    y += 56 + 8;

    _slotHintLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, y, w, 14)];
    _slotHintLabel.textAlignment = NSTextAlignmentCenter;
    _slotHintLabel.font = [UIFont systemFontOfSize:11];
    _slotHintLabel.textColor = [UIColor colorWithRed:0.6 green:0.95 blue:1.0 alpha:1.0];
    [_pageSlots addSubview:_slotHintLabel];
    y += 14 + 8;

    UIButton *add = [self makeRowBtn:@"添加媒体到空槽位"
                               frame:CGRectMake(0, y, w, 36)
                               color:[UIColor colorWithRed:0.2 green:0.6 blue:0.9 alpha:1]];
    [add addTarget:self action:@selector(onAddToSlot) forControlEvents:UIControlEventTouchUpInside];
    [_pageSlots addSubview:add];
    y += 36 + 6;

    UIButton *clear = [self makeRowBtn:@"清空所有槽位"
                                 frame:CGRectMake(0, y, w, 36)
                                 color:[UIColor colorWithRed:0.55 green:0.30 blue:0.30 alpha:1]];
    [clear addTarget:self action:@selector(onClearSlots) forControlEvents:UIControlEventTouchUpInside];
    [_pageSlots addSubview:clear];

    [self updateSlotButtons];
}

- (void)onTabTapped:(UIButton *)sender { [self switchToTab:sender.tag]; }

- (void)switchToTab:(NSInteger)tab {
    _pageSettings.hidden = (tab != 0);
    _pageSlots.hidden    = (tab != 1);
    UIColor *inactive = [UIColor colorWithRed:0.32 green:0.33 blue:0.35 alpha:1];
    UIColor *active   = [UIColor colorWithRed:0.58 green:0.59 blue:0.61 alpha:1];
    _tabSettingsBtn.backgroundColor = (tab == 0) ? active : inactive;
    _tabSlotsBtn.backgroundColor    = (tab == 1) ? active : inactive;
    [self updateStatusLabel];
}

- (void)updateStatusLabel {
    NSDictionary *s = QMReadSettings();
    BOOL en = s[kQMEnabledKey] ? [s[kQMEnabledKey] boolValue] : YES;
    NSInteger active = [s[kQMActiveSlotKey] integerValue];
    NSInteger rot = QMReadRotation();
    _statusLabel.text = [NSString stringWithFormat:@"%@ | 槽位 %ld | %ld°",
                         en ? @"已开启" : @"已关闭", (long)active, (long)rot];
}

- (NSInteger)nextEmptySlot {
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSInteger i = 1; i <= kQMSlotCount; i++) {
        BOOL exists = NO;
        if (QMSlotExistingExt(i)) exists = YES;
        if ([fm fileExistsAtPath:QMSlotPathLegacy(i)]) exists = YES;
        if (!exists) return i;
    }
    return 0;
}

- (void)updateSlotButtons {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSInteger active = [QMReadSettings()[kQMActiveSlotKey] integerValue];
    NSInteger nextEmpty = [self nextEmptySlot];
    NSInteger filled = 0;
    for (UIButton *b in _slotButtons) {
        NSInteger slot = b.tag;
        BOOL exists = (QMSlotExistingExt(slot) != nil) ||
                      [fm fileExistsAtPath:QMSlotPathLegacy(slot)];
        if (exists) filled++;
        if (exists) {
            b.backgroundColor = [UIColor colorWithRed:0.1 green:0.6 blue:0.85 alpha:1];
            [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
            b.layer.borderWidth = (active == slot) ? 3 : 1.5;
            b.layer.borderColor = (active == slot)
                ? [UIColor colorWithRed:0 green:1 blue:1 alpha:1].CGColor
                : [UIColor colorWithRed:0.2 green:0.9 blue:0.4 alpha:1].CGColor;
        } else {
            b.backgroundColor = [UIColor clearColor];
            [b setTitleColor:[UIColor colorWithWhite:0.5 alpha:1] forState:UIControlStateNormal];
            b.layer.borderWidth = 1.5;
            b.layer.borderColor = (nextEmpty == slot)
                ? [UIColor colorWithRed:1 green:0.85 blue:0 alpha:1].CGColor
                : [UIColor colorWithWhite:0.4 alpha:0.6].CGColor;
        }
    }
    if (filled >= kQMSlotCount)
        _slotHintLabel.text = [NSString stringWithFormat:@"已满 (%ld/%ld)", (long)filled, (long)kQMSlotCount];
    else if (nextEmpty > 0)
        _slotHintLabel.text = [NSString stringWithFormat:@"下一个：槽位 %ld (%ld/%ld)",
                               (long)nextEmpty, (long)filled, (long)kQMSlotCount];
    else
        _slotHintLabel.text = [NSString stringWithFormat:@"%ld/%ld", (long)filled, (long)kQMSlotCount];
    [self updateStatusLabel];
}

#pragma mark - 槽位交互（添加不激活，点击才激活）

// 空槽位：打开 picker 添加（不激活）
// 有内容槽位：激活（按 1 播 1，按 2 播 2，按 3 播 3）
- (void)onSlotTapped:(UIButton *)sender {
    if (_isPresentingPicker) return;
    NSInteger slot = sender.tag;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *ext = QMSlotExistingExt(slot);
    NSString *legacy = QMSlotPathLegacy(slot);
    BOOL exists = (ext != nil) || [fm fileExistsAtPath:legacy];
    if (!exists) {
        // 空槽位 → 添加，不激活
        _selectingSlot = slot;
        [self presentPicker];
        return;
    }
    // 有内容 → 激活
    NSString *realPath = (ext != nil) ? QMSlotPath(slot) : legacy;
    QMUpdateSettings(^(NSMutableDictionary *s) {
        s[kQMActiveSlotKey] = @(slot);
        s[kQMMediaPathKey]  = realPath;
        s[kQMEnabledKey]    = @YES;
    });
    [self updateSlotButtons];
    NSLog(@"[QMEnhancer] 激活槽位 %ld -> %@", (long)slot, realPath);
}

// 添加媒体到空槽位（找第一个空槽 → 打开 picker）
- (void)onAddToSlot {
    if (_isPresentingPicker) return;
    NSInteger next = [self nextEmptySlot];
    if (next == 0) { [self toast:@"所有槽位已满"]; return; }
    _selectingSlot = next;
    [self presentPicker];
}

- (void)onClearSlots {
    if (_isPresentingPicker) return;
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSInteger i = 1; i <= kQMSlotCount; i++) {
        // 清所有扩展名
        NSString *base = [kQMMediaDir stringByAppendingPathComponent:
                          [NSString stringWithFormat:@"vcam_slot_%ld", (long)i]];
        NSArray *exts = @[@"mov", @"mp4", @"png", @"jpg", @"jpeg", @"heic"];
        for (NSString *e in exts) {
            [fm removeItemAtPath:[base stringByAppendingPathExtension:e] error:nil];
        }
        [fm removeItemAtPath:QMSlotPathLegacy(i) error:nil];
    }
    // 清临时文件（所有扩展名）
    NSString *tempBase = [kQMMediaDir stringByAppendingPathComponent:@"vcam_temp"];
    for (NSString *e in @[@"mov", @"mp4", @"png", @"jpg", @"jpeg", @"heic"]) {
        [fm removeItemAtPath:[tempBase stringByAppendingPathExtension:e] error:nil];
    }

    QMUpdateSettings(^(NSMutableDictionary *s) {
        s[kQMActiveSlotKey] = @0;
        s[kQMEnabledKey]    = @NO;
        [s removeObjectForKey:kQMMediaPathKey];
    });
    [self updateSlotButtons];
    [self toast:@"已清空所有槽位"];
}

// 设置 tab 的"选择图片/视频"：临时替换，不占槽位
- (void)onPickMedia {
    if (_isPresentingPicker) return;
    _selectingSlot = 0;   // 0 = 临时替换
    [self presentPicker];
}

#pragma mark - PHPicker

- (void)presentPicker {
    if (_isPresentingPicker) {
        NSLog(@"[QMEnhancer] 已有 picker 正在展示，忽略");
        return;
    }
    UIViewController *host = _hostWindow ? _hostWindow.rootViewController : nil;
    if (!host) {
        _selectingSlot = 0;
        [self toast:@"无法打开相册"];
        return;
    }
    if (host.presentedViewController) {
        NSLog(@"[QMEnhancer] host 已 present 其他 VC，忽略");
        _selectingSlot = 0;
        return;
    }

    if (@available(iOS 15.0, *)) {
        PHPickerConfiguration *cfg = [PHPickerConfiguration new];
        cfg.selectionLimit = 1;
        cfg.filter = [PHPickerFilter anyFilterMatchingSubfilters:@[
            PHPickerFilter.videosFilter,
            PHPickerFilter.imagesFilter
        ]];
        PHPickerViewController *p = [[PHPickerViewController alloc] initWithConfiguration:cfg];
        p.delegate = self;
        _isPresentingPicker = YES;
        [host presentViewController:p animated:YES completion:nil];
    } else if (@available(iOS 14.0, *)) {
        PHPickerConfiguration *cfg = [PHPickerConfiguration new];
        cfg.selectionLimit = 1;
        cfg.filter = [PHPickerFilter videosFilter];
        PHPickerViewController *p = [[PHPickerViewController alloc] initWithConfiguration:cfg];
        p.delegate = self;
        _isPresentingPicker = YES;
        [host presentViewController:p animated:YES completion:nil];
    } else {
        _selectingSlot = 0;
        [self toast:@"系统版本不支持 PHPicker"];
    }
}

// pendingSlot == 0 → 临时替换；>=1 → 添加槽位（不激活）
// 按类型写扩展名：视频 → .mov，图片 → .png
- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    _isPresentingPicker = NO;
    NSInteger pendingSlot = _selectingSlot;
    _selectingSlot = 0;

    __weak typeof(self) ws = self;
    [picker dismissViewControllerAnimated:YES completion:^{
        typeof(ws) ss = ws;
        if (!ss) return;
        if (results.count == 0) return;

        PHPickerResult *res = results.firstObject;
        NSItemProvider *prov = res.itemProvider;

        // 判断类型
        NSString *type = nil;
        if ([prov hasItemConformingToTypeIdentifier:kQMUTIMovie]) type = kQMUTIMovie;
        else if ([prov hasItemConformingToTypeIdentifier:kQMUTIImage]) type = kQMUTIImage;
        if (!type) { [ss toast:@"无法识别媒体类型"]; return; }

        // 按类型选扩展名
        BOOL isVideo = [type isEqualToString:kQMUTIMovie];
        NSString *ext = isVideo ? @"mov" : @"png";

        // 确定目标路径
        NSInteger slot = pendingSlot;
        NSString *dst = nil;
        BOOL isTemp = NO;

        if (slot == 0) {
            // 设置 tab 的"选择图片/视频" → 临时替换
            dst = [kQMMediaDir stringByAppendingPathComponent:
                   [NSString stringWithFormat:@"vcam_temp.%@", ext]];
            isTemp = YES;
        } else if (slot >= 1 && slot <= kQMSlotCount) {
            // 添加槽位 → 只写文件不激活
            dst = [kQMMediaDir stringByAppendingPathComponent:
                   [NSString stringWithFormat:@"vcam_slot_%ld.%@", (long)slot, ext]];
        } else {
            // 兜底：找空槽
            slot = [ss nextEmptySlot];
            if (slot == 0) slot = 1;
            dst = [kQMMediaDir stringByAppendingPathComponent:
                   [NSString stringWithFormat:@"vcam_slot_%ld.%@", (long)slot, ext]];
        }

        NSInteger capturedSlot = slot;
        BOOL capturedTemp = isTemp;
        NSString *capturedDst = dst;
        NSString *capturedExt = ext;

        [prov loadFileRepresentationForTypeIdentifier:type
                                    completionHandler:^(NSURL *url, NSError *err) {
            if (!url) {
                NSLog(@"[QMEnhancer] PHPicker load fail: %@", err);
                return;
            }

            QMEnsureDir();
            NSString *safeTmp = [NSTemporaryDirectory() stringByAppendingPathComponent:
                                 [NSString stringWithFormat:@"qmpick_%ld_%u.%@",
                                  (long)capturedSlot, arc4random(), capturedExt]];
            NSError *cpErr = nil;
            BOOL okSync = [[NSFileManager defaultManager] copyItemAtPath:url.path
                                                                  toPath:safeTmp
                                                                   error:&cpErr];
            if (!okSync) {
                NSLog(@"[QMEnhancer] 临时拷贝失败: %@", cpErr);
                dispatch_async(dispatch_get_main_queue(), ^{
                    typeof(ws) s2 = ws; if (s2) [s2 toast:@"文件读取失败"];
                });
                return;
            }

            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                NSFileManager *fm = [NSFileManager defaultManager];

                // 清理旧的同槽位文件（所有扩展名）
                if (!capturedTemp) {
                    NSString *base = [kQMMediaDir stringByAppendingPathComponent:
                                      [NSString stringWithFormat:@"vcam_slot_%ld", (long)capturedSlot]];
                    NSArray *exts = @[@"mov", @"mp4", @"png", @"jpg", @"jpeg", @"heic"];
                    for (NSString *e in exts) {
                        [fm removeItemAtPath:[base stringByAppendingPathExtension:e] error:nil];
                    }
                    [fm removeItemAtPath:QMSlotPathLegacy(capturedSlot) error:nil];
                } else {
                    // 临时替换：清旧的 temp 所有扩展名
                    NSString *base = [kQMMediaDir stringByAppendingPathComponent:@"vcam_temp"];
                    for (NSString *e in @[@"mov", @"mp4", @"png", @"jpg", @"jpeg", @"heic"]) {
                        [fm removeItemAtPath:[base stringByAppendingPathExtension:e] error:nil];
                    }
                }

                NSError *mvErr = nil;
                if (![fm moveItemAtPath:safeTmp toPath:capturedDst error:&mvErr]) {
                    NSLog(@"[QMEnhancer] 落盘失败: %@", mvErr);
                    [fm removeItemAtPath:safeTmp error:nil];
                    dispatch_async(dispatch_get_main_queue(), ^{
                        typeof(ws) s2 = ws; if (s2) [s2 toast:@"落盘失败"];
                    });
                    return;
                }
                // 0666 权限
                [fm setAttributes:@{NSFilePosixPermissions: @0666} ofItemAtPath:capturedDst error:nil];

                if (capturedTemp) {
                    // 临时替换：切换 mediaPath
                    QMUpdateSettings(^(NSMutableDictionary *s) {
                        s[kQMMediaPathKey] = capturedDst;
                        s[kQMEnabledKey]   = @YES;
                        s[kQMActiveSlotKey] = @0;   // 清掉槽位标记
                    });
                    NSLog(@"[QMEnhancer] 临时替换: %@", capturedDst);
                } else {
                    // 添加槽位：只写文件，不动 activeSlot / mediaPath
                    NSLog(@"[QMEnhancer] 槽位 %ld 已保存(未激活): %@", (long)capturedSlot, capturedDst);
                }

                dispatch_async(dispatch_get_main_queue(), ^{
                    typeof(ws) s2 = ws;
                    if (s2) {
                        [s2 updateSlotButtons];
                        [s2 toast:capturedTemp
                            ? @"临时替换已就绪"
                            : [NSString stringWithFormat:@"槽位 %ld 已保存（点击槽位激活）", (long)capturedSlot]];
                    }
                });
            });
        }];
    }];
}

#pragma mark - 设置按钮

- (void)onToggleEnabled:(UIButton *)b {
    BOOL en = QMReadEnabled();
    QMUpdateSettings(^(NSMutableDictionary *s) { s[kQMEnabledKey] = @(!en); });
    [b setTitle:(!en ? @"关闭替换" : @"开启替换") forState:UIControlStateNormal];
    [self updateStatusLabel];
}

- (void)onDisable {
    QMUpdateSettings(^(NSMutableDictionary *s) { s[kQMEnabledKey] = @NO; });
    [self updateStatusLabel];
    [self toast:@"替换已禁用"];
}

- (void)onRotate {
    NSInteger cur = QMReadRotation();
    NSInteger next = (cur + 90) % 360;
    QMUpdateSettings(^(NSMutableDictionary *s) { s[kQMRotationKey] = @(next); });
    [self updateStatusLabel];
}

- (void)onScale {
    static const CGFloat steps[4] = {1.0f, 1.5f, 2.0f, 0.8f};
    CGFloat cur = QMReadScale();
    NSInteger idx = 0;
    for (NSInteger i = 0; i < 4; i++)
        if (fabs(steps[i] - cur) < 0.01f) { idx = i; break; }
    CGFloat next = steps[(idx + 1) % 4];
    QMUpdateSettings(^(NSMutableDictionary *s) { s[kQMScaleKey] = @(next); });
}

#pragma mark - 提示

- (void)toast:(NSString *)msg {
    UIViewController *host = _hostWindow ? _hostWindow.rootViewController : nil;
    if (!host) return;
    if (host.presentedViewController) {
        NSLog(@"[QMEnhancer] toast 跳过：host 已有 presentedViewController");
        return;
    }
    UIAlertController *a = [UIAlertController alertControllerWithTitle:nil
                                                               message:msg
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [host presentViewController:a animated:YES completion:nil];
}

@end

#pragma mark - QMFloatBall（悬浮球）

@interface QMFloatBall ()
@property (nonatomic, strong) QMFloatWindow  *win;
@property (nonatomic, strong) UIButton       *ball;
@property (nonatomic, strong) QMEnhancerView *panel;
@property (nonatomic, assign) int retryCount;
@property (nonatomic, assign) BOOL creating;
@property (nonatomic, assign) NSUInteger retryToken;
@end

@implementation QMFloatBall

+ (instancetype)shared {
    static QMFloatBall *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [QMFloatBall new]; });
    return s;
}

- (void)show {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.win || self.creating) return;
        self.creating = YES;
        self.retryCount = 0;
        self.retryToken++;
        NSUInteger myToken = self.retryToken;
        [self createWindowWithToken:myToken];
    });
}

- (void)hide {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.retryToken++;
        self.creating = NO;
        self.retryCount = 0;
        [self.panel removeFromSuperview];
        self.panel = nil;
        [self.ball removeFromSuperview];
        self.ball = nil;
        self.win.hidden = YES;
        self.win = nil;
    });
}

- (void)createWindowWithToken:(NSUInteger)token {
    if (!self.creating) return;
    if (token != self.retryToken) return;

    UIWindowScene *scene = nil;
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]] &&
            s.activationState == UISceneActivationStateForegroundActive) {
            scene = (UIWindowScene *)s; break;
        }
    }
    if (!scene) {
        for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
            if ([s isKindOfClass:[UIWindowScene class]]) { scene = (UIWindowScene *)s; break; }
        }
    }
    if (!scene) {
        self.retryCount++;
        if (self.retryCount > 60) {
            NSLog(@"[QMEnhancer] 悬浮球超时，放弃创建");
            self.creating = NO;
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (self.creating && token == self.retryToken) {
                [self createWindowWithToken:token];
            }
        });
        return;
    }

    CGRect screen = scene.coordinateSpace.bounds;
    self.win = [[QMFloatWindow alloc] initWithWindowScene:scene];
    self.win.frame = screen;
    self.win.windowLevel = UIWindowLevelAlert + 100;
    self.win.backgroundColor = [UIColor clearColor];
    self.win.hidden = NO;

    UIViewController *rootVC = [UIViewController new];
    rootVC.view.backgroundColor = [UIColor clearColor];
    rootVC.view.userInteractionEnabled = YES;
    self.win.rootViewController = rootVC;

    CGFloat bs = 50;
    CGFloat bx = screen.size.width - bs - 20;
    CGFloat by = screen.size.height / 2 - bs / 2;
    self.ball = [UIButton buttonWithType:UIButtonTypeSystem];
    self.ball.frame = CGRectMake(bx, by, bs, bs);
    self.ball.backgroundColor = [UIColor colorWithRed:0.35 green:0.36 blue:0.38 alpha:0.92];
    self.ball.layer.cornerRadius = bs / 2;
    self.ball.layer.borderWidth = 2;
    self.ball.layer.borderColor = [UIColor colorWithWhite:0.8 alpha:1].CGColor;
    UIImage *icon = [UIImage systemImageNamed:@"video.fill"];
    if (icon) {
        [self.ball setImage:icon forState:UIControlStateNormal];
        self.ball.tintColor = [UIColor whiteColor];
    } else {
        [self.ball setTitle:@"●" forState:UIControlStateNormal];
        [self.ball setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        self.ball.titleLabel.font = [UIFont boldSystemFontOfSize:22];
    }
    [self.ball addTarget:self action:@selector(ballTapped) forControlEvents:UIControlEventTouchUpInside];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
        initWithTarget:self action:@selector(ballDragged:)];
    [self.ball addGestureRecognizer:pan];
    [rootVC.view addSubview:self.ball];

    self.creating = NO;
}

- (void)ballTapped {
    if (self.panel) { [self dismissPanel]; return; }
    [self showPanel];
}

- (void)ballDragged:(UIPanGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan && self.panel) [self dismissPanel];
    CGPoint t = [g translationInView:self.win];
    CGPoint c = CGPointMake(self.ball.center.x + t.x, self.ball.center.y + t.y);
    CGFloat hw = self.ball.frame.size.width / 2;
    CGFloat hh = self.ball.frame.size.height / 2;
    c.x = MAX(hw, MIN(self.win.bounds.size.width - hw, c.x));
    c.y = MAX(hh, MIN(self.win.bounds.size.height - hh, c.y));
    self.ball.center = c;
    [g setTranslation:CGPointZero inView:self.win];
    [self updatePanelPosition];
}

- (void)showPanel {
    if (!self.win) return;
    CGSize panelSize = CGSizeMake(280, 320);
    self.panel = [[QMEnhancerView alloc] initWithFrame:CGRectMake(0, 0, panelSize.width, panelSize.height)];
    self.panel.hostWindow = self.win;
    [self updatePanelPosition];
    [self.win.rootViewController.view addSubview:self.panel];
}

- (void)dismissPanel {
    [self.panel removeFromSuperview];
    self.panel = nil;
}

- (void)updatePanelPosition {
    if (!self.panel || !self.ball || !self.win) return;
    CGFloat w = self.panel.frame.size.width;
    CGFloat h = self.panel.frame.size.height;
    CGRect ballF = self.ball.frame;
    CGFloat screenW = self.win.bounds.size.width;
    CGFloat screenH = self.win.bounds.size.height;
    CGFloat px = 5, py = 5;
    BOOL found = NO;

    CGFloat rightX = CGRectGetMaxX(ballF) + 8;
    if (rightX + w <= screenW - 5) {
        CGFloat ty = ballF.origin.y + ballF.size.height/2 - h/2;
        if (ty < 5) ty = 5;
        if (ty + h > screenH - 5) ty = screenH - h - 5;
        px = rightX; py = ty; found = YES;
    }
    if (!found) {
        CGFloat leftX = ballF.origin.x - w - 8;
        if (leftX >= 5) {
            CGFloat ty = ballF.origin.y + ballF.size.height/2 - h/2;
            if (ty < 5) ty = 5;
            if (ty + h > screenH - 5) ty = screenH - h - 5;
            px = leftX; py = ty; found = YES;
        }
    }
    if (!found) {
        CGFloat upY = ballF.origin.y - h - 8;
        if (upY >= 5) {
            CGFloat tx = ballF.origin.x + ballF.size.width/2 - w/2;
            if (tx < 5) tx = 5;
            if (tx + w > screenW - 5) tx = screenW - w - 5;
            px = tx; py = upY; found = YES;
        }
    }
    if (!found) {
        CGFloat downY = CGRectGetMaxY(ballF) + 8;
        if (downY + h <= screenH - 5) {
            CGFloat tx = ballF.origin.x + ballF.size.width/2 - w/2;
            if (tx < 5) tx = 5;
            if (tx + w > screenW - 5) tx = screenW - w - 5;
            px = tx; py = downY; found = YES;
        }
    }
    if (!found) {
        px = 5;
        CGFloat ballCY = ballF.origin.y + ballF.size.height/2;
        CGFloat topY = 5, botY = screenH - h - 5;
        py = (fabs(ballCY - (topY + h/2)) > fabs(ballCY - (botY + h/2))) ? botY : topY;
    }
    self.panel.frame = CGRectMake(px, py, w, h);
}

@end
