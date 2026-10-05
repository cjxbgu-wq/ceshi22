ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = rootless
INSTALL_TARGET_PROCESSES = SpringBoard mediaserverd lskdd

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = QianmianEnhancer
QianmianEnhancer_FILES = Tweak.xm QMEnhancerView.m
QianmianEnhancer_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-function -Wno-unused-const-variable -Wno-unused-variable
QianmianEnhancer_FRAMEWORKS = UIKit CoreVideo CoreImage CoreGraphics QuartzCore
QianmianEnhancer_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk
