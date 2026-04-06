// AVSAudioBridge.h
// LordVCAM - Reconstructed via reverse engineering of AVServicesd.dylib
// Audio PCM ring-buffer bridge: replaces microphone feed in mediaserverd

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

// Ring buffer approach:
//   _avs_ab_feed:count:channels:sampleRate:  → write PCM from network into ring buffer
//   _avs_ab_consume:count:channels:sampleRate: → read PCM, injected into audio callback

@interface AVSAudioBridge : NSObject

@property (nonatomic, assign) BOOL   isActive;
@property (nonatomic, assign) double audioSampleRate;  // e.g. 44100, 48000
@property (nonatomic, assign) int    _sourceChannels;  // 1=mono, 2=stereo

// Ring buffer management
- (void)clearRingBuffer;
- (void)clearRingLocked;
- (void)clearLastOutput;
- (BOOL)_avs_ab_feed:(const float *)samples count:(int)count channels:(int)ch sampleRate:(double)rate;
- (BOOL)_avs_ab_consume:(float *)output count:(int)count channels:(int)ch sampleRate:(double)rate;

// Audio credit (prevents stale silence injection)
- (void)setAudioCredit:(int)credit;

@end
