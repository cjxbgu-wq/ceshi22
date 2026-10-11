TARGET := iphone:clang:latest:14.0
ARCHS := arm64 arm64e
INSTALL_TARGET_PROCESSES = SpringBoard

export PATH := $(THEOS)/bin:$(PATH)

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = VCamPlus
VCamPlus_FILES = Tweak.xm
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
    $(error [VCamPlus] 请先运行: bash scripts/entry.sh)
  endif
endif

after-install::
	install.exec "killall -9 SpringBoard"
