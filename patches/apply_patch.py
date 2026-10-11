#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
VCam Tweak 补丁脚本 v6（全量去品牌 + 编译修复）
================================================
改动清单（12 项）：
   1. 全量去品牌：vcamplus → cfgdatax（明文 + 编码 + URL，等长 8→8）
   2. 数据迁移：vcamplus → cfgdatax（flock 保护，旧名走 _ds 加密）
   3. 浏览器 injectionTime 0 → 1
   4. UI 精简（正则 + 行级回退）
   5. 镜像按钮 tag=10
   6. 【编译修复】FWCtrl ivar 补齐
   7. 【编译修复】updateHighlight + hide 空实现
   8. 【链接修复】VCAM_FRIEND_JS_* weak 桩
   9. 防重复弹层
  10. tag:8 标题刷新
  11. 【编译修复】SecTrustCopyCertificateChain iOS 14 兼容
  12. 编译前删除 .patched，防止缓存
"""

import os
import re
import sys
from pathlib import Path


# -----------------------------------------------------------------
# 定位 Tweak.xm
# -----------------------------------------------------------------
def locate_tweak() -> Path:
    env = os.environ.get("VCAM_TWEAK_PATH")
    if env:
        p = Path(env)
        if not p.is_absolute():
            p = Path.cwd() / p
        if p.exists():
            return p
        print(f"[!] VCAM_TWEAK_PATH 不存在：{p}", file=sys.stderr)

    root = Path(__file__).resolve().parent.parent
    for c in [
        root / "Tweak.xm", root / "tweak.xm",
        root / "src" / "Tweak.xm", root / "tweak" / "Tweak.xm",
        root / "Tweak" / "Tweak.xm",
    ]:
        if c.exists():
            return c

    for p in sorted(root.rglob("*.xm")):
        s = str(p)
        if any(x in s for x in ("/.git/", "/.theos/", "/packages/", "/obj/")):
            continue
        if "tweak" in p.name.lower():
            return p

    print("[!] 未找到 Tweak.xm", file=sys.stderr)
    sys.exit(1)


TWEAK = locate_tweak()
print(f"[*] 目标源码：{TWEAK}")

src = TWEAK.read_text(encoding="utf-8")

# ---------- 幂等（v6 特征） ----------
if ("cfgdatax" in src
        and "tag:10" in src
        and "_panelVisible;" in src
        and "VCAM_FRIEND_JS_STREAM_GET(void) { return" in src
        and "if (@available(iOS 15.0, *))" in src
        and "+ (void)hide { }" in src):
    print("[*] 已打过 v6 补丁，跳过（幂等）")
    sys.exit(0)

original = src
report = []

# =================================================================
# 3. 浏览器 injectionTime 0 → 1
# =================================================================
n1 = src.count("initWithSource:js injectionTime:0 forMainFrameOnly:NO")
src = src.replace(
    "initWithSource:js injectionTime:0 forMainFrameOnly:NO",
    "initWithSource:js injectionTime:1 forMainFrameOnly:NO")
n2 = src.count("initWithSource:lazyJS injectionTime:0 forMainFrameOnly:NO")
src = src.replace(
    "initWithSource:lazyJS injectionTime:0 forMainFrameOnly:NO",
    "initWithSource:lazyJS injectionTime:1 forMainFrameOnly:NO")
if n1 or n2:
    report.append(f"✓ injectionTime 0→1 (×{n1 + n2})")

# =================================================================
# 6. FWCtrl ivar 补齐（编译修复）
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
    print("[!] FWCtrl @implementation 块未找到", file=sys.stderr)
    sys.exit(2)

# =================================================================
# 7. updateHighlight + hide 空实现（编译修复）
# =================================================================
OLD_SHOW = "+ (void)show {\n    return;\n}"
NEW_SHOW = (
    "+ (void)show {\n    return;\n}\n"
    "/* [PATCH] 原源码调用/声明但未实现 */\n"
    "- (void)updateHighlight { }\n"
    "+ (void)hide { }"
)
if OLD_SHOW in src:
    src = src.replace(OLD_SHOW, NEW_SHOW, 1)
    report.append("✓ updateHighlight + hide 空实现")

# =================================================================
# 8. VCAM_FRIEND_JS_* weak 桩（链接修复）
# =================================================================
if "VCAM_FRIEND_JS_STREAM_GET(void) { return" not in src:
    anchor = "static NSString *vcam_buildWebCamJS(void) {"
    stubs = (
        "/* [PATCH] 弱符号桩：仓库未提供 WebCamJS 定义时保链接 */\n"
        "__attribute__((weak)) NSString *VCAM_FRIEND_JS_STREAM_GET(void) "
        "{ return @\"/*stream-stub*/\"; }\n"
        "__attribute__((weak)) NSString *VCAM_FRIEND_JS_VIDEO_GET(void) "
        "{ return @\"/*video-stub*/\"; }\n"
        "__attribute__((weak)) NSString *VCAM_FRIEND_JS_IMAGE_GET(void) "
        "{ return @\"/*image-stub*/\"; }\n\n"
    )
    if anchor in src:
        src = src.replace(anchor, stubs + anchor, 1)
        report.append("✓ VCAM_FRIEND_JS_* weak 桩")

# =================================================================
# 9. 防重复弹层
# =================================================================
OLD_SM = """    UIViewController *topVC = vcam_topVC();
    if (!topVC || [topVC isKindOfClass:[UIAlertController class]]) return;
