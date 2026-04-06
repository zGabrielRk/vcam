// AVSRenderPipeline.m
// LordVCAM — Reconstruído via engenharia reversa de AVServicesd.dylib
// Pipeline de renderização Metal GPU + CoreImage

#import "AVSRenderPipeline.h"
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <CoreImage/CoreImage.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>
#import <UIKit/UIKit.h>
#import <Accelerate/Accelerate.h>
#import <os/lock.h>

// Kernels Metal identificados no binário:
//   processFrameKernel
//   processFrameNV12Kernel
//   renderNV12Kernel
//   renderBGRAtoNV12Kernel
//
// Filtros CoreImage usados:
//   CIColorControls    → brightness, contrast, saturation
//   CIGammaAdjust      → gamma (power)
//   CIColorMatrix      → matriz RGB para grading avançado
//   CIAdditionCompositing → blend de frames
//   CIQRCodeGenerator  → QR para pagamento PIX

@implementation AVSRenderPipeline {
    id<MTLLibrary>  _library;
    id<MTLFunction> _processFrameKernelFn;
    id<MTLFunction> _processFrameNV12KernelFn;
    id<MTLFunction> _renderNV12KernelFn;
    id<MTLFunction> _renderBGRAtoNV12KernelFn;

    // Parâmetros de cor atuais
    float _brightness;   // -1.0 a 1.0
    float _contrast;     // 0.0 a 4.0  (1.0 = normal)
    float _saturation;   // 0.0 a 2.0  (1.0 = normal)
    float _gamma;        // 0.1 a 3.0  (1.0 = normal)

    // Estado de rotação/flip/zoom/pan
    float _currentScale;   // zoom
    float _currentPanX;
    float _currentPanY;
    BOOL  _flipHorizontal;
    int   _rotationDegrees; // 0, 90, 180, 270

    // Grain/noise
    BOOL  _grainEnabled;
    float _grainIntensity;

    // CIFilter instances cached para evitar alloc por frame
    CIFilter *_colorFilter;
    CIFilter *_gammaFilter;

    // Protege leituras/escritas de ivars de transform entre UI thread e decoder thread
    os_unfair_lock _transformLock;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _brightness = 0.0f;
        _contrast = 1.0f;
        _saturation = 1.0f;
        _gamma = 1.0f;
        _currentScale = 1.0f;
        _currentPanX = 0.0f;
        _currentPanY = 0.0f;
        _flipHorizontal = NO;
        _rotationDegrees = 0;
        _frameBlendEnabled = NO;
        _blendEnabled = NO;
        _transformLock = OS_UNFAIR_LOCK_INIT;
        _colorFilter = [CIFilter filterWithName:@"CIColorControls"];
        _gammaFilter = [CIFilter filterWithName:@"CIGammaAdjust"];
        [self _setupMetal];
    }
    return self;
}

- (void)dealloc {
    if (_textureCache) {
        CVMetalTextureCacheFlush(_textureCache, 0);
        CFRelease(_textureCache);
    }
}

// -----------------------------------------------------------------------
// Setup Metal
// -----------------------------------------------------------------------
- (void)_setupMetal {
    self.device = MTLCreateSystemDefaultDevice();
    if (!self.device) {
        NSLog(@"[avsd] Metal device not available");
        return;
    }

    self.commandQueue = [self.device newCommandQueue];

    // Texture cache para CVPixelBuffer → MTLTexture (zero-copy via IOSurface)
    CVMetalTextureCacheCreate(kCFAllocatorDefault, nil,
                              self.device, nil, &_textureCache);

    // Carrega shaders compilados embutidos no binário
    // (os kernels .metal são compilados e embutidos no __TEXT,__text)
    NSError *err = nil;
    _library = [self.device newDefaultLibrary];
    if (!_library) {
        // Fallback: compila inline
        NSString *shaderSrc = [self _metalShaderSource];
        _library = [self.device newLibraryWithSource:shaderSrc options:nil error:&err];
        if (err) NSLog(@"[avsd] Metal compile error: %@", err);
    }

    [self _buildPipelines];

    // Sampler para interpolação bilinear
    MTLSamplerDescriptor *sampDesc = [MTLSamplerDescriptor new];
    sampDesc.minFilter = MTLSamplerMinMagFilterLinear;
    sampDesc.magFilter = MTLSamplerMinMagFilterLinear;
    sampDesc.sAddressMode = MTLSamplerAddressModeClampToEdge;
    sampDesc.tAddressMode = MTLSamplerAddressModeClampToEdge;
    self.samplerState = [self.device newSamplerStateWithDescriptor:sampDesc];
}

