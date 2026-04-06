// VCPortraitController.m
// LordVCAM — Reconstruído via engenharia reversa de AVServicesd.dylib
// UIViewController que força retrato — usado como rootViewController
// dos UIWindows do painel para garantir orientação consistente

#import "VCPortraitController.h"

@implementation VCPortraitController

- (instancetype)init {
    self = [super init];
    if (self) {
        _currentRotation = 0;
    }
    return self;
}

// Força orientação retrato
- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskPortrait;
}

- (UIInterfaceOrientation)preferredInterfaceOrientationForPresentation {
    return UIInterfaceOrientationPortrait;
}

- (BOOL)shouldAutorotate {
    return NO;
}

- (BOOL)prefersStatusBarHidden {
    return YES;
}

- (UIStatusBarStyle)preferredStatusBarStyle {
    return UIStatusBarStyleLightContent;
}

@end
