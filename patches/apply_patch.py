#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
VCam Tweak 补丁脚本 v3（深度审计修复版）
=======================================
修复清单（11 项）：
  1. 品牌处理 3 处（含编码通知名 com.vcamplus.* → com.system.*）
  2. 浏览器注入时机 0 → 1
  3. UI 精简（正则 + 行级回退双保险）
  4. 镜像按钮 tag=10
  5. 【编译修复】FWCtrl ivar 补齐
  6. 【编译修复】updateHighlight 空实现
  7. 【链接修复】VCAM_FRIEND_JS_* weak 桩
  8. 【数据】flock 保护的一次性迁移
  9. 幂等性
 10. UI 失败时给出明确锚点
 11. 多文件定位交由 entry.sh 处理
"""

import os, re, sys
from pathlib import Path

# -----------------------------------------------------------------
# 定位 Tweak.xm
# -----------------------------------------------------------------
def locate_tweak() -> Path:
    env = os.environ.get("VCAM_TWEAK_PATH")
    if env:
        p = Path(env)
        if not p.is_absolute(): p = Path.cwd() / p
        if p.exists(): return p
        print(f"[!] VCAM_TWEAK_PATH 不存在：{p}", file=sys.stderr)

    root = Path(__file__).resolve().parent.parent
    for c in [
        root / "Tweak.xm", root / "tweak.xm",
        root / "src" / "Tweak.xm", root / "tweak" / "Tweak.xm",
        root / "Tweak" / "Tweak.xm", root / "VCamPlus" / "Tweak.xm",
        root / "vcam" / "Tweak.xm", root / "vcamplus" / "Tweak.xm",
        root / "Sources" / "Tweak.xm",
    ]:
        if c.exists(): return c

    for p in sorted(root.rglob("Tweak.xm")):
        s = str(p)
        if any(x in s for x in ("/.git/", "/.theos/", "/packages/", "/obj/")):
            continue
        return p
    print("[!] 未找到 Tweak.xm", file=sys.stderr)
    sys.exit(1)


TWEAK = locate_tweak()
print(f"[*] 目标源码：{TWEAK}")

src = TWEAK.read_text(encoding="utf-8")

# ---------- 幂等 ----------
if "Library/.cfgdata" in src and "tag:10" in src and "_panelVisible;" in src \
        and "VCAM_FRIEND_JS_STREAM_GET(void) { return" in src:
    print("[*] 已打过补丁，跳过")
    sys.exit(0)

original, report = src, []

# =================================================================
# 1. 品牌处理（3 处）
# =================================================================
# 1a. 目录
src = src.replace(
    '#define VCAM_DIR   @"/var/jb/var/mobile/Library/vcamplus"',
    '#define VCAM_DIR   @"/var/jb/var/mobile/Library/.cfgdata"',
)
if "Library/.cfgdata" in src: report.append("✓ 目录 → .cfgdata")

# 1b. 明文 formatIdentifier
src = src.replace(
    'initWithFormatIdentifier:@"com.vcamplus.edit"',
    'initWithFormatIdentifier:@"com.system.assets"',
)

# 1c. _ds() 加密版 com.vcamplus.* → com.system.*
# 加密前缀：_ds("\x54\x58\x5A\x19..." (c-o-m-.)
# 原 "vcamplus" 段：\x41\x54\x56\x5A\x47\x5B\x42\x44
# 新 "system"   段：\x44\x4E\x44\x43\x52\x5A
BRAND_OLD_PREFIX = r'\x54\x58\x5A\x19\x41\x54\x56\x5A\x47\x5B\x42\x44'
BRAND_NEW_PREFIX = r'\x54\x58\x5A\x19\x44\x4E\x44\x43\x52\x5A'
n_brand = src.count(BRAND_OLD_PREFIX)
src = src.replace(BRAND_OLD_PREFIX, BRAND_NEW_PREFIX)
if n_brand: report.append(f"✓ 编码通知名 com.vcamplus.* → com.system.* (×{n_brand})")

if "com.system.assets" in src: report.append("✓ 明文标识符 → com.system.assets")

# =================================================================
# 2. 浏览器注入时机
# =================================================================
n1 = src.count("initWithSource:js injectionTime:0 forMainFrameOnly:NO")
src = src.replace(
    "initWithSource:js injectionTime:0 forMainFrameOnly:NO",
    "initWithSource:js injectionTime:1 forMainFrameOnly:NO")
n2 = src.count("initWithSource:lazyJS injectionTime:0 forMainFrameOnly:NO")
src = src.replace(
    "initWithSource:lazyJS injectionTime:0 forMainFrameOnly:NO",
    "initWithSource:lazyJS injectionTime:1 forMainFrameOnly:NO")
if n1 or n2: report.append(f"✓ injectionTime 0→1 (×{n1+n2})")

# =================================================================
# 5 + 6. 编译修复
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
    /* [PATCH] 原源码 doHide 引用但未声明 — 修复编译错误 */
    BOOL _panelVisible;
    UIView *_panel;
    UIWindow *_window;
}"""
if OLD_FW in src:
    src = src.replace(OLD_FW, NEW_FW)
    report.append("✓ FWCtrl ivar 补齐")
