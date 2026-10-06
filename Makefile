ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:16.0
INSTALL_TARGET_PROCESSES = SpringBoard mediaserverd

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = QianmianEnhancer

QianmianEnhancer_FILES = Tweak.xm \
    QMEnhancerView.m

QianmianEnhancer_CFLAGS = -fobjc-arc -Wno-unused-function -Wno-unused-variable -Wno-deprecated-declarations
QianmianEnhancer_FRAMEWORKS = UIKit Foundation CoreVideo CoreMedia VideoToolbox CoreImage AVFoundation QuartzCore PhotosUI ImageIO
QianmianEnhancer_PRIVATE_FRAMEWORKS =
QianmianEnhancer_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 SpringBoard mediaserverd || true"
