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
# 【修正】移除 crypto（iOS 无此库，CommonCrypto 在 libSystem）
VCamPlus_LIBRARIES = substrate z

include $(THEOS_MAKE_PATH)/tweak.mk

# 【强制】未打补丁不允许编译
before-all::
	@if [ ! -f "$(THEOS_PROJECT_DIR)/.patched" ]; then \
	    echo "================================================================"; \
	    echo "[!] 未检测到 .patched 标记"; \
	    echo "[!] 请先执行：  bash scripts/entry.sh"; \
	    echo "[!] 本项目要求「补丁方式进入」，禁止直接 make"; \
	    echo "================================================================"; \
	    exit 1; \
	fi

after-install::
	install.exec "killall -9 SpringBoard"
