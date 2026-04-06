// AVSMotionSynthesizer.h
// LordVCAM - Reconstructed via reverse engineering of AVServicesd.dylib
// Synthesizes CoreMotion data (accelerometer/gyro/device motion) to fake camera movement

#import <Foundation/Foundation.h>
#import <CoreMotion/CoreMotion.h>

// Hooks CMMotionManager, synthesizes CMAccelerometerData, CMGyroData, CMDeviceMotion
// Injects artificial motion so live video appears to have natural camera shake

@interface AVSMotionSynthesizer : NSObject

@property (nonatomic, assign) BOOL   isActive;
@property (nonatomic, assign) BOOL   _avs_cfg_moveOn;  // motion enabled
@property (nonatomic, assign) double _avs_cfg_motGain; // motion intensity (0.0–1.0)

// Lifecycle
- (void)start;
- (void)stop;

// Pan controls (UI buttons → current pan offsets)
@property (nonatomic, assign) double currentPanX;
- (void)panLeft;
- (void)panDown;

// Motion gain
- (void)_avs_cfg_motPlus;
- (void)_avs_cfg_motMinus;

@end
