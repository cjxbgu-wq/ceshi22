#!/usr/bin/env bash
# 补丁方式进入 —— 未过补丁不允许构建
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "[*] VCam Tweak 入口 —— 补丁方式"
echo "[*] 工作目录：$ROOT"
echo ""

# ---------------------------------------------------------------
# 定位 Tweak.xm（多结果显式报错）
# ---------------------------------------------------------------
mapfile -t ALL < <(find . -maxdepth 4 -iname 'tweak.xm' \
    -not -path './.git/*' \
    -not -path './.theos/*' \
    -not -path './packages/*' \
    -not -path './obj/*' 2>/dev/null | sort)

if [ ${#ALL[@]} -eq 0 ]; then
    echo "================================================================"
    echo "[!] 未找到 Tweak.xm"
    echo "================================================================"
    echo "[i] 仓库根目录："
    ls -la "$ROOT" 2>/dev/null || true
    echo ""
    echo "[i] 所有 .xm/.x/.mm（深度 ≤4）："
    find . -maxdepth 4 \( -iname '*.xm' -o -iname '*.x' -o -iname '*.mm' \) \
        -not -path './.git/*' -not -path './.theos/*' 2>/dev/null || true
    exit 1
fi

if [ ${#ALL[@]} -gt 1 ]; then
    echo "[!] 找到多个 Tweak.xm，请手动指定："
    printf '    %s\n' "${ALL[@]}"
    echo "[!] 用法：VCAM_TWEAK_PATH=./src/Tweak.xm bash scripts/entry.sh"
    exit 1
fi

TWEAK_PATH="${ALL[0]}"
echo "[*] 找到源码：$TWEAK_PATH"
export VCAM_TWEAK_PATH="$TWEAK_PATH"

# ---------------------------------------------------------------
# 打补丁
# ---------------------------------------------------------------
echo "[*] 应用补丁..."
python3 patches/apply_patch.py

# ---------------------------------------------------------------
# Python 校验（跨平台一致）
# ---------------------------------------------------------------
echo "[*] 补丁校验（Python）..."
VCAM_TWEAK_PATH="$TWEAK_PATH" python3 - <<'PY'
import os, sys
p = os.environ["VCAM_TWEAK_PATH"]
src = open(p, encoding="utf-8").read()
checks = [
    ("Library/.cfgdata",               "目录未改"),
    ("injectionTime:1 forMainFrameOnly:NO", "injectionTime 未改"),
    ("tag:10",                         "tag:10 未注入"),
    ("_panelVisible;",                 "FWCtrl ivar 未补"),
    ("void)updateHighlight",           "updateHighlight 未补"),
    ("VCAM_FRIEND_JS_STREAM_GET(void) { return", "weak 桩未注入"),
    ("com.system.",                    "品牌后缀未改"),
]
fail = False
for needle, msg in checks:
    if needle not in src:
        print(f"[!] {msg}：缺少 `{needle}`", file=sys.stderr)
        fail = True
if fail: sys.exit(1)
print("[+] Python 校验通过")
PY

echo "$TWEAK_PATH" > .patched
echo "[+] 全部校验通过，可以编译"
echo "[+] 打补丁文件：$TWEAK_PATH"
