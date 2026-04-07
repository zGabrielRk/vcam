// AVSDataProvider.m
// LordVCAM — Reconstruído via engenharia reversa de AVServicesd.dylib
// AVSLocalDataProvider: reprodução de vídeo/foto da galeria com AVAssetReader

#import "AVSDataProvider.h"
#import <AVFoundation/AVFoundation.h>
#import <PhotosUI/PhotosUI.h>
#import <ImageIO/ImageIO.h>

// -----------------------------------------------------------------------
// AVSLocalDataProvider
// -----------------------------------------------------------------------
@implementation AVSLocalDataProvider {
    dispatch_queue_t  _readQueue;
    dispatch_source_t _readTimer;
    NSLock           *_readerLock;
    int               _currentFPS;
    BOOL              _loop;
    CVPixelBufferRef  _staticPixelBuffer;              // retained; used for still-image loop
    CMVideoFormatDescriptionRef _staticFormatDesc;     // cached; avoids 30x/sec alloc
}
@synthesize isVideo = _isVideo;
@synthesize isReady = _isReady;
@synthesize _framesAdvanced;

- (instancetype)init {
    self = [super init];
    if (self) {
        _readQueue  = dispatch_queue_create("com.avsd.assetreader", DISPATCH_QUEUE_SERIAL);
        _readerLock = [[NSLock alloc] init];
        _isVideo  = NO;
        _isReady  = NO;
        _isRunning = NO;
        _isPaused = NO;
        _currentFPS = 30;
        _loop = YES;
        _framesAdvanced = 0;
    }
    return self;
}

// -----------------------------------------------------------------------
// Carrega uma URL de vídeo (public.movie) ou imagem (public.image)
// -----------------------------------------------------------------------
- (void)_avs_dat_loadVid:(NSURL *)url {
    [self _avs_dat_stop];
    self.isVideo = YES;

    AVAsset *asset = [AVAsset assetWithURL:url];
    self.videoAsset = asset;
    self.currentMediaPath = url.path;

    // Configura AVAssetReader para vídeo
    NSError *error = nil;
    self.assetReader = [AVAssetReader assetReaderWithAsset:asset error:&error];
    if (error) {
        NSLog(@"[avsd] AVAssetReader error: %@", error);
        return;
    }

    // Track de vídeo
    AVAssetTrack *videoTrack = [[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
    if (!videoTrack) return;

    // FPS
    _currentFPS = (int)round(videoTrack.nominalFrameRate);
    if (_currentFPS <= 0) _currentFPS = 30;

    NSDictionary *videoSettings = @{
        (__bridge NSString *)kCVPixelBufferPixelFormatTypeKey:
            @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        (__bridge NSString *)kCVPixelBufferMetalCompatibilityKey: @YES,
        (__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };

    self.trackOutput = [AVAssetReaderTrackOutput
                        assetReaderTrackOutputWithTrack:videoTrack
                                        outputSettings:videoSettings];
    self.trackOutput.alwaysCopiesSampleData = NO;
    [self.assetReader addOutput:self.trackOutput];

    // Track de áudio (opcional)
    AVAssetTrack *audioTrack = [[asset tracksWithMediaType:AVMediaTypeAudio] firstObject];
    if (audioTrack) {
        NSDictionary *audioSettings = @{
            AVFormatIDKey: @(kAudioFormatLinearPCM),
            AVSampleRateKey: @44100.0,
            AVNumberOfChannelsKey: @1,
            AVLinearPCMBitDepthKey: @32,
            AVLinearPCMIsFloatKey: @YES,
        };
        self.audioOutput = [AVAssetReaderAudioMixOutput
                            assetReaderAudioMixOutputWithAudioTracks:@[audioTrack]
                                                       audioSettings:audioSettings];
        [self.assetReader addOutput:self.audioOutput];
    }

    if (![self.assetReader startReading]) {
        NSLog(@"[avsd] AVAssetReader startReading failed: %@", self.assetReader.error);
        return;
    }

    self.isReady = YES;
    [self _avs_dat_resume];
}

- (void)_avs_dat_loadImg:(NSURL *)url {
    [self _avs_dat_stop];
    self.isVideo = NO;

    // Use ImageIO (CGImageSource) instead of UIImage — works in all processes
    // including mediaserverd where UIKit is not available
    CGImageSourceRef imgSrc = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
    if (!imgSrc) {
        NSLog(@"[avsd] CGImageSourceCreateWithURL failed for %@", url);
        return;
    }
    CGImageRef cgImg = CGImageSourceCreateImageAtIndex(imgSrc, 0, NULL);
    CFRelease(imgSrc);
    if (!cgImg) {
        NSLog(@"[avsd] CGImageSourceCreateImageAtIndex failed");
        return;
    }

    self.currentMediaPath = url.path;

    size_t w = CGImageGetWidth(cgImg);
    size_t h = CGImageGetHeight(cgImg);
    if (w == 0 || h == 0) { CGImageRelease(cgImg); return; }

    NSDictionary *attrs = @{
        (__bridge NSString *)kCVPixelBufferCGImageCompatibilityKey:         @YES,
        (__bridge NSString *)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES,
        (__bridge NSString *)kCVPixelBufferMetalCompatibilityKey:           @YES,
        (__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey:          @{},
    };
    CVPixelBufferRef pixelBuf = NULL;
    CVReturn ret = CVPixelBufferCreate(kCFAllocatorDefault, w, h,
                                       kCVPixelFormatType_32BGRA,
                                       (__bridge CFDictionaryRef)attrs,
                                       &pixelBuf);
    if (ret != kCVReturnSuccess || !pixelBuf) { CGImageRelease(cgImg); return; }

    CVPixelBufferLockBaseAddress(pixelBuf, 0);
    void   *base        = CVPixelBufferGetBaseAddress(pixelBuf);
    size_t  bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuf);
    CGColorSpaceRef cs  = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx    = CGBitmapContextCreate(base, w, h, 8, bytesPerRow, cs,
                                                kCGImageAlphaNoneSkipFirst |
                                                kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(cs);
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), cgImg);
    CGContextRelease(ctx);
    CVPixelBufferUnlockBaseAddress(pixelBuf, 0);
    CGImageRelease(cgImg);

    if (_staticPixelBuffer) {
        CVPixelBufferRelease(_staticPixelBuffer);
    }
    _staticPixelBuffer = pixelBuf;  // retained by CVPixelBufferCreate

    // Pre-create format description once — reused every tick in _avs_dat_popBuf
    if (_staticFormatDesc) { CFRelease(_staticFormatDesc); _staticFormatDesc = NULL; }
    CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault,
                                                 _staticPixelBuffer,
                                                 &_staticFormatDesc);

    self.isReady = YES;
    [self _avs_dat_resume];  // start 30 fps delivery timer
}

// -----------------------------------------------------------------------
// Controle de reprodução
// -----------------------------------------------------------------------
- (void)_avs_dat_resume {
    if (_isRunning) return;
    _isRunning = YES;
    _isPaused = NO;

    NSTimeInterval frameInterval = 1.0 / _currentFPS;

    __weak typeof(self) weakSelf = self;
    _readTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _readQueue);
    dispatch_source_set_timer(_readTimer,
                              dispatch_time(DISPATCH_TIME_NOW, 0),
                              (uint64_t)(frameInterval * NSEC_PER_SEC),
                              NSEC_PER_SEC / 100);
    dispatch_source_set_event_handler(_readTimer, ^{
        [weakSelf _avs_dat_popBuf];
    });
    dispatch_resume(_readTimer);
}

