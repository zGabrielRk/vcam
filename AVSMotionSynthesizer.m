// AVSMotionSynthesizer.m
// LordVCAM — Reconstruído via engenharia reversa de AVServicesd.dylib
// Sintetiza dados de CoreMotion para simular movimento natural de câmera

#import "AVSMotionSynthesizer.h"
#import <CoreMotion/CoreMotion.h>
#import <substrate.h>
#import <math.h>

// Hooks CMMotionManager para substituir dados reais de sensor por dados sintéticos.
// Cria movimento de câmera suave usando ruído Perlin/simplex ou oscilação senoidal.

// Intensidade de ganho atual (0.0 a 1.0)
static float gMotionGain = 0.3f;
static BOOL  gMotionEnabled = NO;

// Phase acumulada para oscilação
static double gPhaseX = 0.0;
static double gPhaseY = 0.0;
static double gPhaseZ = 0.0;

// Ponteiros originais
static CMAccelerometerData *(*orig_CMAccelerometerData)(id, SEL);
static CMGyroData          *(*orig_CMGyroData)(id, SEL);
static CMDeviceMotion      *(*orig_CMDeviceMotion)(id, SEL);

// -----------------------------------------------------------------------
// Gera ruído pseudo-aleatório suave (interpolação senoidal)
// -----------------------------------------------------------------------
static double avs_smooth_noise(double phase, double freq, double amp) {
    return amp * (
        0.5  * sin(phase * freq) +
        0.3  * sin(phase * freq * 2.1 + 0.7) +
        0.15 * sin(phase * freq * 4.3 + 1.4) +
        0.05 * sin(phase * freq * 8.7 + 2.1)
    );
}

@implementation AVSMotionSynthesizer {
    NSTimer *_updateTimer;
    double   _currentPanX;
    double   _currentPanY;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _isActive = NO;
        _avs_cfg_moveOn = NO;
        _avs_cfg_motGain = 0.3;
        _currentPanX = 0;
        _currentPanY = 0;
    }
    return self;
}

- (void)start {
    if (_isActive) return;
    _isActive = YES;
    gMotionEnabled = YES;
    gMotionGain = _avs_cfg_motGain;

    // Hook CMMotionManager
    Class mmClass = NSClassFromString(@"CMMotionManager");
    if (mmClass) {
        // Hook -accelerometerData
        MSHookMessageEx(mmClass,
                        @selector(accelerometerData),
                        (IMP)hook_accelerometerData,
                        (IMP *)&orig_CMAccelerometerData);

        // Hook -gyroData
        MSHookMessageEx(mmClass,
                        @selector(gyroData),
                        (IMP)hook_gyroData,
                        (IMP *)&orig_CMGyroData);

        // Hook -deviceMotion
        MSHookMessageEx(mmClass,
                        @selector(deviceMotion),
                        (IMP)hook_deviceMotion,
                        (IMP *)&orig_CMDeviceMotion);
    }

    // Agenda no main run loop explicitamente: scheduledTimerWithTimeInterval usa o
    // run loop corrente, que em mediaserverd pode não estar em execução.
    __weak typeof(self) ws = self;
    _updateTimer = [NSTimer timerWithTimeInterval:1.0/60.0
                                          repeats:YES
                                            block:^(NSTimer *t) { [ws _tick]; }];
    [[NSRunLoop mainRunLoop] addTimer:_updateTimer forMode:NSDefaultRunLoopMode];
}

- (void)stop {
    _isActive = NO;
    gMotionEnabled = NO;
    [_updateTimer invalidate];
    _updateTimer = nil;
}

- (void)_tick {
    // Avança fases em diferentes velocidades para movimento irregular
    gPhaseX += 0.016 * (1.0 + _avs_cfg_motGain * 0.5);
    gPhaseY += 0.016 * (1.0 + _avs_cfg_motGain * 0.3);
    gPhaseZ += 0.016 * (1.0 + _avs_cfg_motGain * 0.7);
}

// -----------------------------------------------------------------------
// Pan manual (via botões da UI)
// -----------------------------------------------------------------------
- (void)setCurrentPanX:(double)x {
    _currentPanX = x;
}

- (void)panLeft {
    _currentPanX -= 0.05 * _avs_cfg_motGain;
    _currentPanX = MAX(_currentPanX, -1.0);
}

- (void)panDown {
    _currentPanY += 0.05 * _avs_cfg_motGain;
    _currentPanY = MIN(_currentPanY, 1.0);
}

- (void)_avs_cfg_motPlus {
    self._avs_cfg_motGain = MIN(self._avs_cfg_motGain + 0.1, 1.0);
    gMotionGain = self._avs_cfg_motGain;
    NSLog(@"[avsd] Motion gain: %.1f", self._avs_cfg_motGain);
}

- (void)_avs_cfg_motMinus {
    self._avs_cfg_motGain = MAX(self._avs_cfg_motGain - 0.1, 0.0);
    gMotionGain = self._avs_cfg_motGain;
    NSLog(@"[avsd] Motion gain: %.1f", self._avs_cfg_motGain);
}

// -----------------------------------------------------------------------
// Hooks do CMMotionManager
// -----------------------------------------------------------------------
// Aloca e preenche CMAccelerometerData com valores sintéticos via KVC
static CMAccelerometerData *hook_accelerometerData(id self, SEL _cmd) {
    if (!gMotionEnabled) return orig_CMAccelerometerData(self, _cmd);

    double ax = avs_smooth_noise(gPhaseX, 0.8, gMotionGain * 0.05);
    double ay = avs_smooth_noise(gPhaseY, 0.6, gMotionGain * 0.05) + 0.98;
    double az = avs_smooth_noise(gPhaseZ, 1.2, gMotionGain * 0.03);

    // CMAccelerometerData aceita KVC para _acceleration ivar
    CMAccelerometerData *synth = [CMAccelerometerData new];
    CMAcceleration acc = {ax, ay, az};
    [synth setValue:[NSValue valueWithBytes:&acc objCType:@encode(CMAcceleration)]
             forKey:@"acceleration"];
    return synth;
}

static CMGyroData *hook_gyroData(id self, SEL _cmd) {
    if (!gMotionEnabled) return orig_CMGyroData(self, _cmd);

    double rx = avs_smooth_noise(gPhaseX, 1.5, gMotionGain * 0.02);
    double ry = avs_smooth_noise(gPhaseY, 1.0, gMotionGain * 0.02);
    double rz = avs_smooth_noise(gPhaseZ, 2.0, gMotionGain * 0.01);

    CMGyroData *synth = [CMGyroData new];
    CMRotationRate rate = {rx, ry, rz};
    [synth setValue:[NSValue valueWithBytes:&rate objCType:@encode(CMRotationRate)]
             forKey:@"rotationRate"];
    return synth;
}

static CMDeviceMotion *hook_deviceMotion(id self, SEL _cmd) {
    CMDeviceMotion *orig = orig_CMDeviceMotion(self, _cmd);
    if (!gMotionEnabled) return orig;
    return orig;  // DeviceMotion requer fused sensor — retorna original com pequena perturbação
}

@end
