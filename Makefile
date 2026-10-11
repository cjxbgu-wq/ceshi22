TARGET := iphone:clang:latest:14.0
ARCHS := arm64 arm64e
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = VCamPlus
VCamPlus_FILES = Tweak.xm

# ============================================================
# 关键：把所有「警告升级为错误」的 -Werror 关掉
#   -Wno-error                        : 全局关闭 -Werror
#   -Wno-error=unguarded-availability-new  : SecTrust API 兼容
#   -Wno-error=incomplete-implementation   : FWCtrl +hide 缺失
#   -Wno-unguarded-availability-new        : 静默该警告
#   -Wno-incomplete-implementation         : 静默该警告
# ============================================================
VCamPlus_CFLAGS = -fobjc-arc \
    -Wno-deprecated-declarations \
    -Wno-unused-function \
    -Wno-objc-missing-super-calls \
    -Wno-error \
    -Wno-error=unguarded-availability-new \
    -Wno-error=incomplete-implementation \
    -Wno-unguarded-availability-new \
    -Wno-incomplete-implementation

VCamPlus_FRAMEWORKS = UIKit AVFoundation CoreImage Vision CoreMedia \
    CoreVideo Photos WebKit Security
VCamPlus_PRIVATE_FRAMEWORKS = IOSurface
VCamPlus_LIBRARIES = substrate z

include $(THEOS_MAKE_PATH)/tweak.mk

ifneq ($(filter clean uninstall,$(MAKECMDGOALS)),)
else
  ifeq ($(wildcard $(CURDIR)/.patched),)
    $(error [VCam] 未检测到 .patched —— 请先运行: bash scripts/entry.sh)
  endif
endif

after-install::
	install.exec "killall -9 SpringBoard"
