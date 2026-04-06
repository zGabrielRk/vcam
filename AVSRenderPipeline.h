// AVSRenderPipeline.h
// LordVCAM - Reconstructed via reverse engineering of AVServicesd.dylib
// Metal GPU render pipeline: color grading, scaling, format conversion

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <CoreImage/CoreImage.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>

// Metal compute kernels (from __cstring):
//   processFrameKernel       - main frame processing
//   processFrameNV12Kernel   - NV12 (420v/420f) processing
//   renderNV12Kernel         - render NV12 to texture
//   renderBGRAtoNV12Kernel   - convert BGRA -> NV12

// CoreImage filters used:
//   CIColorControls   (brightness, contrast, saturation)
//   CIGammaAdjust     (gamma)
//   CIColorMatrix     (RGB matrix for color grade)
//   CIAdditionCompositing (frame blending)
//   CIQRCodeGenerator (QR code for PIX payments)

@interface AVSRenderPipeline : NSObject

// Metal objects
@property (nonatomic, strong) id<MTLDevice>              device;
@property (nonatomic, strong) id<MTLCommandQueue>        commandQueue;
@property (nonatomic, strong) id<MTLSamplerState>        samplerState;
@property (nonatomic, strong) id<MTLComputePipelineState> nv12Pipeline;
@property (nonatomic, strong) id<MTLComputePipelineState> bgraPipeline;
@property (nonatomic, strong) id<MTLComputePipelineState> renderNV12Pipeline;
@property (nonatomic, strong) id<MTLComputePipelineState> renderBGRAtoNV12Pipeline;
@property (nonatomic, assign) CVMetalTextureCacheRef textureCache;

// CoreImage
@property (nonatomic, strong) CIContext *ciContext;

// Color adjustment parameters (all normalized 0.0-1.0 or -1.0 to 1.0)
@property (nonatomic, assign) double currentContrast;  // CIColorControls inputContrast
@property (nonatomic, assign) double currentRotation;  // image rotation

// Eyedropper (background color sampling)
@property (nonatomic, assign) double lastEyeR;
@property (nonatomic, assign) double lastEyeG;
@property (nonatomic, assign) double lastEyeB;

// Frame blending
@property (nonatomic, assign) BOOL frameBlendEnabled;
@property (nonatomic, assign) BOOL blendEnabled;
@property (nonatomic, assign) CMSampleBufferRef lastBlendedBuffer;

// Photo mode (still image capture)
@property (nonatomic, assign) CVBufferRef photoBuffer;
@property (nonatomic, strong) UIImage    *photoImage;

// Resolution helpers
- (CGSize)renderResolutionForSource:(id)source mode:(int)mode;
- (CGSize)staleFrameDropThresholdForMode:(int)mode;

// Render
- (CMSampleBufferRef)processFrame:(CMSampleBufferRef)inputFrame;
- (void)ensureCIContext;
- (void)_avs_fp_wrapBuf:(CMSampleBufferRef)buf;
- (void)_avs_fp_transition:(id)transition duration:(double)duration;
- (void)_avs_fp_resetFlags;

// Transform controls (delegated from UI panel)
- (void)zoomIn;
- (void)zoomOut;
- (void)rotateRight;
- (void)rotateLeft;
- (void)flipHorizontal;
- (void)panUp;
- (void)panDown;
- (void)panLeft;
- (void)panRight;
- (void)gammaUp;
- (void)gammaDown;

// Format detection is handled by AVSFormatAnalyzer, not the render pipeline.

@end
