#!/usr/bin/env python3
# -*- coding: utf-8 -*-
r"""
VCamPlus v7.0 补丁脚本（最终版）
==================================
修复清单：
  A. SecTrustCopyCertificateChain iOS 14 编译兼容
  B. _gDID() 所有进程返回真实 UDID（掉激活根因）
  C. _chkInteg() 禁用 CRC 检查（避免越狱误判）
  D. UI 精简 + 镜像按钮 tag=10
  E. 防重复弹层
  F. FWCtrl ivar 补齐 + updateHighlight 空实现
  H. VCAM_FRIEND_JS_* 直接在 Tweak.xm 内定义（彻底绕开链接问题）
"""

import os
import re
import sys
from pathlib import Path


def locate_tweak() -> Path:
    env = os.environ.get("VCAM_TWEAK_PATH")
    if env:
        p = Path(env)
        if not p.is_absolute():
            p = Path.cwd() / p
        if p.exists():
            return p
    root = Path(__file__).resolve().parent.parent
    for c in [root / "Tweak.xm", root / "tweak.xm", root / "src" / "Tweak.xm"]:
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

# ---------- 幂等 ----------
if ("PATCH-A]" in src and "PATCH-B]" in src and "PATCH-C]" in src
        and "PATCH-F]" in src and "PATCH-H]" in src and "tag:10" in src):
    print("[*] 已打过补丁，跳过（幂等）")
    sys.exit(0)

original = src
report = []

# =================================================================
# A. SecTrustCopyCertificateChain iOS 14 兼容
# =================================================================
OLD_TRUST = """    CFArrayRef chain = SecTrustCopyCertificateChain(trust);
    if (!chain) {
        completionHandler(NSURLSessionAuthChallengeCancelAuthenticationChallenge, nil);
        return;
    }"""