- (void)_buildPipelines {
    NSError *err = nil;

    _processFrameKernelFn = [_library newFunctionWithName:@"processFrameKernel"];
    if (_processFrameKernelFn) {
        self.nv12Pipeline = [self.device newComputePipelineStateWithFunction:_processFrameKernelFn
                                                                       error:&err];
    }

    _processFrameNV12KernelFn = [_library newFunctionWithName:@"processFrameNV12Kernel"];
    if (_processFrameNV12KernelFn) {
        self.renderNV12Pipeline = [self.device newComputePipelineStateWithFunction:_processFrameNV12KernelFn
                                                                             error:&err];
    }

    _renderNV12KernelFn = [_library newFunctionWithName:@"renderNV12Kernel"];
    _renderBGRAtoNV12KernelFn = [_library newFunctionWithName:@"renderBGRAtoNV12Kernel"];
    if (_renderBGRAtoNV12KernelFn) {
        self.renderBGRAtoNV12Pipeline = [self.device newComputePipelineStateWithFunction:_renderBGRAtoNV12KernelFn
                                                                                   error:&err];
    }
}

// -----------------------------------------------------------------------
// CoreImage context (lazy)
// -----------------------------------------------------------------------
- (void)ensureCIContext {
    if (!self.ciContext) {
        self.ciContext = [CIContext contextWithMTLDevice:self.device
                                                options:@{
            kCIContextWorkingColorSpace: [NSNull null],
            kCIContextUseSoftwareRenderer: @NO,
        }];
    }
}

// -----------------------------------------------------------------------
// Processamento de frame principal
// Aplica: rotação, flip, zoom, pan, filtros de cor, grain, blend
// -----------------------------------------------------------------------
- (CMSampleBufferRef)processFrame:(CMSampleBufferRef)inputFrame {
    if (!inputFrame) return NULL;

    CVPixelBufferRef pixBuf = CMSampleBufferGetImageBuffer(inputFrame);
    if (!pixBuf) return NULL;

    [self ensureCIContext];

    // Cria CIImage a partir do pixel buffer
    CIImage *ciImage = [CIImage imageWithCVPixelBuffer:pixBuf];

    // Snapshot dos parâmetros de transform (pode ser escrito concorrentemente pelo UI thread)
    os_unfair_lock_lock(&_transformLock);
    BOOL   flip       = _flipHorizontal;
    int    rotation   = _rotationDegrees;
    float  scale      = _currentScale;
    float  panX       = _currentPanX;
    float  panY       = _currentPanY;
    float  brightness = _brightness;
    float  contrast   = _contrast;
    float  saturation = _saturation;
    float  gamma      = _gamma;
    os_unfair_lock_unlock(&_transformLock);

    // 1. Flip horizontal
    if (flip) {
        ciImage = [ciImage imageByApplyingTransform:CGAffineTransformMakeScale(-1, 1)];
    }

    // 2. Rotação
    if (rotation != 0) {
        CGFloat angle = -rotation * M_PI / 180.0;
        ciImage = [ciImage imageByApplyingTransform:
                   CGAffineTransformMakeRotation(angle)];
    }

    // 3. Zoom + Pan
    if (scale != 1.0f || panX != 0 || panY != 0) {
        CGAffineTransform t = CGAffineTransformMakeScale(scale, scale);
        t = CGAffineTransformTranslate(t, panX, panY);
        ciImage = [ciImage imageByApplyingTransform:t];
    }

    // 4. Color controls: só aplica quando diferente dos valores identidade
    if (brightness != 0.0f || contrast != 1.0f || saturation != 1.0f) {
        [_colorFilter setValue:ciImage       forKey:kCIInputImageKey];
        [_colorFilter setValue:@(brightness) forKey:@"inputBrightness"];
        [_colorFilter setValue:@(contrast)   forKey:@"inputContrast"];
        [_colorFilter setValue:@(saturation) forKey:@"inputSaturation"];
        ciImage = _colorFilter.outputImage;
    }

    // 5. Gamma: CIGammaAdjust
    if (gamma != 1.0f) {
        [_gammaFilter setValue:ciImage  forKey:kCIInputImageKey];
        [_gammaFilter setValue:@(gamma) forKey:@"inputPower"];
        ciImage = _gammaFilter.outputImage;
    }

    // 6. Frame blend (CIAdditionCompositing)
    if (_blendEnabled && self.lastBlendedBuffer) {
        CVPixelBufferRef lastPix = CMSampleBufferGetImageBuffer(self.lastBlendedBuffer);
        if (lastPix) {
            CIImage *lastCI = [CIImage imageWithCVPixelBuffer:lastPix];
            CIFilter *blendFilter = [CIFilter filterWithName:@"CIAdditionCompositing"];
            [blendFilter setValue:ciImage   forKey:kCIInputImageKey];
            [blendFilter setValue:lastCI    forKey:kCIInputBackgroundImageKey];
            ciImage = blendFilter.outputImage;
        }
    }

    // 7. Renderiza para novo CVPixelBuffer
    size_t width  = CVPixelBufferGetWidth(pixBuf);
    size_t height = CVPixelBufferGetHeight(pixBuf);
    OSType fmt    = CVPixelBufferGetPixelFormatType(pixBuf);

    CVPixelBufferRef outPixBuf = NULL;
    NSDictionary *attrs = @{
        (__bridge NSString *)kCVPixelBufferPixelFormatTypeKey: @(fmt),
        (__bridge NSString *)kCVPixelBufferMetalCompatibilityKey: @YES,
        (__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
    CVPixelBufferCreate(kCFAllocatorDefault, width, height, fmt,
                        (__bridge CFDictionaryRef)attrs, &outPixBuf);

    if (outPixBuf) {
        [self.ciContext render:ciImage toCVPixelBuffer:outPixBuf];
    }

    // Wrapa em CMSampleBuffer
    CMSampleBufferRef outSample = [self _wrapPixelBuffer:outPixBuf
                                             fromOriginal:inputFrame];
    if (outPixBuf) CVPixelBufferRelease(outPixBuf);
    return outSample;
}

- (CMSampleBufferRef)_wrapPixelBuffer:(CVPixelBufferRef)pixBuf
                          fromOriginal:(CMSampleBufferRef)original {
    if (!pixBuf) return NULL;

    CMVideoFormatDescriptionRef fmt = NULL;
    CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixBuf, &fmt);

    CMSampleTimingInfo timing;
    CMSampleBufferGetSampleTimingInfo(original, 0, &timing);

    CMSampleBufferRef outSample = NULL;
    CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, pixBuf, YES,
                                       NULL, NULL, fmt, &timing, &outSample);
    if (fmt) CFRelease(fmt);
    return outSample;
}

