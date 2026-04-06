// VCPipelineStrategy.m
// LordVCAM — Reconstruído via engenharia reversa de AVServicesd.dylib
// Estratégia de pipeline: controla qualidade, GPU budget, degradação adaptativa

#import "VCPipelineStrategy.h"

static const int    kDefaultMemoryBudgetMB   = 128;
static const int    kDefaultPreRenderFPS     = 30;
static const int    kDefaultPreRenderQoS     = 0x21; // QOS_CLASS_USER_INTERACTIVE

// GPU timeouts por modo (nanosegundos)
static const uint64_t kGPUTimeoutStream_ns   = 16000000;   // 16ms (~60fps budget)
static const uint64_t kGPUTimeoutGallery_ns  = 33000000;   // 33ms (~30fps budget)
static const uint64_t kGPUTimeoutFilter_ns   = 50000000;   // 50ms (filtros pesados)

static const int kWarmupFrameCount = 3; // primeiros frames sem filtro

@implementation VCPipelineStrategy {
    int _warmupRemaining;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _initialDegradationLevel = 0;
        _memoryBudgetMB          = kDefaultMemoryBudgetMB;
        _preRenderFPS            = kDefaultPreRenderFPS;
        _preRenderQoS            = kDefaultPreRenderQoS;
        _frameBlendEnabled       = NO;
        _isStreamMode            = YES;
        _isFilterMode            = NO;
        _warmupRemaining         = kWarmupFrameCount;
    }
    return self;
}

- (uint64_t)gpuTimeoutNsForMode:(int)mode {
    switch (mode) {
        case 0:  return kGPUTimeoutStream_ns;   // stream
        case 1:  return kGPUTimeoutGallery_ns;  // galeria
        case 2:  return kGPUTimeoutFilter_ns;   // filtros
        default: return kGPUTimeoutStream_ns;
    }
}

- (BOOL)popWarmupFrame {
    if (_warmupRemaining > 0) {
        _warmupRemaining--;
        return YES; // sinaliza ao caller para pular filtros
    }
    return NO;
}

- (void)ensureReady {
    _warmupRemaining = kWarmupFrameCount;
}

- (void)frameBlendToggleChanged:(id)sender {
    _frameBlendEnabled = !_frameBlendEnabled;
    NSLog(@"[avsd] Frame blend: %@", _frameBlendEnabled ? @"ON" : @"OFF");
}

@end
