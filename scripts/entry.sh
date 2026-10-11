#!/usr/bin/env bash
# 补丁方式进入 —— 未过补丁不允许构建
# 兼容 macOS bash 3.2（无 mapfile）
# 兼容任意源文件名（如「主源码Tweak.xm」）
# v6: 校验清单已同步到 cfgdatax 品牌策略
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "[*] VCam Tweak 入口 —— 补丁方式"
echo "[*] 工作目录：$ROOT"
echo ""

# ---------------------------------------------------------------
# 定位源文件
# ---------------------------------------------------------------
SOURCE=""
if [ -f "Tweak.xm" ]; then
    SOURCE="Tweak.xm"
else
    FOUND_LIST="$(find . -maxdepth 4 -iname '*tweak*.xm' \
        -not -path './.git/*' \
        -not -path './.theos/*' \
        -not -path './packages/*' \
        -not -path './obj/*' 2>/dev/null | sort || true)"
    COUNT=0
    if [ -n "$FOUND_LIST" ]; then
        COUNT=$(printf '%s\n' "$FOUND_LIST" | wc -l | tr -d ' ')
    fi
    if [ "$COUNT" -eq 0 ]; then
        echo "================================================================"
        echo "[!] 未找到任何 *tweak*.xm 源文件"
        echo "================================================================"
        ls -la "$ROOT" 2>/dev/null || true
        find . -maxdepth 4 \( -iname '*.xm' -o -iname '*.x' -o -iname '*.mm' \) \
            -not -path './.git/*' -not -path './.theos/*' 2>/dev/null || true
        exit 1
    fi
    if [ "$COUNT" -gt 1 ]; then
        echo "[!] 找到多个候选源文件，请手动指定："
        printf '    %s\n' "$FOUND_LIST"
        echo "[!] 用法：VCAM_SOURCE=./主源码Tweak.xm bash scripts/entry.sh"
        exit 1
    fi
    SOURCE="$FOUND_LIST"
fi

if [ -n "${VCAM_SOURCE:-}" ]; then
    SOURCE="$VCAM_SOURCE"
fi
echo "[*] 找到源文件：$SOURCE"

# ---------------------------------------------------------------
# 复制为根目录 Tweak.xm（供 Theos 使用，源文件不动）
# ---------------------------------------------------------------
TARGET="Tweak.xm"
if [ "$SOURCE" != "$TARGET" ]; then
    echo "[*] 复制到构建目标：$SOURCE  →  $TARGET"
    cp -f "$SOURCE" "$TARGET"
else
    echo "[*] 源文件已是 Tweak.xm，直接使用"
fi

# ---------------------------------------------------------------
# 打补丁
# ---------------------------------------------------------------
export VCAM_TWEAK_PATH="$TARGET"
echo "[*] 应用补丁到：$TARGET"
python3 patches/apply_patch.py

# ---------------------------------------------------------------
# Python 校验（跨平台，v6 品牌策略）
# ---------------------------------------------------------------
echo "[*] 补丁校验（Python）..."
VCAM_TWEAK_PATH="$TARGET" python3 - <<'PY'
import os, re, sys
p = os.environ["VCAM_TWEAK_PATH"]
src = open(p, encoding="utf-8").read()

# ---------- 正向检查：v6 补丁的所有特征标记 ----------
checks = [
    ("cfgdatax",                                 "品牌未替换"),
    ("injectionTime:1 forMainFrameOnly:NO",      "injectionTime 未改"),
    ("tag:10",                                   "tag:10 未注入"),
    ("_panelVisible;",                           "FWCtrl ivar 未补"),
    ("void)updateHighlight",                     "updateHighlight 未补"),
    ("void)hide { }",                            "hide 未补"),
    ("VCAM_FRIEND_JS_STREAM_GET(void) { return", "weak 桩未注入"),
    ("if (@available(iOS 15.0, *))",             "SecTrust iOS 14 兼容未注入"),
    ("cfg_migrate.lock",                         "数据迁移未注入"),
]
fail = False
for needle, msg in checks:
    if needle not in src:
        print(f"[!] {msg}：缺少 `{needle}`", file=sys.stderr)
        fail = True

# ---------- 反向检查：不允许残留明文 vcamplus ----------
# 注意：加密形式 \x41\x54\x56\x5A... 会在 v6 补丁中被替换掉，
#       迁移代码里的旧目录名用 _ds() 加密保存，源码明文里不应出现。
if "vcamplus" in src.lower():
    print("[!] 源码里仍残留明文 vcamplus：", file=sys.stderr)
    for m in re.finditer(r'.{0,40}vcamplus.{0,40}', src, re.IGNORECASE):
        print(f"    {m.group(0)}", file=sys.stderr)
    fail = True

# ---------- 反向检查：不允许残留旧编码 ----------
# vcamplus 的两种编码形态（大写/小写 hex）都不应存在
for old_enc in [
    r'\x41\x54\x56\x5A\x47\x5B\x42\x44',
    r'\x41\x54\x56\x5a\x47\x5b\x42\x44',
]:
    if old_enc in src:
        print(f"[!] 源码里仍残留编码形式 vcamplus：`{old_enc}`", file=sys.stderr)
        fail = True

# ---------- 反向检查：不允许残留旧品牌目录路径 ----------
for old_path in [
    'Library/.cfgdata',   # v4 曾用过的临时名
    'com.system.',        # v4 曾用过的临时前缀
]:
    if old_path in src:
        print(f"[!] 检测到 v4 残留标记 `{old_path}`（应已被 cfgdatax 策略取代）",
              file=sys.stderr)
        fail = True

if fail:
    sys.exit(1)
print("[+] Python 校验通过（无 vcamplus 残留）")
PY

echo "$TARGET" > .patched
echo "[+] 全部校验通过，可以编译"
echo "[+] 源文件保持零改动：$SOURCE"
echo "[+] 构建目标（已打补丁）：$TARGET"