// -----------------------------------------------------------------------
// Resolução de renderização por modo
// -----------------------------------------------------------------------
- (CGSize)renderResolutionForSource:(id)source mode:(int)mode {
    // mode: 0=auto, 1=720p, 2=1080p, 3=4K
    switch (mode) {
        case 1: return CGSizeMake(1280, 720);
        case 2: return CGSizeMake(1920, 1080);
        case 3: return CGSizeMake(3840, 2160);
        default: return CGSizeMake(1920, 1080);
    }
}

- (CGSize)staleFrameDropThresholdForMode:(int)mode {
    // Threshold para descartar frames antigos (em ms)
    switch (mode) {
        case 0: return CGSizeMake(100, 50); // {ms_threshold, drop_count}
        case 1: return CGSizeMake(200, 100);
        default: return CGSizeMake(150, 75);
    }
}

// -----------------------------------------------------------------------
// Eyedropper: coleta cor de um ponto da imagem
// -----------------------------------------------------------------------
- (void)sampleColorAtPoint:(CGPoint)point fromBuffer:(CVPixelBufferRef)pixBuf {
    if (!pixBuf) return;

    CVPixelBufferLockBaseAddress(pixBuf, kCVPixelBufferLock_ReadOnly);

    size_t width  = CVPixelBufferGetWidth(pixBuf);
    size_t height = CVPixelBufferGetHeight(pixBuf);
    size_t bpr    = CVPixelBufferGetBytesPerRow(pixBuf);
    uint8_t *base = CVPixelBufferGetBaseAddress(pixBuf);

    size_t px = (size_t)(point.x * width);
    size_t py = (size_t)(point.y * height);
    px = MIN(px, width - 1);
    py = MIN(py, height - 1);

    uint8_t *pixel = base + py * bpr + px * 4;
    // BGRA format
    _lastEyeB = pixel[0] / 255.0;
    _lastEyeG = pixel[1] / 255.0;
    _lastEyeR = pixel[2] / 255.0;

    CVPixelBufferUnlockBaseAddress(pixBuf, kCVPixelBufferLock_ReadOnly);

    self.lastEyeR = _lastEyeR;
    self.lastEyeG = _lastEyeG;
    self.lastEyeB = _lastEyeB;
}

