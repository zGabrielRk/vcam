// AVSIPCTransport.m
// LordVCAM — IPC bridge between SpringBoard and mediaserverd
// Zero-copy frame sharing via IOSurface + Darwin notifications

#import "AVSIPCTransport.h"
#import <notify.h>

// -----------------------------------------------------------------------
// AVSIPCSender — SpringBoard side
// -----------------------------------------------------------------------
@implementation AVSIPCSender {
    uint32_t _lastSurfaceID;
}

static int _pubCount = 0;
- (void)publishPixelBuffer:(CVPixelBufferRef)pixelBuffer {
    _pubCount++;
    if (!pixelBuffer) return;

    IOSurfaceRef surface = CVPixelBufferGetIOSurface(pixelBuffer);
    if (!surface) {
        if (_pubCount % 60 == 1) {
            AVSLogWrite(@"[avsd-IPC-TX] #%d WARNING: pixelBuffer %p is NOT IOSurface-backed (fmt=%u %zux%zu)",
                  _pubCount, pixelBuffer,
                  (unsigned)CVPixelBufferGetPixelFormatType(pixelBuffer),
                  CVPixelBufferGetWidth(pixelBuffer),
                  CVPixelBufferGetHeight(pixelBuffer));
        }
        return;
    }

    uint32_t sid = IOSurfaceGetID(surface);

    // Only write metadata file when surface ID changes (new allocation)
    if (sid != _lastSurfaceID) {
        _lastSurfaceID = sid;

        NSDictionary *meta = @{
            @"sid": @(sid),
            @"w":   @((uint32_t)CVPixelBufferGetWidth(pixelBuffer)),
            @"h":   @((uint32_t)CVPixelBufferGetHeight(pixelBuffer)),
            @"fmt": @((uint32_t)CVPixelBufferGetPixelFormatType(pixelBuffer)),
        };
        NSData *data = [NSPropertyListSerialization
                        dataWithPropertyList:meta
                        format:NSPropertyListBinaryFormat_v1_0
                        options:0 error:nil];
        [data writeToFile:kAVSIPCSurfacePath atomically:YES];
        AVSLogWrite(@"[avsd-IPC] Published surface ID=%u %ux%u fmt=%u",
              sid,
              (uint32_t)CVPixelBufferGetWidth(pixelBuffer),
              (uint32_t)CVPixelBufferGetHeight(pixelBuffer),
              (uint32_t)CVPixelBufferGetPixelFormatType(pixelBuffer));
    }

    // Signal mediaserverd — lightweight (~5us)
    notify_post(kAVSIPCFrameNotification);
}

- (void)publishEnabled:(BOOL)enabled {
    NSDictionary *state = @{ @"enabled": @(enabled) };
    NSData *data = [NSPropertyListSerialization
                    dataWithPropertyList:state
                    format:NSPropertyListBinaryFormat_v1_0
                    options:0 error:nil];
    [data writeToFile:kAVSIPCStatePath atomically:YES];
    notify_post(kAVSIPCStateNotification);
    AVSLogWrite(@"[avsd-IPC] Published state enabled=%d", enabled);
}

- (void)teardown {
    [self publishEnabled:NO];
    _lastSurfaceID = 0;
}

@end

// -----------------------------------------------------------------------
// AVSIPCReceiver — mediaserverd side
// -----------------------------------------------------------------------
@implementation AVSIPCReceiver {
    int _frameToken;
    int _stateToken;
    IOSurfaceRef _attachedSurface;
    uint32_t _lastSurfaceID;
    dispatch_queue_t _ipcQueue;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _frameToken = NOTIFY_TOKEN_INVALID;
        _stateToken = NOTIFY_TOKEN_INVALID;
        _ipcQueue = dispatch_queue_create("com.avsd.ipc.receiver",
                                          DISPATCH_QUEUE_SERIAL);
        dispatch_set_target_queue(_ipcQueue,
            dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0));
    }
    return self;
}

- (void)startListening {
    __weak typeof(self) ws = self;

    notify_register_dispatch(kAVSIPCFrameNotification,
                             &_frameToken,
                             _ipcQueue,
                             ^(int token) { [ws _handleNewFrame]; });

    notify_register_dispatch(kAVSIPCStateNotification,
                             &_stateToken,
                             _ipcQueue,
                             ^(int token) { [ws _handleStateChange]; });

    AVSLogWrite(@"[avsd-IPC] Receiver listening for frames and state changes");
}

- (void)stopListening {
    if (_frameToken != NOTIFY_TOKEN_INVALID) {
        notify_cancel(_frameToken);
        _frameToken = NOTIFY_TOKEN_INVALID;
    }
    if (_stateToken != NOTIFY_TOKEN_INVALID) {
        notify_cancel(_stateToken);
        _stateToken = NOTIFY_TOKEN_INVALID;
    }
    if (_attachedSurface) {
        CFRelease(_attachedSurface);
        _attachedSurface = NULL;
    }
}