- (void)_avs_dat_pause {
    _isPaused = YES;
    if (_readTimer) {
        dispatch_suspend(_readTimer);
    }
}

- (void)_avs_dat_stop {
    _isRunning = NO;
    if (_readTimer) {
        // dispatch_source_cancel on a suspended source causes EXC_BAD_INSTRUCTION.
        // Resume before cancel if the source was paused.
        if (_isPaused) dispatch_resume(_readTimer);
        dispatch_source_cancel(_readTimer);
        _readTimer = nil;
    }
    _isPaused = NO;
    [_readerLock lock];
    if (self.assetReader) {
        [self.assetReader cancelReading];
        self.assetReader = nil;
        self.trackOutput = nil;
        self.audioOutput = nil;
    }
    [_readerLock unlock];
    if (_staticFormatDesc) {
        CFRelease(_staticFormatDesc);
        _staticFormatDesc = NULL;
    }
    if (_staticPixelBuffer) {
        CVPixelBufferRelease(_staticPixelBuffer);
        _staticPixelBuffer = NULL;
    }
    self.isReady = NO;
}

- (void)_avs_dat_cleanup {
    [self _avs_dat_stop];
    self.videoAsset = nil;
    self.currentMediaPath = nil;
}

// -----------------------------------------------------------------------
// Pop do próximo frame do buffer
// -----------------------------------------------------------------------
- (void)_avs_dat_popBuf {
    if (!_isRunning || _isPaused || !self.isReady) return;

    // Static image: wrap the cached CVPixelBuffer in a CMSampleBuffer each tick
    if (!_isVideo) {
        if (!_staticPixelBuffer || !_staticFormatDesc) return;

        CMSampleTimingInfo timing = {
            .duration              = CMTimeMake(1, _currentFPS),
            .presentationTimeStamp = CMClockGetTime(CMClockGetHostTimeClock()),
            .decodeTimeStamp       = kCMTimeInvalid,
        };
        CMSampleBufferRef sampleBuf = NULL;
        CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, _staticPixelBuffer,
                                           YES, NULL, NULL,
                                           _staticFormatDesc, &timing, &sampleBuf);
        if (!sampleBuf) return;
        if (self._avs_cfg_onDec) {
            self._avs_cfg_onDec(sampleBuf);
        }
        CFRelease(sampleBuf);
        return;
    }

    if (!self.trackOutput) return;

    [_readerLock lock];
    CMSampleBufferRef sampleBuf = [self.trackOutput copyNextSampleBuffer];
    [_readerLock unlock];

    if (!sampleBuf) {
        // Fim do vídeo
        if (_loop) {
            // Prepara próximo leitor para seamless loop
            [self _prepareNextLoopReader];
        } else {
            [self _avs_dat_stop];
        }
        return;
    }

    _framesAdvanced++;
    // Entrega frame ao coordinator via callback registrado em setDataSource:
    if (self._avs_cfg_onDec) {
        self._avs_cfg_onDec(sampleBuf);
    }
    CFRelease(sampleBuf);
}

