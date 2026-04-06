// AVSFormatAnalyzer.m
// LordVCAM — Reconstruído via engenharia reversa de AVServicesd.dylib
// Detecta formato de pixel, resolução e FPS dos frames de entrada

#import "AVSFormatAnalyzer.h"
#import <CoreVideo/CoreVideo.h>
#import <os/lock.h>

// Mapeamento de OSType para string legível (conforme __cstring do binário)
static NSString *avs_pixfmt_tag(OSType fmt) {
    switch (fmt) {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:  return @"420v";
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:   return @"420f";
        case kCVPixelFormatType_32BGRA:                        return @"BGRA";
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange: return @"p420";
        case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:  return @"pf20";
        // ProRes
        case kCVPixelFormatType_422YpCbCr8:                   return @"2vuy";
        default: {
            char tag[5] = {0};
            tag[0] = (fmt >> 24) & 0xFF;
            tag[1] = (fmt >> 16) & 0xFF;
            tag[2] = (fmt >>  8) & 0xFF;
            tag[3] = (fmt      ) & 0xFF;
            return [NSString stringWithFormat:@"%.4s", tag];
        }
    }
}

@implementation AVSFormatAnalyzer {
    NSString   *_pixelFmtTag;
    int         _width;
    int         _height;
    double         _detectedFPS;
    double         _lastFrameTime;
    NSString      *_cachedInfo;    // rebuilt only when format/resolution changes
    os_unfair_lock _lock;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _pixelFmtTag    = @"???";
        _width          = 0;
        _height         = 0;
        _detectedFPS    = 0.0;
        _lastFrameTime  = 0.0;
        _fpsAccumulator = 0.0;
        _lastMetricsLog = 0.0;
        _lock = OS_UNFAIR_LOCK_INIT;
    }
    return self;
}

// -----------------------------------------------------------------------
// Detecta formato a partir de CMSampleBuffer
// -----------------------------------------------------------------------
- (void)_avs_fa_detect:(CMSampleBufferRef)sampleBuffer {
    if (!sampleBuffer) return;

    // Lê atributos do buffer fora do lock (CF calls são thread-safe para leitura)
    NSString *tag = nil;
    int w = 0, h = 0;

    CVImageBufferRef imgBuf = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (imgBuf) {
        tag = avs_pixfmt_tag(CVPixelBufferGetPixelFormatType(imgBuf));
        w   = (int)CVPixelBufferGetWidth(imgBuf);
        h   = (int)CVPixelBufferGetHeight(imgBuf);
    } else {
        CMFormatDescriptionRef fmtDesc = CMSampleBufferGetFormatDescription(sampleBuffer);
        if (fmtDesc) {
            tag = avs_pixfmt_tag(CMFormatDescriptionGetMediaSubType(fmtDesc));
            CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(fmtDesc);
            w = dims.width;
            h = dims.height;
        }
    }

    // EMA de FPS via timestamp de apresentação
    CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    double ts = 0.0;
    if (CMTIME_IS_VALID(pts)) {
        ts = CMTimeGetSeconds(pts);
    }

    // Aplica resultados com o lock apenas nas escritas
    os_unfair_lock_lock(&_lock);
    if (tag && (![tag isEqualToString:_pixelFmtTag] || w != _width || h != _height)) {
        _pixelFmtTag = tag; _width = w; _height = h;
        _cachedInfo = nil; // invalida cache quando formato/resolução muda
    }
    if (ts > 0.0) {
        if (_lastFrameTime > 0.0) {
            double delta = ts - _lastFrameTime;
            if (delta > 0.001 && delta < 1.0) {
                double instFPS = 1.0 / delta;
                _detectedFPS = (_detectedFPS == 0.0)
                    ? instFPS
                    : 0.9 * _detectedFPS + 0.1 * instFPS;
            }
        }
        _lastFrameTime = ts;
    }
    _fpsAccumulator++;
    os_unfair_lock_unlock(&_lock);
}

// -----------------------------------------------------------------------
// Retorna string descritiva, e.g. "420v 1920x1080 30fps"
// Cache invalidado em _avs_fa_detect: quando formato ou resolução muda.
// -----------------------------------------------------------------------
- (NSString *)_avs_fa_info {
    os_unfair_lock_lock(&_lock);
    NSString *cached = _cachedInfo;
    if (cached) {
        os_unfair_lock_unlock(&_lock);
        return cached;
    }
    // Lê todos os campos dentro do mesmo lock para evitar stale entre dois unlock/lock
    NSString *tag = _pixelFmtTag ?: @"???";
    int w   = _width;
    int h   = _height;
    int fps = (int)round(_detectedFPS);
    NSString *built = (w == 0 || h == 0)
        ? [NSString stringWithFormat:@"%@ (no frame)", tag]
        : [NSString stringWithFormat:@"%@ %dx%d %dfps", tag, w, h, fps];
    _cachedInfo = built;
    os_unfair_lock_unlock(&_lock);
    return built;
}

@end