// -----------------------------------------------------------------------
// Orientação da imagem (EXIF/HEIC)
// "up-mirrored", "down", "down-mirrored", "left-mirrored",
// "right (portrait)", "right-mirrored", "left"
// -----------------------------------------------------------------------
- (UIImageOrientation)orientationFromString:(NSString *)str {
    if ([str isEqualToString:@"up-mirrored"])      return UIImageOrientationUpMirrored;
    if ([str isEqualToString:@"down"])             return UIImageOrientationDown;
    if ([str isEqualToString:@"down-mirrored"])    return UIImageOrientationDownMirrored;
    if ([str isEqualToString:@"left-mirrored"])    return UIImageOrientationLeftMirrored;
    if ([str isEqualToString:@"right (portrait)"]) return UIImageOrientationRight;
    if ([str isEqualToString:@"right-mirrored"])   return UIImageOrientationRightMirrored;
    if ([str isEqualToString:@"left"])             return UIImageOrientationLeft;
    return UIImageOrientationUp;
}

// -----------------------------------------------------------------------
// Reset de filtros
// -----------------------------------------------------------------------
- (void)_avs_fp_resetFlags {
    os_unfair_lock_lock(&_transformLock);
    _brightness = 0.0f;
    _contrast = 1.0f;
    _saturation = 1.0f;
    _gamma = 1.0f;
    _currentScale = 1.0f;
    _currentPanX = 0.0f;
    _currentPanY = 0.0f;
    _flipHorizontal = NO;
    _rotationDegrees = 0;
    _grainEnabled = NO;
    os_unfair_lock_unlock(&_transformLock);
}

// -----------------------------------------------------------------------
// Controles de transformação (chamados pelo painel de UI)
// -----------------------------------------------------------------------
// Limite de pan em pontos (independe de resolução — CIImage usa coordenadas de pixel)
static const float kMaxPan = 500.0f;

- (void)zoomIn  { os_unfair_lock_lock(&_transformLock); _currentScale = MIN(_currentScale + 0.1f, 4.0f); os_unfair_lock_unlock(&_transformLock); }
- (void)zoomOut { os_unfair_lock_lock(&_transformLock); _currentScale = MAX(_currentScale - 0.1f, 0.5f); os_unfair_lock_unlock(&_transformLock); }

- (void)rotateRight { os_unfair_lock_lock(&_transformLock); _rotationDegrees = (_rotationDegrees + 90) % 360;  os_unfair_lock_unlock(&_transformLock); }
- (void)rotateLeft  { os_unfair_lock_lock(&_transformLock); _rotationDegrees = (_rotationDegrees + 270) % 360; os_unfair_lock_unlock(&_transformLock); }

- (void)flipHorizontal { os_unfair_lock_lock(&_transformLock); _flipHorizontal = !_flipHorizontal; os_unfair_lock_unlock(&_transformLock); }

- (void)panUp    { os_unfair_lock_lock(&_transformLock); _currentPanY = MAX(_currentPanY - 20.0f, -kMaxPan); os_unfair_lock_unlock(&_transformLock); }
- (void)panDown  { os_unfair_lock_lock(&_transformLock); _currentPanY = MIN(_currentPanY + 20.0f,  kMaxPan); os_unfair_lock_unlock(&_transformLock); }
- (void)panLeft  { os_unfair_lock_lock(&_transformLock); _currentPanX = MAX(_currentPanX - 20.0f, -kMaxPan); os_unfair_lock_unlock(&_transformLock); }
- (void)panRight { os_unfair_lock_lock(&_transformLock); _currentPanX = MIN(_currentPanX + 20.0f,  kMaxPan); os_unfair_lock_unlock(&_transformLock); }

- (void)gammaUp   { os_unfair_lock_lock(&_transformLock); _gamma = MIN(_gamma + 0.1f, 3.0f); os_unfair_lock_unlock(&_transformLock); }
- (void)gammaDown { os_unfair_lock_lock(&_transformLock); _gamma = MAX(_gamma - 0.1f, 0.1f); os_unfair_lock_unlock(&_transformLock); }

