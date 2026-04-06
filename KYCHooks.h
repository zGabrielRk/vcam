// KYCHooks.h
// LordVCAM - Reconstructed via reverse engineering of AVServicesd.dylib
// KYC = "Know Your Camera" — the CydiaSubstrate injection entry point
// Hooks inserted into: mediaserverd, com.apple.springboard, com.apple.camera

#import <Foundation/Foundation.h>

// -----------------------------------------------------------------------
// Injection targets (from .plist filter):
//   Bundles:  mediaserverd, springboard, UIKit
//   Executables: mediaserverd, lskdd
//
// Private frameworks loaded at runtime (dlopen):
//   /System/Library/PrivateFrameworks/CMCaptureCore.framework/CMCaptureCore
//   /System/Library/PrivateFrameworks/CMCapture.framework/CMCapture
//   /System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices
// -----------------------------------------------------------------------

// -----------------------------------------------------------------------
// KYC Subsystem initialization log sequence:
//   [avsd-KYC] ctor starting in mediaserverd
//   [avsd-KYC] dlopen complete
//   [avsd-KYC] KYCCore initialized
//   [avsd-KYC] KYCMetadata initialized
//   [avsd-KYC] KYCSession initialized (FigCaptureClientSessionMonitor)
//   [avsd-KYC] KYCPhoto initialized
//   [avsd-KYC] KYCPhotoEncoder initialized (A11+)
//   [avsd-KYC] KYCOrientation initialized (FBSOrientationUpdate)
//   [avsd-KYC] init complete
// -----------------------------------------------------------------------

// Hooked private classes:
//   BWNodeOutput        - AVFoundation camera graph node output
//   BWGraph             - camera pipeline graph
//   BWNode              - generic pipeline node
//   BWMetadataSourceNode
//   BWVideoOrientationMetadataNode
//   BWMetadataDetectorGatingNode
//   BWStillImageScalerNode
//   BWPhotoEncoderNode
//   FigCaptureClientSessionMonitor  — session lifecycle events
//   AVCaptureConnection             — frame delivery hook point
//   AVCapturePhotoOutput            — photo capture hook
//   FBSOrientationUpdate            — device orientation (FrontBoardServices)

// Log tags used per injection path:
//   [avsd] [WK] #N ...          WebKit / non-camera app path
//   [avsd] [INJ-DBG] #N ...     debug injection info
//   [avsd-CACHE-AUDIT] #N ...   cache consistency
//   [avsd-SLOW] ...             slow-path (software scaling)
//   [avsd-AUDIT] #N ...         delivery audit
//   [avsd] [PROBE] %@           probe output per process

// Format codes injected (pixel buffer FourCC):
//   420v = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
//   420f = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
//   BGRA = kCVPixelFormatType_32BGRA
//   p420/pf20/x420/xf20 = HEVC 10-bit variants
//   &8v0/&8f0 = 8-bit ProRes
//   &xv0/&xf0 = 10-bit ProRes

// Photo injection hooks:
//   _addAuxImagesIfNeededForEncodingScheme:sampleBuffer:metadata:...
//   _addThumbnailForEncodingScheme:thumbnailPixelBuffer:...

// -----------------------------------------------------------------------
// Anti-detection checks (from __cstring error codes):
//   IC02 / 0xE7I1: internal integrity check
//   Trim / BL01:   conflicting tweak
//   BL02:          Frida/debugger
//   ep_0x03:       environment probe
//   fn_0x07:       function hook detection
//   0xE09:         network error
// -----------------------------------------------------------------------

// Probe system: writes per-process probe files
// Path: /var/tmp/com.apple.avfcache/probe_<processName>.txt
// Contains: injection status, frame counts, format info

// State persistence: /var/tmp/com.apple.avfcache/state.plist
//   "loaded" = YES when injected
//   "_avs_inj" = current injection mode

// -----------------------------------------------------------------------
// Virtual camera ID format: "_avc%08x" (hex random)
// -----------------------------------------------------------------------
