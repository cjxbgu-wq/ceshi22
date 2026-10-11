#!/usr/bin/env bash
# 补丁方式进入 —— 未过补丁不允许构建
# 兼容 macOS bash 3.2（无 mapfile）
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "[*] VCamPlus 入口 —— 补丁方式"
echo "[*] 工作目录：$ROOT"
echo ""

# 定位源文件
SOURCE=""
if [ -f "Tweak.xm" ]; then
    SOURCE="Tweak.xm"
else
    FOUND="$(find . -maxdepth 4 -iname '*tweak*.xm' \
        -not -path './.git/*' -not -path './.theos/*' \
        -not -path './packages/*' -not -path './obj/*' 2>/dev/null | sort || true)"
    CNT=0
    [ -n "$FOUND" ] && CNT=$(printf '%s\n' "$FOUND" | wc -l | tr -d ' ')
    if [ "$CNT" -eq 0 ]; then
        echo "[!] 未找到 *tweak*.xm"
        ls -la "$ROOT" 2>/dev/null || true
        exit 1
    fi
    if [ "$CNT" -gt 1 ]; then
        echo "[!] 找到多个候选，请手动指定："
        printf '    %s\n' "$FOUND"
        echo "[!] 用法：VCAM_SOURCE=./主源码Tweak.xm bash scripts/entry.sh"
        exit 1
    fi
    SOURCE="$FOUND"
fi

if [ -n "${VCAM_SOURCE:-}" ]; then SOURCE="$VCAM_SOURCE"; fi
echo "[*] 找到源文件：$SOURCE"

TARGET="Tweak.xm"
if [ "$SOURCE" != "$TARGET" ]; then
    echo "[*] 复制到：$SOURCE  →  $TARGET"
    cp -f "$SOURCE" "$TARGET"
fi

export VCAM_TWEAK_PATH="$TARGET"
echo "[*] 应用补丁..."
python3 patches/apply_patch.py

echo "[*] 校验..."
VCAM_TWEAK_PATH="$TARGET" python3 - <<'PY'
import os, sys
p = os.environ["VCAM_TWEAK_PATH"]
src = open(p, encoding="utf-8").read()
# ★ 修正：只用 "PATCH-X]" 前缀匹配，不依赖后面的具体文字
checks = [
    ("PATCH-A]",  "SecTrust 兼容未注入"),
    ("PATCH-B]",  "_gDID 修复未注入"),
    ("PATCH-C]",  "_chkInteg 禁用未注入"),
    ("tag:10",    "镜像按钮未注入"),
]
fail = False
for needle, msg in checks:
    if needle not in src:
        print(f"[!] {msg}：缺少 `{needle}`", file=sys.stderr)
        fail = True
if fail:
    sys.exit(1)
print("[+] Python 校验通过")
PY

echo "$TARGET" > .patched
echo "[+] 全部通过，可以编译：make package FINALPACKAGE=1"
