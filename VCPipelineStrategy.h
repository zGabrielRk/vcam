// VCPipelineStrategy.h
// LordVCAM — Reconstruído via engenharia reversa de AVServicesd.dylib
// Estratégia de pipeline de vídeo: qualidade adaptativa, GPU budgets, degradação

#import <Foundation/Foundation.h>

@interface VCPipelineStrategy : NSObject

// Nível inicial de degradação (0 = máxima qualidade, valores maiores = menor qualidade)
@property (nonatomic, assign) int initialDegradationLevel;

// Budget de memória GPU em MB
@property (nonatomic, assign) int memoryBudgetMB;

// FPS alvo para pre-render
@property (nonatomic, assign) int preRenderFPS;

// QoS do pre-render (mapeado para dispatch_qos_class_t)
@property (nonatomic, assign) int preRenderQoS;

// Frame blending
@property (nonatomic, assign) BOOL frameBlendEnabled;

// Modo stream vs galeria
@property (nonatomic, assign) BOOL isStreamMode;
@property (nonatomic, assign) BOOL isFilterMode;

// Retorna timeout de GPU em nanosegundos para o modo atual
- (uint64_t)gpuTimeoutNsForMode:(int)mode;

// Pop de frame de warmup (primeiros N frames após connect — sem filtros)
- (BOOL)popWarmupFrame;

// Prepara pipeline para o modo stream/galeria
- (void)ensureReady;

// Alterna blending de frames
- (void)frameBlendToggleChanged:(id)sender;

@end
