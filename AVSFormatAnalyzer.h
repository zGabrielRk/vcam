// AVSFormatAnalyzer.h
// LordVCAM - Reconstructed via reverse engineering of AVServicesd.dylib
// Detects pixel format, resolution, FPS of incoming camera/video frames

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>

@interface AVSFormatAnalyzer : NSObject

// Detection
- (void)_avs_fa_detect:(CMSampleBufferRef)sampleBuffer;
- (NSString *)_avs_fa_info;  // returns format string e.g. "420v 1920x1080 30fps"

// FPS tracking
@property (nonatomic, assign) double _fpsAccumulator;
@property (nonatomic, assign) double _lastMetricsLog;

@end
