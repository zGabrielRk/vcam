// AVSMediaDecoder.h
// LordVCAM - Reconstructed via reverse engineering of AVServicesd.dylib
// H.264/H.265 hardware decoder using VideoToolbox VTDecompressionSession

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <VideoToolbox/VideoToolbox.h>

// Supported pixel format tags (from __cstring):
//   420v  = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
//   420f  = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
//   BGRA  = kCVPixelFormatType_32BGRA
//   p420 / pf20 / x420 / xf20 = HEVC variants
//   &8v0 / &8f0 / &xv0 / &xf0 = ProRes variants

@interface AVSMediaDecoder : NSObject

@property (nonatomic, assign) VTDecompressionSessionRef session;
@property (nonatomic, assign) BOOL isReady;
@property (nonatomic, assign) BOOL isRunning;

// SPS/PPS parameter sets (H.264) or VPS/SPS/PPS (H.265)
@property (nonatomic, strong) NSData *spsData;
@property (nonatomic, strong) NSData *ppsData;

// Callback invoked on each decoded frame
@property (nonatomic, copy) void(^_avs_cfg_onDec)(CMSampleBufferRef);

// Decode a raw NAL unit buffer with sequence number
- (void)_avs_dec_process:(NSData *)data sequenceNumber:(int)seq;
- (void)_avs_dec_processInt:(NSData *)data sequenceNumber:(int)seq;

// Recreate VTDecompressionSession with new format description
- (void)_avs_dec_recreate:(CMVideoFormatDescriptionRef)fmtDesc;

// Wrap a CVPixelBuffer into a CMSampleBuffer
- (CMSampleBufferRef)_avs_dec_wrapBuf:(CVPixelBufferRef)pixelBuffer;

// Format helper
- (NSString *)decoder;
- (NSString *)decoder_de;  // "decoder_de" = decoder description extended

@end
