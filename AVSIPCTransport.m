// AVSIPCTransport.m
// LordVCAM — IPC bridge between SpringBoard and mediaserverd
// Zero-copy frame sharing via IOSurface + Darwin notify_set_state
// No file I/O — works on roothide where /var/tmp/ is per-process virtualized

#import "AVSIPCTransport.h"
#import <notify.h>

// -----------------------------------------------------------------------
// AVSIPCSender — SpringBoard side
// Uses notify_set_state to pass IOSurface ID through kernel (no files)
// -----------------------------------------------------------------------
@implementation AVSIPCSender {
    uint32_t _lastSurfaceID;
    int _frameToken;
    int _stateToken;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _frameToken = NOTIFY_TOKEN_INVALID;
        _stateToken = NOTIFY_TOKEN_INVALID;
        // Register tokens for setting state
        notify_register_check(kAVSIPCFrameNotification, &_frameToken);
        notify_register_check(kAVSIPCStateNotification, &_stateToken);
    }
    return self;
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

    if (sid != _lastSurfaceID) {
        _lastSurfaceID = sid;
        AVSLogWrite(@"[avsd-IPC] Published surface ID=%u %zux%zu fmt=%u",
              sid,
              CVPixelBufferGetWidth(pixelBuffer),
              CVPixelBufferGetHeight(pixelBuffer),
              (uint32_t)CVPixelBufferGetPixelFormatType(pixelBuffer));
    }

    // Pass surface ID via kernel notification state (no file I/O)
    if (_frameToken != NOTIFY_TOKEN_INVALID) {
        notify_set_state(_frameToken, (uint64_t)sid);
    }

    // Signal mediaserverd
    notify_post(kAVSIPCFrameNotification);
}

- (void)publishEnabled:(BOOL)enabled {
    if (_stateToken != NOTIFY_TOKEN_INVALID) {
        notify_set_state(_stateToken, enabled ? 1 : 0);
    }
    notify_post(kAVSIPCStateNotification);
    AVSLogWrite(@"[avsd-IPC] Published state enabled=%d", enabled);
}

- (void)teardown {
    [self publishEnabled:NO];
    if (_frameToken != NOTIFY_TOKEN_INVALID) {
        notify_cancel(_frameToken);
        _frameToken = NOTIFY_TOKEN_INVALID;
    }
    if (_stateToken != NOTIFY_TOKEN_INVALID) {
        notify_cancel(_stateToken);
        _stateToken = NOTIFY_TOKEN_INVALID;
    }
    _lastSurfaceID = 0;
}

- (void)dealloc {
    [self teardown];
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
                             ^(int token) { [ws _handleNewFrame:token]; });

    notify_register_dispatch(kAVSIPCStateNotification,
                             &_stateToken,
                             _ipcQueue,
                             ^(int token) { [ws _handleStateChange:token]; });

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
- (void)_handleNewFrame:(int)token {
    _recvFrameCount++;

    // Get surface ID from kernel notification state (no file I/O)
    uint64_t state = 0;
    notify_get_state(token, &state);
    uint32_t sid = (uint32_t)state;

    if (sid == 0) {
        if (_recvFrameCount % 60 == 1) {
            AVSLogWrite(@"[avsd-IPC-RX] #%d surface ID is 0", _recvFrameCount);
        }
        return;
    }

    // Attach to new surface if ID changed
    if (sid != _lastSurfaceID || !_attachedSurface) {
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
            return;
        }
    }

    if (!_attachedSurface) return;

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

- (void)_handleStateChange:(int)token {
    uint64_t state = 0;
    notify_get_state(token, &state);
    BOOL enabled = (state != 0);

    AVSLogWrite(@"[avsd-IPC] Received state enabled=%d", enabled);

    if (self.onStateChanged) {
        self.onStateChanged(enabled);
    }
}

- (void)dealloc {
    [self stopListening];
}

@end
