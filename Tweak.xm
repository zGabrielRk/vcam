// Tweak.xm
// LordVCAM - Logos entry point
// Must match original structure for MobileLoader compatibility

#import <substrate.h>
#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <AVFoundation/AVFoundation.h>
#import "AVSFrameCoordinator.h"
#import "AVSRenderPipeline.h"
#import "AVSMediaDecoder.h"
#import "KYCHooks.h"

// Hook: BWNodeOutput — kept for Logos compatibility
// Actual copyNextSampleBuffer hook is in KYCHooks.m via MSHookMessageEx
%hook BWNodeOutput

- (void)dealloc {
    %orig;
}

%end

// Hook: AVCaptureConnection — placeholder for future injection
%hook AVCaptureConnection

%end