- (void)_avs_fp_wrapBuf:(CMSampleBufferRef)buf {
    // Manage retain/release manually: the property is 'assign' (ARC doesn't manage CF types).
    CMSampleBufferRef old = self.lastBlendedBuffer;
    if (buf) CFRetain(buf);
    self.lastBlendedBuffer = buf;
    if (old) CFRelease(old);
}

- (void)_avs_fp_transition:(id)transition duration:(double)duration {
    // Transição suave entre fontes (fade, dissolve)
    // Usa CIAdditionCompositing com alpha decrescente
}

// -----------------------------------------------------------------------
// Metal shader source (fallback caso o binário não contenha o .metallib)
// -----------------------------------------------------------------------
- (NSString *)_metalShaderSource {
    return @""
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "\n"
    "// Processa frame YCbCr NV12 com transformações de cor\n"
    "kernel void processFrameNV12Kernel(\n"
    "    texture2d<float, access::read>  inY   [[texture(0)]],\n"
    "    texture2d<float, access::read>  inCbCr [[texture(1)]],\n"
    "    texture2d<float, access::write> outY   [[texture(2)]],\n"
    "    texture2d<float, access::write> outCbCr [[texture(3)]],\n"
    "    constant float4 &params            [[buffer(0)]],\n"
    "    uint2 gid                          [[thread_position_in_grid]])\n"
    "{\n"
    "    float brightness = params.x;\n"
    "    float contrast   = params.y;\n"
    "    float saturation = params.z;\n"
    "    float gamma      = params.w;\n"
    "    float4 y  = inY.read(gid);\n"
    "    float yVal = clamp(y.r * contrast + brightness, 0.0f, 1.0f);\n"
    "    yVal = pow(yVal, gamma);\n"
    "    outY.write(float4(yVal, 0, 0, 1), gid);\n"
    "    if (gid.x % 2 == 0 && gid.y % 2 == 0) {\n"
    "        uint2 cgid = gid / 2;\n"
    "        float4 cbcr = inCbCr.read(cgid);\n"
    "        float cb = (cbcr.r - 0.5f) * saturation + 0.5f;\n"
    "        float cr = (cbcr.g - 0.5f) * saturation + 0.5f;\n"
    "        outCbCr.write(float4(cb, cr, 0, 1), cgid);\n"
    "    }\n"
    "}\n"
    "\n"
    "// Converte BGRA para NV12\n"
    "kernel void renderBGRAtoNV12Kernel(\n"
    "    texture2d<float, access::read>  inBGRA  [[texture(0)]],\n"
    "    texture2d<float, access::write> outY    [[texture(1)]],\n"
    "    texture2d<float, access::write> outCbCr [[texture(2)]],\n"
    "    uint2 gid [[thread_position_in_grid]])\n"
    "{\n"
    "    float4 bgra = inBGRA.read(gid);\n"
    "    float b = bgra.r, g = bgra.g, r = bgra.b;\n"
    "    float y  =  0.2126f*r + 0.7152f*g + 0.0722f*b;\n"
    "    float cb = -0.1146f*r - 0.3854f*g + 0.5000f*b + 0.5f;\n"
    "    float cr =  0.5000f*r - 0.4542f*g - 0.0458f*b + 0.5f;\n"
    "    outY.write(float4(y, 0, 0, 1), gid);\n"
    "    if (gid.x % 2 == 0 && gid.y % 2 == 0) {\n"
    "        outCbCr.write(float4(cb, cr, 0, 1), gid / 2);\n"
    "    }\n"
    "}\n"
    "\n"
    "// Render NV12 para textura de exibição\n"
    "kernel void renderNV12Kernel(\n"
    "    texture2d<float, access::read>  inY    [[texture(0)]],\n"
    "    texture2d<float, access::read>  inCbCr [[texture(1)]],\n"
    "    texture2d<float, access::write> outRGBA [[texture(2)]],\n"
    "    uint2 gid [[thread_position_in_grid]])\n"
    "{\n"
    "    float y  = inY.read(gid).r;\n"
    "    float cb = inCbCr.read(gid/2).r - 0.5f;\n"
    "    float cr = inCbCr.read(gid/2).g - 0.5f;\n"
    "    float r = clamp(y + 1.5748f*cr, 0.f, 1.f);\n"
    "    float g = clamp(y - 0.1873f*cb - 0.4681f*cr, 0.f, 1.f);\n"
    "    float b = clamp(y + 1.8556f*cb, 0.f, 1.f);\n"
    "    outRGBA.write(float4(r, g, b, 1), gid);\n"
    "}\n";
}

@end
