ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:15.0
INSTALL_TARGET_PROCESSES = SpringBoard mediaserverd lskdd

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = VCamEnhancer
VCamEnhancer_FILES = Tweak.xm QMEnhancerView.m
VCamEnhancer_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-function -Wno-unused-const-variable -Wno-unused-variable
VCamEnhancer_FRAMEWORKS = UIKit CoreVideo CoreImage CoreGraphics QuartzCore
VCamEnhancer_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk
