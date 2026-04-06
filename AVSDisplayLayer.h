// AVSDisplayLayer.h
// LordVCAM - Reconstructed via reverse engineering of AVServicesd.dylib
// Custom AVSampleBufferDisplayLayer subclass for live preview in panel

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreMedia/CoreMedia.h>

@interface AVSDisplayLayer : NSObject

@property (nonatomic, assign) BOOL isReady;

// Returns the underlying CALayer to insert into a UIView
- (CALayer *)layer;

// Enqueues frame for display in preview window
- (void)_avs_dl_updFrame:(CMSampleBufferRef)frame;

@end