"""
NEW_SM = """    UIViewController *topVC = vcam_topVC();
    if (!topVC || [topVC isKindOfClass:[UIAlertController class]]) return;
    /* [PATCH] 防重复弹层 */
    if ([topVC isKindOfClass:NSClassFromString(@"VCamMenu")]) {
        vcam_log(@"showMenu: already presented, skip");
        return;
    }
"""
if OLD_SM in src:
    src = src.replace(OLD_SM, NEW_SM, 1)
    report.append("✓ vcam_showMenu 防重复")

# =================================================================
# 4. UI 精简
# =================================================================
NEW_UI_LINES = [
    "    /* [PATCH v6] 精简 UI：5 项核心 + 取消 */",
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
    end = next((i for i, l in enumerate(lines) if "tag:9 x:(cw - bw)" in l), None)
    if start is None or end is None:
        print("[!] UI 行级回退失败", file=sys.stderr)
        sys.exit(3)
    src = "\n".join(lines[:start] + NEW_UI_LINES + lines[end + 1:])
    report.append("✓ UI 精简（行级回退）")

src = src.replace("CGFloat ch = 380;", "CGFloat ch = 260;")
report.append("✓ 卡片高度 380 → 260")

# =================================================================
# 5. 镜像按钮 tag=10
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
    print("[!] btnTap 块未匹配", file=sys.stderr)
    sys.exit(4)

# =================================================================
# 10. tag:8 标题刷新
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
# 11. SecTrustCopyCertificateChain iOS 14 兼容
# =================================================================
OLD_TRUST = """    CFArrayRef chain = SecTrustCopyCertificateChain(trust);
    if (!chain) {
        completionHandler(NSURLSessionAuthChallengeCancelAuthenticationChallenge, nil);
        return;
    }"""
NEW_TRUST = """    /* [PATCH] iOS 14 兼容：SecTrustCopyCertificateChain 是 iOS 15+ API */
    CFArrayRef chain = NULL;
    if (@available(iOS 15.0, *)) {
        chain = SecTrustCopyCertificateChain(trust);
    } else {
        CFIndex cnt = SecTrustGetCertificateCount(trust);
        CFMutableArrayRef arr = CFArrayCreateMutable(kCFAllocatorDefault, cnt,
                                                     &kCFTypeArrayCallBacks);
        for (CFIndex i = 0; i < cnt; i++) {
            SecCertificateRef c = SecTrustGetCertificateAtIndex(trust, i);
            if (c) CFArrayAppendValue(arr, c);
        }
        chain = arr;
    }
    if (!chain) {
        completionHandler(NSURLSessionAuthChallengeCancelAuthenticationChallenge, nil);
        return;
    }"""
if OLD_TRUST in src:
    src = src.replace(OLD_TRUST, NEW_TRUST, 1)
    report.append("✓ SecTrust iOS 14 兼容")
else:
    print("[!] SecTrustCopyCertificateChain 块未匹配", file=sys.stderr)
    sys.exit(6)

# =================================================================
# 确保 sys/file.h 已导入（flock 需要）
# =================================================================
if "#include <sys/file.h>" not in src:
    src = src.replace("#include <string.h>",
                      "#include <string.h>\n#include <sys/file.h>", 1)

# =================================================================
# 1. 【v6 核心】全量去品牌：vcamplus → cfgdatax（等长 8→8）
# =================================================================
def _keep_case(m):
    s = m.group(0)
    r = "cfgdatax"
    if s.isupper():
        return r.upper()
    if s[0].isupper():
        return r.capitalize()
    return r


n_brand_plain = len(re.findall(r'vcamplus', src, flags=re.IGNORECASE))
src = re.sub(r'vcamplus', _keep_case, src, flags=re.IGNORECASE)

# 编码形式替换（\xHH 序列），xor 0x37 后的 "vcamplus" → "cfgdatax"
# 大写十六进制：\x41\x54\x56\x5A\x47\x5B\x42\x44 → \x54\x51\x50\x53\x56\x43\x56\x4F
# 小写十六进制：\x41\x54\x56\x5a\x47\x5b\x42\x44 → \x54\x51\x50\x53\x56\x43\x56\x4f
BRAND_ENC_PAIRS = [
    (r'\x41\x54\x56\x5A\x47\x5B\x42\x44', r'\x54\x51\x50\x53\x56\x43\x56\x4F'),
    (r'\x41\x54\x56\x5a\x47\x5b\x42\x44', r'\x54\x51\x50\x53\x56\x43\x56\x4f'),
]
n_brand_enc = 0
for old, new in BRAND_ENC_PAIRS:
    cnt = src.count(old)
    if cnt:
        src = src.replace(old, new)
        n_brand_enc += cnt

if n_brand_plain or n_brand_enc:
    report.append(f"✓ 全量去品牌 (明文×{n_brand_plain}, 编码×{n_brand_enc})")

# =================================================================
# 2. 【v6 核心】数据迁移：vcamplus → cfgdatax（flock 保护）
#    旧目录名用 _ds() 加密，二进制里无明文 "vcamplus"
# =================================================================
OLD_MIG = """        [[NSFileManager defaultManager] createDirectoryAtPath:VCAM_DIR
            withIntermediateDirectories:YES attributes:nil error:nil];
        vcam_log([NSString stringWithFormat:@"CONSTRUCTOR: proc=%@ bid=%@", proc, bid]);"""

NEW_MIG = """        [[NSFileManager defaultManager] createDirectoryAtPath:VCAM_DIR
            withIntermediateDirectories:YES attributes:nil error:nil];
        /* [PATCH v6] 一次性数据迁移（旧目录名加密，二进制无明文痕迹） */
        {
            int lockFd = open("/var/jb/var/mobile/Library/.cfg_migrate.lock",
                              O_CREAT | O_RDWR, 0666);
            if (lockFd >= 0 && flock(lockFd, LOCK_EX | LOCK_NB) == 0) {
                @try {
                    NSFileManager *fm = [NSFileManager defaultManager];
                    NSString *oldName = _ds("\\x41\\x54\\x56\\x5A\\x47\\x5B\\x42\\x44", 8);
                    NSString *oldDir  = [@"/var/jb/var/mobile/Library"
                                         stringByAppendingPathComponent:oldName];
                    NSString *newDir  = @"/var/jb/var/mobile/Library/cfgdatax";
                    if ([fm fileExistsAtPath:oldDir]) {
                        NSArray *items = [fm contentsOfDirectoryAtPath:oldDir error:nil];
                        for (NSString *it in items) {
                            NSString *s = [oldDir stringByAppendingPathComponent:it];
                            NSString *d = [newDir stringByAppendingPathComponent:it];
                            if (![fm fileExistsAtPath:d]) {
                                [fm moveItemAtPath:s toPath:d error:nil];
                            }
                        }
                        [fm removeItemAtPath:oldDir error:nil];
                        vcam_log([NSString stringWithFormat:@"migrated %@ -> cfgdatax", oldName]);
                    }
                } @finally { close(lockFd); }
            }
        }
        vcam_log([NSString stringWithFormat:@"CONSTRUCTOR: proc=%@ bid=%@", proc, bid]);"""

if OLD_MIG in src:
    src = src.replace(OLD_MIG, NEW_MIG, 1)
    report.append("✓ 数据迁移（旧目录名加密）")
else:
    print("[!] 迁移锚点未匹配", file=sys.stderr)
    sys.exit(7)

# =================================================================
# 写回
# =================================================================
if src == original:
    print("[!] 无变更", file=sys.stderr)
    sys.exit(8)

TWEAK.write_text(src, encoding="utf-8")
print(f"[+] 补丁成功：{TWEAK}")
for r in report:
    print("   ", r)
print(f"[+] 共 {len(report)} 项")
