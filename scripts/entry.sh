#!/usr/bin/env bash
# 补丁方式进入 —— 未过补丁不允许构建
# 兼容 macOS bash 3.2（无 mapfile / readarray）
# 兼容任意源文件名（如「主源码Tweak.xm」），源文件零改动
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "[*] VCam Tweak 入口 —— 补丁方式"
echo "[*] 工作目录：$ROOT"
echo ""

# ---------------------------------------------------------------
# 1) 定位源文件
#    优先精确匹配 Tweak.xm；否则模糊匹配 *tweak*.xm
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
        echo "[i] 仓库根目录："
        ls -la "$ROOT" 2>/dev/null || true
        echo ""
        echo "[i] 所有 .xm/.x/.mm（深度 ≤4）："
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

# 允许通过环境变量覆盖
if [ -n "${VCAM_SOURCE:-}" ]; then
    SOURCE="$VCAM_SOURCE"
fi

echo "[*] 找到源文件：$SOURCE"

# ---------------------------------------------------------------
# 2) 复制为根目录 Tweak.xm（供 Theos 使用）
#    源文件绝对不动
# ---------------------------------------------------------------
TARGET="Tweak.xm"
if [ "$SOURCE" != "$TARGET" ]; then
    echo "[*] 复制到构建目标：$SOURCE  →  $TARGET"
    cp -f "$SOURCE" "$TARGET"
else
    echo "[*] 源文件已是 Tweak.xm，直接使用"
fi

# ---------------------------------------------------------------
# 3) 打补丁（打到 TARGET 上，源文件不动）
# ---------------------------------------------------------------
export VCAM_TWEAK_PATH="$TARGET"
echo "[*] 应用补丁到：$TARGET"
python3 patches/apply_patch.py

# ---------------------------------------------------------------
# 4) 校验（Python 跨平台）
# ---------------------------------------------------------------
echo "[*] 补丁校验（Python）..."
VCAM_TWEAK_PATH="$TARGET" python3 - <<'PY'
import os, sys
p = os.environ["VCAM_TWEAK_PATH"]
src = open(p, encoding="utf-8").read()
checks = [
    ("Library/.cfgdata",                         "目录未改"),
    ("injectionTime:1 forMainFrameOnly:NO",      "injectionTime 未改"),
    ("tag:10",                                   "tag:10 未注入"),
    ("_panelVisible;",                           "FWCtrl ivar 未补"),
    ("void)updateHighlight",                     "updateHighlight 未补"),
    ("VCAM_FRIEND_JS_STREAM_GET(void) { return", "weak 桩未注入"),
    ("com.system.",                              "品牌后缀未改"),
]
fail = False
for needle, msg in checks:
    if needle not in src:
        print(f"[!] {msg}：缺少 `{needle}`", file=sys.stderr)
        fail = True
if fail: sys.exit(1)
print("[+] Python 校验通过")
PY

echo "$TARGET" > .patched
echo "[+] 全部校验通过，可以编译"
echo "[+] 源文件保持零改动：$SOURCE"
echo "[+] 构建目标（已打补丁）：$TARGET"
