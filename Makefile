TARGET := iphone:clang:latest:14.0
ARCHS := arm64 arm64e
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = VCamPlus
VCamPlus_FILES = Tweak.xm
VCamPlus_CFLAGS = -fobjc-arc \
    -Wno-deprecated-declarations \
    -Wno-unused-function \
    -Wno-objc-missing-super-calls
VCamPlus_FRAMEWORKS = UIKit AVFoundation CoreImage Vision CoreMedia \
    CoreVideo Photos WebKit Security
VCamPlus_PRIVATE_FRAMEWORKS = IOSurface
# 注意：移除 crypto（iOS 无 libcrypto，CommonCrypto 在 libSystem）
VCamPlus_LIBRARIES = substrate z

include $(THEOS_MAKE_PATH)/tweak.mk

# 【强制】未打补丁不允许编译（make 解析期守卫，不依赖 Theos 钩子）
ifneq ($(filter clean uninstall,$(MAKECMDGOALS)),)
else
  ifeq ($(wildcard $(CURDIR)/.patched),)
    $(error [VCam] 未检测到 .patched —— 请先运行: bash scripts/entry.sh)
  endif
endif

after-install::
	install.exec "killall -9 SpringBoard"
