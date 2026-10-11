#!/usr/bin/env bash
# 补丁方式进入 —— 未过补丁不允许构建
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "[*] VCam Tweak 入口 —— 补丁方式"
echo "[*] 工作目录：$ROOT"

[ -f "Tweak.xm" ] || { echo "[!] 未找到 Tweak.xm"; exit 1; }

echo "[*] 应用补丁..."
python3 patches/apply_patch.py

echo "[*] 补丁校验（按 ASCII 锚点，避免 locale 问题）..."
# 1. vcamplus 已去除
grep -q 'Library/\.cfgdata' Tweak.xm \
    || { echo "[!] .cfgdata 未生效"; exit 2; }
# 2. 浏览器注入时机
grep -q 'injectionTime:1 forMainFrameOnly:NO' Tweak.xm \
    || { echo "[!] injectionTime 未改"; exit 3; }
# 3. 镜像按钮 tag（纯 ASCII，无 locale 风险）
grep -q 'tag:10' Tweak.xm \
    || { echo "[!] tag:10 未注入"; exit 4; }
# 4. FWCtrl ivar 补齐
grep -q '_panelVisible;' Tweak.xm \
    || { echo "[!] FWCtrl ivar 未补"; exit 5; }
# 5. updateHighlight 空实现
grep -q 'FWCtrl updateHighlight' Tweak.xm \
    || { echo "[!] updateHighlight 未补"; exit 6; }

# 6. 防止绕过：生成 .patched 标记
touch .patched
echo "[+] 全部校验通过，可以编译"
