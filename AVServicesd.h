// AVServicesd.h
// LordVCAM — Reconstruído via engenharia reversa de AVServicesd.dylib
// Classe raiz do tweak — ponto de entrada e coordenação global

#import <Foundation/Foundation.h>

@class AVSFrameCoordinator;
@class AVSPreferencePanel;
@class AVSServiceConfiguration;
@class VCDefaultStrategy;
@class VCPipelineStrategy;

@interface AVServicesd : NSObject

@property (nonatomic, strong) AVSFrameCoordinator     *coordinator;
@property (nonatomic, strong) AVSPreferencePanel       *panel;
@property (nonatomic, strong) AVSServiceConfiguration  *config;
@property (nonatomic, strong) VCDefaultStrategy        *connectionStrategy;
@property (nonatomic, strong) VCPipelineStrategy       *pipelineStrategy;

// Singleton
+ (instancetype)sharedInstance;

// Inicialização por processo
- (void)setupForMediaserverd;
- (void)setupForSpringBoard;
- (void)setupForUIKitApp;

@end