else:
    print("[!] FWCtrl @implementation 块未找到", file=sys.stderr); sys.exit(2)

OLD_SHOW = "+ (void)show {\n    return;\n}"
NEW_SHOW = ("+ (void)show {\n    return;\n}\n"
            "/* [PATCH] 原源码调用但未实现 — 防止 unrecognized selector */\n"
            "- (void)updateHighlight { }")
if OLD_SHOW in src:
    src = src.replace(OLD_SHOW, NEW_SHOW, 1)
    report.append("✓ updateHighlight 空实现补齐")

# =================================================================
# 7. 【链接修复】VCAM_FRIEND_JS_* weak 桩
# =================================================================
if "VCAM_FRIEND_JS_STREAM_GET(void) { return" not in src:
    # 插入到 vcam_buildWebCamJS 前
    anchor = "static NSString *vcam_buildWebCamJS(void) {"
    stubs = (
        "/* [PATCH] 弱符号桩：如仓库未提供 WebCamJS 定义，用桩保证链接通过 */\n"
        "__attribute__((weak)) NSString *VCAM_FRIEND_JS_STREAM_GET(void) "
        "{ return @\"/*stream-stub*/\"; }\n"
        "__attribute__((weak)) NSString *VCAM_FRIEND_JS_VIDEO_GET(void) "
        "{ return @\"/*video-stub*/\"; }\n"
        "__attribute__((weak)) NSString *VCAM_FRIEND_JS_IMAGE_GET(void) "
        "{ return @\"/*image-stub*/\"; }\n\n"
    )
    if anchor in src:
        src = src.replace(anchor, stubs + anchor, 1)
        report.append("✓ VCAM_FRIEND_JS_* weak 桩注入")

# =================================================================
# 8. 防重复弹层
# =================================================================
OLD_SM = """    UIViewController *topVC = vcam_topVC();
    if (!topVC || [topVC isKindOfClass:[UIAlertController class]]) return;
"""
NEW_SM = """    UIViewController *topVC = vcam_topVC();
    if (!topVC || [topVC isKindOfClass:[UIAlertController class]]) return;
    /* [PATCH] 防重复 */
    if ([topVC isKindOfClass:NSClassFromString(@"VCamMenu")]) {
        vcam_log(@"showMenu: already presented, skip");
        return;
    }
"""
if OLD_SM in src:
    src = src.replace(OLD_SM, NEW_SM, 1)
    report.append("✓ vcam_showMenu 防重复")

