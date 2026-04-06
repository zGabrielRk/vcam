ARCHS = arm64
TARGET = iphone:clang:16.5:15.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = LordVCAM

LordVCAM_FILES = \
	Tweak.xm \
	KYCHooks.m \
	AVSFrameCoordinator.m \
	AVSRenderPipeline.m \
	AVSMediaDecoder.m \
	AVSAudioBridge.m \
	AVSDataProvider.m \
	AVSFormatAnalyzer.m \
	AVSMotionSynthesizer.m \
	AVSAccessibilityOverlay.m \
	AVSPreferencePanel.m \
	AVSDisplayLayer.m \
	AVSWSProtocol.m \
	AVSIPCTransport.m

LordVCAM_FRAMEWORKS = \
	Foundation \
	UIKit \
	AVFoundation \
	CoreMedia \
	CoreVideo \
	Metal \
	MetalKit \
	CoreImage \
	VideoToolbox \
	CoreMotion \
	Photos \
	PhotosUI \
	Accelerate \
	QuartzCore

LordVCAM_PRIVATE_FRAMEWORKS = \
	IOKit \
	CMCaptureCore \
	CMCapture \
	FrontBoardServices

LordVCAM_LIBRARIES = substrate

LordVCAM_CFLAGS  = -fobjc-arc -I$(THEOS_PROJECT_DIR) -I$(THEOS)/include
LordVCAM_CCFLAGS = $(LordVCAM_CFLAGS)
LordVCAM_LDFLAGS = -framework IOSurface

INSTALL_TARGET_PROCESSES = SpringBoard mediaserverd

include $(THEOS)/makefiles/tweak.mk
