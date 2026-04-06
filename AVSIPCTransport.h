// AVSIPCTransport.h
// LordVCAM — IPC bridge between SpringBoard and mediaserverd
// Uses IOSurface shared memory + Darwin notifications for zero-copy frame sharing

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <IOSurface/IOSurface.h>

// Darwin notification names
#define kAVSIPCFrameNotification  "com.avsd.ipc.frame"
#define kAVSIPCStateNotification  "com.avsd.ipc.state"

// Shared file paths (under directory already created by KYCHooks ctor)
#define kAVSIPCSurfacePath  @"/var/tmp/com.apple.avfcache/ipc_surface.dat"
#define kAVSIPCStatePath    @"/var/tmp/com.apple.avfcache/ipc_state.dat"

// -----------------------------------------------------------------------
// Sender — runs in SpringBoard
// Publishes CVPixelBuffer via IOSurface for mediaserverd to read
// -----------------------------------------------------------------------
@interface AVSIPCSender : NSObject

- (void)publishPixelBuffer:(CVPixelBufferRef)pixelBuffer;
- (void)publishEnabled:(BOOL)enabled;
- (void)teardown;

@end

// -----------------------------------------------------------------------
// Receiver — runs in mediaserverd
// Listens for Darwin notifications and reads shared IOSurface
// -----------------------------------------------------------------------
@interface AVSIPCReceiver : NSObject

@property (nonatomic, copy) void (^onFrameReceived)(CMSampleBufferRef frame);
@property (nonatomic, copy) void (^onStateChanged)(BOOL enabled);

- (void)startListening;
- (void)stopListening;

@end