# =================================================================
# 3. UI 精简（正则 + 行级回退）
# =================================================================
NEW_UI_LINES = [
    "    /* [PATCH] 精简 UI：5 项核心 + 取消 */",
    "    CGFloat iy = 60;",
    "    CGFloat bw = (cw - 20 - 20 - 10) / 2;",
    "    CGFloat bx1 = 20, bx2 = 20 + bw + 10;",
    "    CGFloat by = iy, bh = 42, gap = 10;",
    '    [card addSubview:[self mkBtn:@"📹  选择视频" color:vcam_rgb(34, 197, 94) tag:1 x:bx1 y:by w:bw h:bh]];',
    '    [card addSubview:[self mkBtn:@"🖼  选择图片" color:vcam_rgb(59, 130, 246) tag:2 x:bx2 y:by w:bw h:bh]]; by += bh + gap;',
    '    [card addSubview:[self mkBtn:@"🔄  旋转" color:vcam_rgb(139, 92, 246) tag:4 x:bx1 y:by w:bw h:bh]];',
    '    [card addSubview:[self mkBtn:(gVideoFlipH ? @"🪞  镜像 ON" : @"🪞  镜像 OFF") color:vcam_rgb(245, 158, 11) tag:10 x:bx2 y:by w:bw h:bh]]; by += bh + gap;',
    '    [card addSubview:[self mkBtn:(_on ? @"⏹  禁用视频" : @"▶  启用视频") color:(_on ? vcam_rgb(239, 68, 68) : vcam_rgb(34, 197, 94)) tag:8 x:bx1 y:by w:bw h:bh]];',
    '    [card addSubview:[self mkBtn:@"✖  取消" color:vcam_rgb(107, 114, 128) tag:9 x:bx2 y:by w:bw h:bh]];',
]
NEW_UI = "\n" + "\n".join(NEW_UI_LINES)

ui_pat = re.compile(
    r'\n    CGFloat iy = 54;\n.*?tag:9 x:\(cw - bw\) / 2 y:by w:bw h:bh\]\];',
    re.DOTALL)
new_src, n = ui_pat.subn(NEW_UI, src, count=1)
if n == 1:
    src = new_src
    report.append("✓ UI 精简（正则命中）")
else:
    print("[!] UI 正则未命中，尝试行级回退...", file=sys.stderr)
    lines = src.split("\n")
    start = next((i for i, l in enumerate(lines) if "CGFloat iy = 54;" in l), None)
    end   = next((i for i, l in enumerate(lines) if "tag:9 x:(cw - bw)" in l), None)
    if start is None or end is None:
        print("[!] UI 行级回退也失败", file=sys.stderr); sys.exit(3)
    src = "\n".join(lines[:start] + NEW_UI_LINES + lines[end+1:])
    report.append("✓ UI 精简（行级回退）")

src = src.replace("CGFloat ch = 380;", "CGFloat ch = 260;")
report.append("✓ 卡片高度 380 → 260")

# =================================================================
# 4. 镜像按钮 tag=10
# =================================================================
OLD_BTN = """    if (tag == 9) {
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

NEW_BTN = """    if (tag == 9) {
        [self dismissViewControllerAnimated:YES completion:nil];
        return;
    }
    if (tag == 10) { /* [PATCH] 镜像 */
        gVideoFlipH = !gVideoFlipH;
        [b setTitle:(gVideoFlipH ? @"🪞  镜像 ON" : @"🪞  镜像 OFF") forState:UIControlStateNormal];
        vcam_writeControls();
        vcam_log([NSString stringWithFormat:@"Mirror: %@", gVideoFlipH ? @"ON" : @"OFF"]);
        return;
    }
    if (tag == 4) { [[FWCtrl shared] btnTap:vcam_fwBtn(101)]; return; } // 视频旋转"""

if OLD_BTN in src:
    src = src.replace(OLD_BTN, NEW_BTN, 1)
    report.append("✓ 镜像按钮 tag=10")
