#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
VCam Tweak 补丁脚本（修正版）
=============================
在构建前对 Tweak.xm 打补丁，源码始终保持原样。

修补清单（9 项）：
  1. 去除 vcamplus 痕迹 → 目录 .cfgdata / 标识符 com.system.assets
  2. 浏览器注入时机 AtDocumentStart(0) → AtDocumentEnd(1)
  3. UI 精简（正则锚定，不依赖空格）
  4. 新增镜像按钮 tag=10
  5. 【编译修复】FWCtrl 补 ivar：_panelVisible / _panel / _window
  6. 【编译修复】FWCtrl 补空实现 updateHighlight
  7. 【健壮性】tag:8 按钮标题切换后刷新
  8. 【健壮性】VCamMenu 单例防重复弹层
  9. 【数据迁移】旧目录 vcamplus → .cfgdata 自动迁移（可选）
"""

import re
import sys
from pathlib import Path

ROOT  = Path(__file__).resolve().parent.parent
TWEAK = ROOT / "Tweak.xm"

if not TWEAK.exists():
    print(f"[!] 找不到 {TWEAK}", file=sys.stderr)
    sys.exit(1)

src = TWEAK.read_text(encoding="utf-8")

# ---------- 幂等：已打过就跳过 ----------
if "Library/.cfgdata" in src and "tag:10" in src and "_panelVisible;" in src:
    print("[*] 已打过补丁，跳过（幂等）")
    sys.exit(0)

original = src
report   = []

# =================================================================
# 1. 去除 vcamplus 痕迹
# =================================================================
src = src.replace(
    '#define VCAM_DIR   @"/var/jb/var/mobile/Library/vcamplus"',
    '#define VCAM_DIR   @"/var/jb/var/mobile/Library/.cfgdata"',
)
if "Library/.cfgdata" in src:
    report.append("✓ 目录 vcamplus → .cfgdata")

# 明文标识符
src = src.replace(
    'initWithFormatIdentifier:@"com.vcamplus.edit"',
    'initWithFormatIdentifier:@"com.system.assets"',
)
# _ds() 加密版：com.vcamplus.edit → com.system.assets
# 原: \x54\x58\x5A\x19\x41\x54\x56\x5A\x47\x5B\x42\x44\x19\x52\x53\x5E\x43 (17)
# 新: \x54\x58\x5A\x19\x44\x4E\x44\x43\x52\x5A\x19\x56\x44\x44\x52\x43\x44 (17)
src = src.replace(
    r'_ds("\x54\x58\x5A\x19\x41\x54\x56\x5A\x47\x5B\x42\x44\x19\x52\x53\x5E\x43",17)',
    r'_ds("\x54\x58\x5A\x19\x44\x4E\x44\x43\x52\x5A\x19\x56\x44\x44\x52\x43\x44",17)',
)
if "com.system.assets" in src:
    report.append("✓ 标识符 com.vcamplus.edit → com.system.assets")

# =================================================================
# 2. 浏览器注入时机修复
# =================================================================
before = src.count("initWithSource:js injectionTime:0 forMainFrameOnly:NO")
src = src.replace(
    "initWithSource:js injectionTime:0 forMainFrameOnly:NO",
    "initWithSource:js injectionTime:1 forMainFrameOnly:NO",
)
before2 = src.count("initWithSource:lazyJS injectionTime:0 forMainFrameOnly:NO")
src = src.replace(
    "initWithSource:lazyJS injectionTime:0 forMainFrameOnly:NO",
    "initWithSource:lazyJS injectionTime:1 forMainFrameOnly:NO",
)
if before or before2:
    report.append(f"✓ WKUserScript injectionTime 0→1 (×{before + before2})")

# =================================================================
# 5+6. 【编译修复】FWCtrl 补 ivar + updateHighlight
# =================================================================
OLD_FW = """@implementation FWCtrl {
    UIButton *_colorInjectBtn;
    NSTimer *_colorSampleTimer;
    UIView *_colorIndicator;
}"""
NEW_FW = """@implementation FWCtrl {
    UIButton *_colorInjectBtn;
    NSTimer *_colorSampleTimer;
    UIView *_colorIndicator;
    /* [PATCH] 补声明：原源码 doHide 引用但未声明，导致编译失败 */
    BOOL _panelVisible;
    UIView *_panel;
    UIWindow *_window;
}"""
if OLD_FW in src:
    src = src.replace(OLD_FW, NEW_FW)
    report.append("✓ FWCtrl ivar 补齐（修复编译错误）")
else:
    print("[!] 未找到 FWCtrl @implementation 块", file=sys.stderr)
    sys.exit(2)

# FWCtrl 加 updateHighlight 空方法（防止 unrecognized selector）
OLD_SHOW = """+ (void)show {
    return;
}"""
NEW_SHOW = """+ (void)show {
    return;
}
/* [PATCH] 原源码调用但未实现，避免 unrecognized selector 崩溃 */
- (void)updateHighlight { }"""
if OLD_SHOW in src:
    src = src.replace(OLD_SHOW, NEW_SHOW, 1)
    report.append("✓ FWCtrl updateHighlight 空实现补齐")

# =================================================================
# 8. 【健壮性】VCamMenu 单例防重复弹层
# =================================================================
OLD_SHOWMENU_CALL = """static void vcam_showMenu(void) {
    if (gBootTime > 0 && (CACurrentMediaTime() - gBootTime) < 5.0) {
        vcam_log(@"showMenu: boot cooldown, skipping");
        return;
    }
    UIViewController *topVC = vcam_topVC();
    if (!topVC || [topVC isKindOfClass:[UIAlertController class]]) return;"""
NEW_SHOWMENU_CALL = """static void vcam_showMenu(void) {
    if (gBootTime > 0 && (CACurrentMediaTime() - gBootTime) < 5.0) {
        vcam_log(@"showMenu: boot cooldown, skipping");
        return;
    }
    UIViewController *topVC = vcam_topVC();
    if (!topVC || [topVC isKindOfClass:[UIAlertController class]]) return;
    /* [PATCH] 防重复：已弹出 VCamMenu 就忽略本次触发 */
    if ([topVC isKindOfClass:NSClassFromString(@"VCamMenu")]) {
        vcam_log(@"showMenu: already presented, skip");
        return;
    }"""
if OLD_SHOWMENU_CALL in src:
    src = src.replace(OLD_SHOWMENU_CALL, NEW_SHOWMENU_CALL, 1)
    report.append("✓ vcam_showMenu 防重复弹层")

# =================================================================
# 3. UI 精简（正则锚定）
# =================================================================
# 用正则把 viewDidLoad 里从 "CGFloat iy = 54;" 到 "取消" 按钮整块替换
ui_pattern = re.compile(
    r'\n    CGFloat iy = 54;\n.*?tag:9 x:\(cw - bw\) / 2 y:by w:bw h:bh\]\];',
    re.DOTALL
)

NEW_UI = """
    /* [PATCH] 精简 UI：仅保留 5 项核心功能 + 取消 */
    CGFloat iy = 60;
    CGFloat bw = (cw - 20 - 20 - 10) / 2;
    CGFloat bx1 = 20, bx2 = 20 + bw + 10;
    CGFloat by = iy, bh = 42, gap = 10;
    [card addSubview:[self mkBtn:@"📹  选择视频" color:vcam_rgb(34, 197, 94) tag:1 x:bx1 y:by w:bw h:bh]];
    [card addSubview:[self mkBtn:@"🖼  选择图片" color:vcam_rgb(59, 130, 246) tag:2 x:bx2 y:by w:bw h:bh]]; by += bh + gap;
    [card addSubview:[self mkBtn:@"🔄  旋转" color:vcam_rgb(139, 92, 246) tag:4 x:bx1 y:by w:bw h:bh]];
    [card addSubview:[self mkBtn:(gVideoFlipH ? @"🪞  镜像 ON" : @"🪞  镜像 OFF") color:vcam_rgb(245, 158, 11) tag:10 x:bx2 y:by w:bw h:bh]]; by += bh + gap;
    [card addSubview:[self mkBtn:(_on ? @"⏹  禁用视频" : @"▶  启用视频") color:(_on ? vcam_rgb(239, 68, 68) : vcam_rgb(34, 197, 94)) tag:8 x:bx1 y:by w:bw h:bh]];
    [card addSubview:[self mkBtn:@"✖  取消" color:vcam_rgb(107, 114, 128) tag:9 x:bx2 y:by w:bw h:bh]];"""

new_src, n = ui_pattern.subn(NEW_UI, src, count=1)
if n != 1:
    print("[!] UI 块正则未匹配到（源码结构可能不同）", file=sys.stderr)
    sys.exit(3)
src = new_src
report.append("✓ UI 精简为 5 项 + 取消")

# 卡片高度适配
src = src.replace("CGFloat ch = 380;", "CGFloat ch = 260;")
report.append("✓ 卡片高度 380 → 260")

# =================================================================
# 4. 新增镜像按钮处理（tag == 10）
# =================================================================
OLD_BTN_BLOCK = """    if (tag == 9) {
        [self dismissViewControllerAnimated:YES completion:nil];
        return;
    }
    if (tag == 4) { [[FWCtrl shared] btnTap:vcam_fwBtn(101)]; return; } // 视频旋转
    if (tag == 5) { // 彩色注入 (白色原点吸取屏幕颜色)
        [[FWCtrl shared] btnTap:vcam_fwBtn(110)];
        [self syncColorDot];
        return;
    }
    if (tag == 6) { [[FWCtrl shared] btnTap:vcam_fwBtn(111)]; return; } // 彩色增强
    if (tag == 7) { [[FWCtrl shared] btnTap:vcam_fwBtn(112)]; return; } // 彩色减少"""

NEW_BTN_BLOCK = """    if (tag == 9) {
        [self dismissViewControllerAnimated:YES completion:nil];
        return;
    }
    if (tag == 10) { // [PATCH] 镜像开关
        gVideoFlipH = !gVideoFlipH;
        [b setTitle:(gVideoFlipH ? @"🪞  镜像 ON" : @"🪞  镜像 OFF") forState:UIControlStateNormal];
        vcam_writeControls();
        vcam_log([NSString stringWithFormat:@"Mirror: %@", gVideoFlipH ? @"ON" : @"OFF"]);
        return;
    }
    if (tag == 4) { [[FWCtrl shared] btnTap:vcam_fwBtn(101)]; return; } // 视频旋转"""

if OLD_BTN_BLOCK in src:
    src = src.replace(OLD_BTN_BLOCK, NEW_BTN_BLOCK, 1)
    report.append("✓ 镜像按钮 tag=10 注入")
else:
    print("[!] btnTap 块未匹配", file=sys.stderr)
    sys.exit(4)

# =================================================================
# 7. 【健壮性】tag:8 切换后刷新按钮标题
# =================================================================
OLD_TAG8 = """            } else {
                gTweakEnabled = YES;
                [@"1" writeToFile:VCAM_FLAG atomically:YES encoding:NSUTF8StringEncoding error:nil];
            }
        }
    });
}"""
NEW_TAG8 = """            } else {
                gTweakEnabled = YES;
                [@"1" writeToFile:VCAM_FLAG atomically:YES encoding:NSUTF8StringEncoding error:nil];
            }
            /* [PATCH] 刷新 tag:8 按钮标题，反映最新开关状态 */
            __weak UIButton *wb = b;
            dispatch_async(dispatch_get_main_queue(), ^{
                UIButton *sb = wb;
                if (!sb) return;
                BOOL on = gTweakEnabled;
                [sb setTitle:(on ? @"⏹  禁用视频" : @"▶  启用视频") forState:UIControlStateNormal];
                [sb setBackgroundColor:(on ? vcam_rgb(239, 68, 68) : vcam_rgb(34, 197, 94))];
            });
        }
    });
}"""
if OLD_TAG8 in src:
    src = src.replace(OLD_TAG8, NEW_TAG8, 1)
    report.append("✓ tag:8 标题自动刷新")

# =================================================================
# 9. 旧目录数据迁移（一次性）
# =================================================================
OLD_MIGRATE_ANCHOR = """        [[NSFileManager defaultManager] createDirectoryAtPath:VCAM_DIR
            withIntermediateDirectories:YES attributes:nil error:nil];
        vcam_log([NSString stringWithFormat:@"CONSTRUCTOR: proc=%@ bid=%@", proc, bid]);"""
NEW_MIGRATE_ANCHOR = """        [[NSFileManager defaultManager] createDirectoryAtPath:VCAM_DIR
            withIntermediateDirectories:YES attributes:nil error:nil];
        /* [PATCH] 一次性迁移旧 vcamplus 目录 → .cfgdata */
        {
            NSFileManager *fm = [NSFileManager defaultManager];
            NSString *oldDir = @"/var/jb/var/mobile/Library/vcamplus";
            if ([fm fileExistsAtPath:oldDir] && ![fm fileExistsAtPath:VCAM_DIR @"/video.mp4"]) {
                NSError *mvErr = nil;
                NSArray *contents = [fm contentsOfDirectoryAtPath:oldDir error:nil];
                for (NSString *item in contents) {
                    [fm moveItemAtPath:[oldDir stringByAppendingPathComponent:item]
                                 toPath:[VCAM_DIR stringByAppendingPathComponent:item]
                                  error:&mvErr];
                }
                vcam_log(@"migrated old vcamplus → .cfgdata");
            }
        }
        vcam_log([NSString stringWithFormat:@"CONSTRUCTOR: proc=%@ bid=%@", proc, bid]);"""
if OLD_MIGRATE_ANCHOR in src:
    src = src.replace(OLD_MIGRATE_ANCHOR, NEW_MIGRATE_ANCHOR, 1)
    report.append("✓ 旧目录数据迁移")

# =================================================================
# 写回
# =================================================================
if src == original:
    print("[!] 没有产生任何变更", file=sys.stderr)
    sys.exit(5)

TWEAK.write_text(src, encoding="utf-8")
print(f"[+] 已打补丁：{TWEAK}")
for line in report:
    print("   ", line)
print(f"[+] 共 {len(report)} 项修改成功")
