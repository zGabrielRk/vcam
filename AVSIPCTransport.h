// AVSIPCTransport.h
// LordVCAM — IPC bridge between SpringBoard and mediaserverd
// Uses IOSurface shared memory + Darwin notifications for zero-copy frame sharing

#import <Foundation/Foundation.h>

// File-based logging (defined in KYCHooks.m)
extern void AVSLogWrite(NSString *format, ...);

#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>

// IOSurface C API — forward declarations (header not in Theos SDK)
typedef struct __IOSurface *IOSurfaceRef;
extern uint32_t IOSurfaceGetID(IOSurfaceRef surface);
extern IOSurfaceRef IOSurfaceLookup(uint32_t csid);
extern size_t IOSurfaceGetWidth(IOSurfaceRef surface);
extern size_t IOSurfaceGetHeight(IOSurfaceRef surface);
extern kern_return_t IOSurfaceLock(IOSurfaceRef surface, uint32_t options, uint32_t *seed);
extern kern_return_t IOSurfaceUnlock(IOSurfaceRef surface, uint32_t options, uint32_t *seed);
extern IOSurfaceRef CVPixelBufferGetIOSurface(CVPixelBufferRef pixelBuffer);
extern CVReturn CVPixelBufferCreateWithIOSurface(CFAllocatorRef allocator, IOSurfaceRef surface, CFDictionaryRef pixelBufferAttributes, CVPixelBufferRef *pixelBufferOut);

// IOSurface lock options
#define kIOSurfaceLockReadOnly 0x00000001

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
