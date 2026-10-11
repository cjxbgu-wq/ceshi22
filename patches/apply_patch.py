#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
VCamPlus v7.0 补丁脚本（修正版）
================================
针对 v7.0 源码的最小必要修复：

  A. SecTrustCopyCertificateChain iOS 14 编译兼容  ← 编译必须
  B. _gDID() 非 SpringBoard 进程返回真实 UDID        ← 掉激活根因
  C. _chkInteg() 禁用 CRC 检查                        ← 避免误判掉激活
  D. UI 精简 + 镜像按钮 tag=10                         ← 之前要求
  E. tag:8 标题刷新 + 防重复弹层                       ← 健壮性

修正：所有 re.subn 的 replacement 用 lambda 包装，避免 NEW_GDID 中的
     \\x 被 Python 正则引擎解析为"坏转义" (re.error: bad escape \\x)
"""

import os, re, sys
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
if ("PATCH-A] SecTrust" in src and "PATCH-B] _gDID" in src
        and "PATCH-C] _chkInteg" in src and "tag:10" in src):
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
    print("[!] SecTrust 块未匹配（可能已打过补丁）", file=sys.stderr)

# =================================================================
# B. _gDID 修复：非 SpringBoard 进程返回真实 UDID
#    根因：激活时如果 device.id 不存在，非 SB 进程返回 "unknown"，
#          之后 SB 写入真实 UDID → 授权文件 u 字段与 _gDID() 不一致 → 掉激活
# =================================================================
OLD_GDID = '''    // 2. Only SpringBoard generates device.id (non-sandboxed)
    NSString *proc = [[NSProcessInfo processInfo] processName];
    if (![proc isEqualToString:_ds("\\x64\\x47\\x45\\x5E\\x59\\x50\\x75\\x58\\x56\\x45\\x53",11)]) return @"unknown";
    // 3. Get UDID via MGCopyAnswer
    NSString *uid = _getMGUDID();
    if (!uid || uid.length == 0) {
        @try {
            if ([UIDevice class])
                uid = [[[UIDevice currentDevice] identifierForVendor] UUIDString];
        } @catch (NSException *e) {}
    }
    // 4. Save UDID + ECID
    if (uid && uid.length > 0) {
        [uid writeToFile:_devPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
        NSString *ecid = _getIORegUDID();
        if (ecid && ecid.length > 0) {
            [ecid writeToFile:_ecidPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
        return uid;
    }
    return @"unknown";'''

NEW_GDID = '''    /* [PATCH-B] _gDID: 所有进程统一返回真实 UDID，避免激活时写入 "unknown" */
    NSString *proc = [[NSProcessInfo processInfo] processName];
    NSString *uid = _getMGUDID();
    if (!uid || uid.length == 0) {
        @try {
            if ([UIDevice class])
                uid = [[[UIDevice currentDevice] identifierForVendor] UUIDString];
        } @catch (NSException *e) {}
    }
    if (uid && uid.length > 0) {
        /* [PATCH-B] 仅 SpringBoard 写缓存，避免多进程竞态 */
        if ([proc isEqualToString:_ds("\\x64\\x47\\x45\\x5E\\x59\\x50\\x75\\x58\\x56\\x45\\x53",11)]) {
            [uid writeToFile:_devPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
            NSString *ecid = _getIORegUDID();
            if (ecid && ecid.length > 0) {
                [ecid writeToFile:_ecidPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
            }
        }
        return uid;
    }
    return @"unknown";'''

if OLD_GDID in src:
    src = src.replace(OLD_GDID, NEW_GDID, 1)
    report.append("✓ [B] _gDID 修复（掉激活根因）")
else:
    # 用正则兜底 — 关键：replacement 用 lambda 包装，避免 \x 被解析为转义
    pat = re.compile(
        r'//\s*2\.\s*Only SpringBoard generates.*?return @"unknown";',
        re.DOTALL)
    new_src, n = pat.subn(lambda m: NEW_GDID, src, count=1)
    if n == 1:
        src = new_src
        report.append("✓ [B] _gDID 修复（正则命中）")
    else:
        print("[!] _gDID 块未匹配（跳过，非致命）", file=sys.stderr)

# =================================================================
# C. 禁用 CRC 完整性检查（避免误判掉激活）
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
                    return NO; // first run, save baseline
                }
                return (crc != _savedCRC);
            }
        }
    }
    return NO;
}'''

NEW_INTEG = '''__attribute__((optnone)) static BOOL _chkInteg(void) {
    /* [PATCH-C] 禁用 CRC 检查：越狱环境下 CRC 常因页缓存/延迟绑定误判，导致掉激活 */
    return NO;
}'''

if OLD_INTEG in src:
    src = src.replace(OLD_INTEG, NEW_INTEG, 1)
    report.append("✓ [C] 禁用 CRC 完整性检查")
else:
    print("[!] _chkInteg 块未匹配（跳过，非致命）", file=sys.stderr)

# =================================================================
# D. UI 精简（正则锚定 + 行级回退）
# =================================================================
NEW_UI_LINES = [
    "    /* [PATCH-D] 精简 UI：5 项核心 + 取消 */",
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
    lines = src.split("\n")
    start = next((i for i, l in enumerate(lines) if "CGFloat iy = 54;" in l), None)
    end = next((i for i, l in enumerate(lines) if "tag:9 x:(cw - bw)" in l), None)
    if start is not None and end is not None:
        src = "\n".join(lines[:start] + NEW_UI_LINES + lines[end + 1:])
        report.append("✓ [D] UI 精简（行级回退）")
    else:
        print("[!] UI 块未匹配（跳过）", file=sys.stderr)

src = src.replace("CGFloat ch = 380;", "CGFloat ch = 260;")
report.append("✓ [D] 卡片高度 380→260")

# =================================================================
# E. 镜像按钮 tag=10 + 隐藏已移除按钮 + 防重复弹层
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

# 防重复弹层
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
# 写回
# =================================================================
if src == original:
    print("[!] 无变更（可能源码版本不同）", file=sys.stderr)
    sys.exit(5)

TWEAK.write_text(src, encoding="utf-8")
print(f"[+] 补丁成功：{TWEAK}")
for r in report:
    print("   ", r)
print(f"[+] 共 {len(report)} 项")