else:
    print("[!] btnTap 块未匹配", file=sys.stderr); sys.exit(4)

# =================================================================
# 9. tag:8 刷新
# =================================================================
OLD_T8 = """            } else {
                gTweakEnabled = YES;
                [@"1" writeToFile:VCAM_FLAG atomically:YES encoding:NSUTF8StringEncoding error:nil];
            }
        }
    });
}"""
NEW_T8 = """            } else {
                gTweakEnabled = YES;
                [@"1" writeToFile:VCAM_FLAG atomically:YES encoding:NSUTF8StringEncoding error:nil];
            }
            /* [PATCH] 刷新 tag:8 标题 */
            __weak UIButton *wb = b;
            dispatch_async(dispatch_get_main_queue(), ^{
                UIButton *sb = wb; if (!sb) return;
                BOOL on = gTweakEnabled;
                [sb setTitle:(on ? @"⏹  禁用视频" : @"▶  启用视频") forState:UIControlStateNormal];
                [sb setBackgroundColor:(on ? vcam_rgb(239, 68, 68) : vcam_rgb(34, 197, 94))];
            });
        }
    });
}"""
if OLD_T8 in src:
    src = src.replace(OLD_T8, NEW_T8, 1)
    report.append("✓ tag:8 标题自动刷新")

# =================================================================
# 10. flock 保护的目录迁移
# =================================================================
OLD_MIG = """        [[NSFileManager defaultManager] createDirectoryAtPath:VCAM_DIR
            withIntermediateDirectories:YES attributes:nil error:nil];
        vcam_log([NSString stringWithFormat:@"CONSTRUCTOR: proc=%@ bid=%@", proc, bid]);"""
NEW_MIG = """        [[NSFileManager defaultManager] createDirectoryAtPath:VCAM_DIR
            withIntermediateDirectories:YES attributes:nil error:nil];
        /* [PATCH] flock 保护的一次性迁移 vcamplus → .cfgdata */
        {
            int lockFd = open("/var/jb/var/mobile/Library/.vcam_migrate.lock",
                              O_CREAT | O_RDWR, 0666);
            if (lockFd >= 0 && flock(lockFd, LOCK_EX | LOCK_NB) == 0) {
                @try {
                    NSFileManager *fm = [NSFileManager defaultManager];
                    NSString *oldDir = @"/var/jb/var/mobile/Library/vcamplus";
                    if ([fm fileExistsAtPath:oldDir]) {
                        NSArray *items = [fm contentsOfDirectoryAtPath:oldDir error:nil];
                        for (NSString *it in items) {
                            NSString *s = [oldDir stringByAppendingPathComponent:it];
                            NSString *d = [VCAM_DIR stringByAppendingPathComponent:it];
                            if (![fm fileExistsAtPath:d]) {
                                [fm moveItemAtPath:s toPath:d error:nil];
                            }
                        }
                        [fm removeItemAtPath:oldDir error:nil];
                        vcam_log(@"migrated vcamplus → .cfgdata");
                    }
                } @finally { close(lockFd); }
            }
        }
        vcam_log([NSString stringWithFormat:@"CONSTRUCTOR: proc=%@ bid=%@", proc, bid]);"""
if OLD_MIG in src:
    src = src.replace(OLD_MIG, NEW_MIG, 1)
    report.append("✓ flock 迁移")

# =================================================================
# 写回
# =================================================================
if src == original:
    print("[!] 无变更", file=sys.stderr); sys.exit(5)

# 确保 <sys/file.h> 已导入（flock 需要）
if "#include <sys/file.h>" not in src:
    src = src.replace("#include <string.h>",
                      "#include <string.h>\n#include <sys/file.h>", 1)

TWEAK.write_text(src, encoding="utf-8")
print(f"[+] 补丁成功：{TWEAK}")
for r in report: print("   ", r)
print(f"[+] 共 {len(report)} 项")
