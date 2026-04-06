// Tweak.xm
// LordVCAM - Reconstructed Logos/CydiaSubstrate tweak entry point
// Based on reverse engineering of AVServicesd.dylib
//
// NOTE: The __attribute__((constructor)) entry point lives exclusively in
// KYCHooks.m. This file contains only Logos %hook blocks that complement
// the MSHookMessageEx hooks installed there. Having a second constructor
// here would cause double-initialization of all globals (gCoordinator,
// gPanel, etc.) and double hook installation.

#import <substrate.h>
#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <AVFoundation/AVFoundation.h>
#import "AVSFrameCoordinator.h"
#import "AVSRenderPipeline.h"
#import "AVSMediaDecoder.h"
#import "KYCHooks.h"

// -----------------------------------------------------------------------
// Hook: BWNodeOutput — intercept raw camera frames in mediaserverd
// dealloc override kept for diagnostic logging only.
// The actual copyNextSampleBuffer hook is installed via MSHookMessageEx
// in KYCHooks.m (AVSFrameCoordinator_setup_mediaserverd).
// -----------------------------------------------------------------------
%hook BWNodeOutput

- (void)dealloc {
    NSLog(@"[avsd] BWNodeOutput dealloc");
    %orig;
}

%end

// -----------------------------------------------------------------------
// Hook: AVCaptureConnection — main frame injection point
// Each frame goes through this hook before reaching the app
//
// Injection decision tree (from log strings):
//   1. Check if replacement is enabled (_avs_cfg_replOn)
//   2. Check for double-injection (skip if _avs_inj already set)
//      → [avsd] [WK] #N SKIP double-inj WxH
//   3. If no source: deliver original
//      → [avsd] [WK] #N ORIG (no source at all) WxH
//   4. If no rotated pixel buffer yet:
//      → [avsd] [WK] #N ORIG (no rotatedPB yet) WxH
//   5. If raw mode:
//      → [avsd] [WK] #N NO-PROCESSED (raw) WxH
//   6. Fast path via VT (VideoToolbox):
//      → [avsd-AUDIT] #N dst=WxH(ar) src=WxH(ar) crop=N% front=N path=VT
//   7. Slow path (software):
//      → [avsd] [WK] #N SLOW-PATH WxH aspect=ar camApp=N needsCCW90=N front=N
// -----------------------------------------------------------------------
%hook AVCaptureConnection

%end

// -----------------------------------------------------------------------
// Hook: FigCaptureClientSessionMonitor — session lifecycle
// (hooks handled internally via MSHookMessageEx in KYCHooks.m)
// -----------------------------------------------------------------------

// -----------------------------------------------------------------------
// Signal handler setup (crash reporter)
// Catches: SIGSEGV, SIGBUS, SIGFPE
// Writes crash log to: /var/tmp/com.apple.avfcache/crash.txt
// -----------------------------------------------------------------------
