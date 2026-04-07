ARCHS = arm64 arm64e
TARGET = iphone:clang:16.5:15.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = LordVCAM

LordVCAM_FILES = Tweak.xm

LordVCAM_FRAMEWORKS = \
	Foundation \
	UIKit \
	AVFoundation \
	CoreMedia \
	CoreVideo \
	Photos \
	PhotosUI \
	QuartzCore

LordVCAM_PRIVATE_FRAMEWORKS = \
	CMCaptureCore \
	CMCapture

LordVCAM_LIBRARIES = substrate

LordVCAM_CFLAGS  = -fobjc-arc
LordVCAM_CCFLAGS = $(LordVCAM_CFLAGS)
LordVCAM_LDFLAGS = -framework IOSurface

INSTALL_TARGET_PROCESSES = SpringBoard mediaserverd

include $(THEOS)/makefiles/tweak.mk
