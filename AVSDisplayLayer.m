// AVSDisplayLayer.m
// LordVCAM — Reconstruído via engenharia reversa de AVServicesd.dylib
// Camada de exibição ao vivo para preview no painel de controle

#import "AVSDisplayLayer.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>

@implementation AVSDisplayLayer {
    AVSampleBufferDisplayLayer *_displayLayer;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _isReady = NO;
        [self _setup];
    }
    return self;
}

- (void)_setup {
    _displayLayer = [[AVSampleBufferDisplayLayer alloc] init];
    _displayLayer.videoGravity = AVLayerVideoGravityResizeAspect;
    _displayLayer.backgroundColor = [UIColor blackColor].CGColor;
    // _restampBuffer: sobrescreve o PTS com CACurrentMediaTime(), então
    // o timebase de controle é desnecessário — a camada renderiza imediatamente.
    _isReady = YES;
}

// -----------------------------------------------------------------------
// Expõe a CALayer para ser inserida em uma UIView
// -----------------------------------------------------------------------
- (CALayer *)layer {
    return _displayLayer;
}

// -----------------------------------------------------------------------
// Enfileira frame para exibição no preview
// -----------------------------------------------------------------------
- (void)_avs_dl_updFrame:(CMSampleBufferRef)frame {
    if (!frame || !_isReady) return;

    // AVSampleBufferDisplayLayer precisa de apresentação no main thread
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_displayLayer.status == AVQueuedSampleBufferRenderingStatusFailed) {
            [self->_displayLayer flush];
        }

        // Reestampa o PTS com o tempo atual para renderização imediata
        CMSampleBufferRef resampled = [self _restampBuffer:frame];
        if (resampled) {
            [self->_displayLayer enqueueSampleBuffer:resampled];
            CFRelease(resampled);
        } else {
            [self->_displayLayer enqueueSampleBuffer:frame];
        }
    });
}

// Recria o CMSampleBuffer com PTS = agora (evita descartes por timestamp antigo)
- (CMSampleBufferRef)_restampBuffer:(CMSampleBufferRef)original {
    CMItemCount count = 0;
    CMSampleBufferGetSampleTimingInfoArray(original, 0, NULL, &count);
    if (count == 0) return NULL;

    // Usa stack para o caso comum (1 sample por buffer de vídeo)
    // evita malloc no main thread a 30fps
    CMSampleTimingInfo stackBuf[4];
    CMSampleTimingInfo *timings = (count <= 4) ? stackBuf
                                               : malloc(sizeof(CMSampleTimingInfo) * count);
    if (!timings) return NULL;

    OSStatus st = CMSampleBufferGetSampleTimingInfoArray(original, count, timings, &count);
    if (st != noErr) {
        if (timings != stackBuf) free(timings);
        return NULL;
    }

    CMTime now = CMTimeMakeWithSeconds(CACurrentMediaTime(), 90000);
    for (CMItemCount i = 0; i < count; i++) {
        timings[i].presentationTimeStamp = now;
        timings[i].decodeTimeStamp       = kCMTimeInvalid;
    }

    CMSampleBufferRef copy = NULL;
    st = CMSampleBufferCreateCopyWithNewTiming(
        kCFAllocatorDefault,
        original,
        count,
        timings,
        &copy
    );
    if (timings != stackBuf) free(timings);

    return (st == noErr) ? copy : NULL;
}

@end