- (void)_prepareNextLoopReader {
    // Recria AVAssetReader para loop seamless
    if (!self.videoAsset) return;

    NSError *error = nil;
    AVAssetReader *nextReader = [AVAssetReader assetReaderWithAsset:self.videoAsset
                                                              error:&error];
    if (!nextReader) return;

    AVAssetTrack *vt = [[self.videoAsset tracksWithMediaType:AVMediaTypeVideo] firstObject];
    NSDictionary *vs = @{
        (__bridge NSString *)kCVPixelBufferPixelFormatTypeKey:
            @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        (__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
    AVAssetReaderTrackOutput *output = [AVAssetReaderTrackOutput
                                       assetReaderTrackOutputWithTrack:vt
                                                       outputSettings:vs];
    output.alwaysCopiesSampleData = NO;
    [nextReader addOutput:output];

    if ([nextReader startReading]) {
        [_readerLock lock];
        self.assetReader = nextReader;
        self.trackOutput = output;
        [_readerLock unlock];
    }
}

// -----------------------------------------------------------------------
// PHPickerViewController presentation & delegate
// Picker is presented and handled by AVSPreferencePanel.
// These stubs satisfy the AVSDataProvider protocol.
// -----------------------------------------------------------------------
- (void)_avs_dat_picker    { }
- (void)_avs_dat_dismissPkr { }

// PHPickerViewControllerDelegate (required)
- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
}

- (void)_avs_dat_cleanExcl:(id)exclusion {
    // Limpa arquivos temporários exceto o especificado
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *tmpDir = NSTemporaryDirectory();
    NSArray *files = [fm contentsOfDirectoryAtPath:tmpDir error:nil];
    for (NSString *file in files) {
        if (![file isEqualToString:exclusion]) {
            [fm removeItemAtPath:[tmpDir stringByAppendingPathComponent:file] error:nil];
        }
    }
}

- (BOOL)isReady { return _isReady; }
- (BOOL)isVideo { return _isVideo; }
- (void)setIsReady:(BOOL)r { _isReady = r; }
- (void)setIsVideo:(BOOL)v { _isVideo = v; }

@end

// -----------------------------------------------------------------------
// AVSRemoteDataProvider (stub — lógica principal no coordinator)
// -----------------------------------------------------------------------
@implementation AVSRemoteDataProvider

- (instancetype)init {
    self = [super init];
    if (self) {
        _isVideo  = YES;
        _isReady  = NO;
        _isRunning = NO;
        _isPaused = NO;
    }
    return self;
}

- (void)_avs_dat_popBuf      { /* frames chegam via WebSocket → coordinator */ }
- (void)_avs_dat_pause       { _isPaused = YES; }
- (void)_avs_dat_resume      { _isPaused = NO; _isRunning = YES; }
- (void)_avs_dat_stop        { _isRunning = NO; _isReady = NO; }
- (void)_avs_dat_cleanup     { [self _avs_dat_stop]; }
- (void)_avs_dat_picker      { }
- (void)_avs_dat_dismissPkr  { }
- (void)_avs_dat_loadImg:(NSURL *)url { }
- (void)_avs_dat_loadVid:(NSURL *)url { }
- (void)_avs_dat_cleanExcl:(id)exclusion { }
- (BOOL)isVideo { return _isVideo; }
- (BOOL)isReady { return _isReady; }

@end
