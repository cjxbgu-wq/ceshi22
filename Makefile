# ============================================================
#  QianmianEnhancer - VCam 增强 Tweak
#  Makefile
# ============================================================

# ---------- 目标平台 ----------
TARGET = iphone:clang:latest:14.0
ARCHS  = arm64 arm64e

# ---------- Theos 公共规则 ----------
include $(THEOS)/makefiles/common.mk

# ---------- Tweak 名称 ----------
TWEAK_NAME = QianmianEnhancer

# ---------- 源文件 ----------
QianmianEnhancer_FILES = \
    Tweak.xm \
    QMEnhancerView.m

# ---------- 编译参数 ----------
# -fobjc-arc       : 使用 ARC（weak 属性 / block 内存管理依赖）
# -Wno-deprecated  : 忽略废弃 API 警告（notify_post、UIImageJPEGRepresentation 等）
# -Wno-unguarded   : 忽略 @available 检查外的 API 使用警告
# -Wno-unused      : 忽略未使用变量警告
# -Wno-format      : 忽略 NSLog 格式化警告（不同 SDK 的 format 差异）
QianmianEnhancer_CFLAGS = \
    -fobjc-arc \
    -Wno-deprecated-declarations \
    -Wno-unguarded-availability \
    -Wno-unguarded-availability-new \
    -Wno-unused-variable \
    -Wno-unused-function \
    -Wno-format \
    -Wno-nullability-completeness \
    -Wno-nullability-extension \
    -Wno-nullable-to-nonnull-conversion

# ---------- 链接的框架 ----------
# UIKit         : UIView / UIWindow / UIButton 等
# CoreVideo     : CVPixelBuffer / CVBufferRef
# QuartzCore    : CALayer / CGAffineTransform 相关
# CoreGraphics  : CGContext / CGImage / CGColorSpace（UIKit 已含，显式列出更稳）
# CoreMedia     : CMSampleBuffer（若引用）
# PhotosUI      : PHPickerViewController / PHPickerConfiguration
# Photos        : PHPicker 内部依赖（显式列出）
# AVFoundation  : 若引用 AVAsset（当前未用，预留）
QianmianEnhancer_FRAMEWORKS = \
    UIKit \
    Foundation \
    CoreVideo \
    CoreMedia \
    CoreGraphics \
    QuartzCore \
    PhotosUI \
    Photos

# ---------- 私有框架（无） ----------
QianmianEnhancer_PRIVATE_FRAMEWORKS =

# ---------- 链接的库（无） ----------
# notify_post / notify_register_dispatch 在 libSystem 内，无需显式链接
QianmianEnhancer_LIBRARIES =

# ---------- 编译 .xm 文件（Logos 预处理） ----------
# Theos 自动处理 .xm 文件，无需额外配置

# ---------- 引入 Tweak 规则 ----------
include $(THEOS_MAKE_PATH)/tweak.mk

# ---------- 安装后重启目标进程 ----------
after-install::
	@echo "[QianmianEnhancer] 重启 SpringBoard 与 mediaserverd ..."
	install.exec "killall -9 SpringBoard" || true
	install.exec "killall -9 mediaserverd" || true