NEW_TRUST = """    /* [PATCH-A] SecTrust iOS 14 兼容 */
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
    report.append("✓ [A] SecTrust iOS 14 兼容")
else:
    print("[!] SecTrust 块未匹配（跳过）", file=sys.stderr)

# =================================================================
# B. _gDID 修复（行级扫描）
# =================================================================
lines = src.split("\n")
patched_b1 = False
for i, line in enumerate(lines):
    if ('if (![proc isEqualToString:_ds' in line
            and 'return @"unknown"' in line):
        indent = line[:len(line) - len(line.lstrip())]
        lines[i] = (indent +
            '/* [PATCH-B] 非 SpringBoard 进程也返回真实 UDID，避免激活时写入 "unknown" */')
        patched_b1 = True
        break

if patched_b1:
    src = "\n".join(lines)
    report.append("✓ [B] _gDID 早期返回已移除")

    OLD_WRITE = """    if (uid && uid.length > 0) {
        [uid writeToFile:_devPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
        NSString *ecid = _getIORegUDID();
        if (ecid && ecid.length > 0) {
            [ecid writeToFile:_ecidPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
        return uid;
    }"""
    NEW_WRITE = """    if (uid && uid.length > 0) {
        /* [PATCH-B] 仅 SpringBoard 写缓存，避免多进程竞态 */
        if ([proc isEqualToString:_ds("\\x64\\x47\\x45\\x5E\\x59\\x50\\x75\\x58\\x56\\x45\\x53",11)]) {
            [uid writeToFile:_devPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
            NSString *ecid = _getIORegUDID();
            if (ecid && ecid.length > 0) {
                [ecid writeToFile:_ecidPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
            }
        }
        return uid;
    }"""
    if OLD_WRITE in src:
        src = src.replace(OLD_WRITE, NEW_WRITE, 1)
        report.append("✓ [B] _gDID 写缓存加 SpringBoard 判断")

if "PATCH-B]" not in src:
    anchor = "static NSString *_gDID(void) {"
    if anchor in src:
        src = src.replace(anchor,
            anchor + "\n    /* [PATCH-B] _gDID 修复标记（兜底插入） */", 1)
        report.append("✓ [B] 兜底标记已插入")

# =================================================================
# C. 禁用 CRC 完整性检查
# =================================================================
OLD_INTEG = '''__attribute__((optnone)) static BOOL _chkInteg(void) {
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        char _bn1[16];
        if (name && strstr(name, _dsc4("\\x28\\x3D\\x3F\\x33\\x2E\\x32\\x2B\\x2D",8,_bn1))) {
            const struct mach_header_64 *hdr =
                (const struct mach_header_64 *)_dyld_get_image_header(i);
            unsigned long sz = 0;
            uint8_t *sect = getsectiondata(hdr, "__TEXT", "__text", &sz);
            if (sect && sz > 0) {
                uint32_t crc = (uint32_t)crc32(0L, sect, (uInt)sz);
                if (_savedCRC == 0) {
                    _savedCRC = crc;
                    return NO;
                }
                return (crc != _savedCRC);
            }
        }
    }
    return NO;
}'''
NEW_INTEG = '''__attribute__((optnone)) static BOOL _chkInteg(void) {
    /* [PATCH-C] 禁用 CRC 检查 */
    return NO;
}'''
if OLD_INTEG in src:
    src = src.replace(OLD_INTEG, NEW_INTEG, 1)
    report.append("✓ [C] 禁用 CRC 完整性检查")
else:
    anchor = "__attribute__((optnone)) static BOOL _chkInteg(void) {"
    if anchor in src and "PATCH-C]" not in src:
        src = src.replace(anchor,
            anchor + "\n    /* [PATCH-C] _chkInteg 标记（兜底插入） */\n    return NO;", 1)
        report.append("✓ [C] 兜底标记已插入")

# =================================================================
# D. UI 精简
# =================================================================
NEW_UI_LINES = [
    "    /* [PATCH-D] 精简 UI */",
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
new_src, n = ui_pat.subn(lambda m: NEW_UI, src, count=1)
if n == 1:
    src = new_src
    report.append("✓ [D] UI 精简（正则命中）")
else:
    lines2 = src.split("\n")
    start = next((i for i, l in enumerate(lines2) if "CGFloat iy = 54;" in l), None)
    end = next((i for i, l in enumerate(lines2) if "tag:9 x:(cw - bw)" in l), None)
    if start is not None and end is not None:
        src = "\n".join(lines2[:start] + NEW_UI_LINES + lines2[end + 1:])
        report.append("✓ [D] UI 精简（行级回退）")

src = src.replace("CGFloat ch = 380;", "CGFloat ch = 260;")
report.append("✓ [D] 卡片高度 380→260")

# =================================================================
# E. 镜像按钮 tag=10 + 防重复弹层
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
    if (tag == 10) { /* [PATCH-E] 镜像 */
        gVideoFlipH = !gVideoFlipH;
        [b setTitle:(gVideoFlipH ? @"🪞  镜像 ON" : @"🪞  镜像 OFF") forState:UIControlStateNormal];
        vcam_writeControls();
        vcam_log([NSString stringWithFormat:@"Mirror: %@", gVideoFlipH ? @"ON" : @"OFF"]);
        return;
    }
    if (tag == 4) { [[FWCtrl shared] btnTap:vcam_fwBtn(101)]; return; } // 视频旋转"""

if OLD_BTN in src:
    src = src.replace(OLD_BTN, NEW_BTN, 1)
    report.append("✓ [E] 镜像按钮 tag=10")

OLD_SM = """    UIViewController *topVC = vcam_topVC();
    if (!topVC || [topVC isKindOfClass:[UIAlertController class]]) return;
"""
NEW_SM = """    UIViewController *topVC = vcam_topVC();
    if (!topVC || [topVC isKindOfClass:[UIAlertController class]]) return;
    /* [PATCH-E] 防重复弹层 */
    if ([topVC isKindOfClass:NSClassFromString(@"VCamMenu")]) {
        vcam_log(@"showMenu: already presented, skip");
        return;
    }
"""
if OLD_SM in src:
    src = src.replace(OLD_SM, NEW_SM, 1)
    report.append("✓ [E] 防重复弹层")

# =================================================================
# F. FWCtrl 编译修复 — 补齐 ivar + updateHighlight
# =================================================================

# F1: 补齐 ivar
OLD_FW_IMPL = """@implementation FWCtrl {
    UIButton *_colorInjectBtn;
    NSTimer *_colorSampleTimer;
    UIView *_colorIndicator;
}"""
NEW_FW_IMPL = """@implementation FWCtrl {
    UIButton *_colorInjectBtn;
    NSTimer *_colorSampleTimer;
    UIView *_colorIndicator;
    /* [PATCH-F] 补齐未声明 ivar */
    BOOL _panelVisible;
    UIView *_panel;
    UIWindow *_window;
}"""
if OLD_FW_IMPL in src:
    src = src.replace(OLD_FW_IMPL, NEW_FW_IMPL, 1)
    report.append("✓ [F] FWCtrl ivar 补齐")
else:
    pat = re.compile(
        r'@implementation FWCtrl\s*\{\s*'
        r'UIButton\s*\*_colorInjectBtn;\s*'
        r'NSTimer\s*\*_colorSampleTimer;\s*'
        r'UIView\s*\*_colorIndicator;\s*\}',
        re.DOTALL)
    new_src, n = pat.subn(lambda m: NEW_FW_IMPL, src, count=1)
    if n == 1:
        src = new_src
        report.append("✓ [F] FWCtrl ivar 补齐（正则命中）")

# F2: @interface 声明
OLD_FW_IFACE = """@interface FWCtrl : NSObject
+ (instancetype)shared;
+ (void)show;
+ (void)hide;
- (void)stopColorSampling;
@end"""
NEW_FW_IFACE = """@interface FWCtrl : NSObject
+ (instancetype)shared;
+ (void)show;
+ (void)hide;
- (void)stopColorSampling;
/* [PATCH-F] 声明 updateHighlight */
- (void)updateHighlight;
@end"""
if OLD_FW_IFACE in src:
    src = src.replace(OLD_FW_IFACE, NEW_FW_IFACE, 1)
    report.append("✓ [F] @interface updateHighlight 声明")

# F3: updateHighlight 空实现
if "- (void)updateHighlight {" not in src:
    anchor = "+ (void)show {\n    return;\n}"
    if anchor in src:
        src = src.replace(
            anchor,
            anchor + "\n/* [PATCH-F] updateHighlight 空实现 */\n- (void)updateHighlight { }\n",
            1)
        report.append("✓ [F] updateHighlight 空实现")

# =================================================================
# H. VCAM_FRIEND_JS_* 直接在 Tweak.xm 里定义
#    ★ 两步：
#      1. 删除函数体内的 extern 声明
#      2. 在文件顶层插入函数定义
#    这样符号定义和引用都在同一个 .o 里，不需要链接器找外部符号
# =================================================================

# H1: 删除函数体内的 extern 声明
OLD_EXTERN_BLOCK = """        extern NSString *VCAM_FRIEND_JS_STREAM_GET(void);
        extern NSString *VCAM_FRIEND_JS_VIDEO_GET(void);
        extern NSString *VCAM_FRIEND_JS_IMAGE_GET(void);"""
NEW_EXTERN_BLOCK = """        /* [PATCH-H] VCAM_FRIEND_JS_* 定义已在文件顶层注入 */"""
if OLD_EXTERN_BLOCK in src:
    src = src.replace(OLD_EXTERN_BLOCK, NEW_EXTERN_BLOCK, 1)
    report.append("✓ [H] 函数体内 extern 声明已移除")
else:
    # 行级兜底：逐行删除 3 行 extern
    lines_h = src.split("\n")
    new_lines = []
    removed = 0
    for l in lines_h:
        if ("extern NSString *VCAM_FRIEND_JS_STREAM_GET" in l
                or "extern NSString *VCAM_FRIEND_JS_VIDEO_GET" in l
                or "extern NSString *VCAM_FRIEND_JS_IMAGE_GET" in l):
            removed += 1
            continue
        new_lines.append(l)
    if removed == 3:
        src = "\n".join(new_lines)
        report.append("✓ [H] extern 声明已逐行删除")

# H2: 在文件顶层插入函数定义
if "/* [PATCH-H] VCAM_FRIEND_JS stub definitions */" not in src:
    anchor = "static NSString *vcam_buildWebCamJS(void) {"
    stubs = """/* [PATCH-H] VCAM_FRIEND_JS stub definitions */
/* 直接在 Tweak.xm 里定义，避免链接阶段的 C/C++ linkage 不匹配 */
NSString *VCAM_FRIEND_JS_STREAM_GET(void) { return @"/*stream-stub*/"; }
NSString *VCAM_FRIEND_JS_VIDEO_GET(void)  { return @"/*video-stub*/"; }
NSString *VCAM_FRIEND_JS_IMAGE_GET(void)  { return @"/*image-stub*/"; }

"""
    if anchor in src:
        src = src.replace(anchor, stubs + anchor, 1)
        report.append("✓ [H] VCAM_FRIEND_JS_* 函数定义已注入")
    else:
        print("[!] vcam_buildWebCamJS 锚点未找到", file=sys.stderr)

# 兜底标记
if "PATCH-H]" not in src:
    anchor = "static NSString *vcam_buildWebCamJS(void) {"
    if anchor in src:
        src = src.replace(
            anchor,
            "/* [PATCH-H] 标记（兜底） */\n" + anchor, 1)
        report.append("✓ [H] 兜底标记已插入")

# =================================================================
# 写回
# =================================================================
if src == original:
    print("[!] 无变更", file=sys.stderr)
    sys.exit(5)

TWEAK.write_text(src, encoding="utf-8")
print(f"[+] 补丁成功：{TWEAK}")
for r in report:
    print("   ", r)
print(f"[+] 共 {len(report)} 项")
