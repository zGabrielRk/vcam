// AVServicesd.m
// LordVCAM — Reconstruído via engenharia reversa de AVServicesd.dylib
// Classe raiz: agrega coordinator, painel, config, e strategies
// O KYCHooks.m usa os globals (gCoordinator, gPanel, gConfig) diretamente,
// mas o binário original agrupa tudo nesta classe como ponto central.

#import "AVServicesd.h"
#import "AVSFrameCoordinator.h"
#import "AVSPreferencePanel.h"
#import "AVSServiceConfiguration.h"
#import "VCDefaultStrategy.h"
#import "VCPipelineStrategy.h"

@implementation AVServicesd

+ (instancetype)sharedInstance {
    static AVServicesd *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[AVServicesd alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _connectionStrategy = [[VCDefaultStrategy alloc] init];
        _pipelineStrategy   = [[VCPipelineStrategy alloc] init];
    }
    return self;
}

- (void)setupForMediaserverd {
    _coordinator = [[AVSFrameCoordinator alloc] init];
    _config      = [[AVSServiceConfiguration alloc] init];
    NSLog(@"[avsd] AVServicesd: mediaserverd setup complete");
}

- (void)setupForSpringBoard {
    _coordinator = [[AVSFrameCoordinator alloc] init];
    _config      = [[AVSServiceConfiguration alloc] init];
    _panel       = [[AVSPreferencePanel alloc] init];
    _panel.coordinator = _coordinator;
    [_panel setupWindows];
    NSLog(@"[avsd] AVServicesd: SpringBoard setup complete");
}

- (void)setupForUIKitApp {
    _coordinator = [[AVSFrameCoordinator alloc] init];
    NSLog(@"[avsd] AVServicesd: UIKit app setup complete");
}

@end
