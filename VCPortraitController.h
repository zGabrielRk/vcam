// VCPortraitController.h
// LordVCAM — Reconstruído via engenharia reversa de AVServicesd.dylib
// Força orientação retrato para manter frame injection consistente

#import <UIKit/UIKit.h>

@interface VCPortraitController : UIViewController

// Rotação atual do dispositivo (0=portrait, 90=landscape left, etc.)
@property (nonatomic, assign) int currentRotation;

@end