static int _recvFrameCount = 0;
- (void)_handleNewFrame {
    _recvFrameCount++;
    // Read surface metadata if we don't have a surface yet
    if (!_attachedSurface || [self _surfaceIDChanged]) {
        [self _attachSurface];
    }
    if (!_attachedSurface) {
        if (_recvFrameCount % 60 == 1) {
            AVSLogWrite(@"[avsd-IPC-RX] #%d no attached surface", _recvFrameCount);
        }
        return;
    }

    // Lock for reading (cross-process safe)
    IOSurfaceLock(_attachedSurface, kIOSurfaceLockReadOnly, NULL);

    // Wrap IOSurface in CVPixelBuffer (zero-copy)
    CVPixelBufferRef pixBuf = NULL;
    CVReturn ret = CVPixelBufferCreateWithIOSurface(
        kCFAllocatorDefault,
        _attachedSurface,
        NULL,
        &pixBuf
    );

    IOSurfaceUnlock(_attachedSurface, kIOSurfaceLockReadOnly, NULL);

    if (ret != kCVReturnSuccess || !pixBuf) {
        if (_recvFrameCount % 60 == 1) {
            AVSLogWrite(@"[avsd-IPC-RX] #%d CVPixelBuffer create failed ret=%d", _recvFrameCount, ret);
        }
        return;
    }

    // Wrap in CMSampleBuffer with current timestamp
    CMVideoFormatDescriptionRef fmtDesc = NULL;
    CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixBuf, &fmtDesc);
    if (!fmtDesc) {
        CVPixelBufferRelease(pixBuf);
        return;
    }

    CMSampleTimingInfo timing = {
        .duration              = CMTimeMake(1, 30),
        .presentationTimeStamp = CMClockGetTime(CMClockGetHostTimeClock()),
        .decodeTimeStamp       = kCMTimeInvalid,
    };

    CMSampleBufferRef sampleBuf = NULL;
    CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, pixBuf,
                                       YES, NULL, NULL, fmtDesc,
                                       &timing, &sampleBuf);
    CFRelease(fmtDesc);
    CVPixelBufferRelease(pixBuf);

    if (sampleBuf && self.onFrameReceived) {
        if (_recvFrameCount % 60 == 1) {
            AVSLogWrite(@"[avsd-IPC-RX] #%d delivering frame to coordinator", _recvFrameCount);
        }
        self.onFrameReceived(sampleBuf);
    } else if (_recvFrameCount % 60 == 1) {
        AVSLogWrite(@"[avsd-IPC-RX] #%d sampleBuf=%p onFrameReceived=%p", _recvFrameCount, sampleBuf, self.onFrameReceived);
    }
    if (sampleBuf) CFRelease(sampleBuf);
}

- (void)_handleStateChange {
    NSData *data = [NSData dataWithContentsOfFile:kAVSIPCStatePath];
    if (!data) return;

    NSDictionary *state = [NSPropertyListSerialization
                           propertyListWithData:data
                           options:NSPropertyListImmutable
                           format:NULL error:nil];
    if (!state) return;

    BOOL enabled = [state[@"enabled"] boolValue];
    AVSLogWrite(@"[avsd-IPC] Received state enabled=%d", enabled);

    if (self.onStateChanged) {
        self.onStateChanged(enabled);
    }
}

- (BOOL)_surfaceIDChanged {
    NSData *data = [NSData dataWithContentsOfFile:kAVSIPCSurfacePath];
    if (!data) return NO;

    NSDictionary *meta = [NSPropertyListSerialization
                          propertyListWithData:data
                          options:NSPropertyListImmutable
                          format:NULL error:nil];
    if (!meta) return NO;

    uint32_t sid = [meta[@"sid"] unsignedIntValue];
    return sid != _lastSurfaceID;
}

- (void)_attachSurface {
    NSData *data = [NSData dataWithContentsOfFile:kAVSIPCSurfacePath];
    if (!data) return;

    NSDictionary *meta = [NSPropertyListSerialization
                          propertyListWithData:data
                          options:NSPropertyListImmutable
                          format:NULL error:nil];
    if (!meta) return;

    uint32_t sid = [meta[@"sid"] unsignedIntValue];
    if (sid == 0) return;

    // Release old surface
    if (_attachedSurface) {
        CFRelease(_attachedSurface);
        _attachedSurface = NULL;
    }

    _attachedSurface = IOSurfaceLookup(sid);
    _lastSurfaceID = sid;

    if (_attachedSurface) {
        AVSLogWrite(@"[avsd-IPC] Attached to IOSurface ID=%u (%zux%zu)",
              sid,
              IOSurfaceGetWidth(_attachedSurface),
              IOSurfaceGetHeight(_attachedSurface));
    } else {
        AVSLogWrite(@"[avsd-IPC] Failed to lookup IOSurface ID=%u", sid);
    }
}

- (void)dealloc {
    [self stopListening];
}

@end
