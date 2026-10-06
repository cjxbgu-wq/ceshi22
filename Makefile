ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:16.0
THEOS_PACKAGE_SCHEME = rootless
INSTALL_TARGET_PROCESSES = SpringBoard mediaserverd

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = QianmianEnhancer

QianmianEnhancer_FILES = Tweak.xm \
    QMEnhancerView.m

QianmianEnhancer_CFLAGS = -fobjc-arc -Wno-unused-function -Wno-unused-variable -Wno-deprecated-declarations
QianmianEnhancer_LDFLAGS = -Wl,-no_dead_strip_inits_and_terms
QianmianEnhancer_FRAMEWORKS = UIKit Foundation CoreVideo CoreMedia VideoToolbox CoreImage AVFoundation QuartzCore PhotosUI ImageIO
QianmianEnhancer_PRIVATE_FRAMEWORKS =
QianmianEnhancer_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 SpringBoard mediaserverd || true"
