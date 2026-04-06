// AVSDataProvider.h
// LordVCAM - Reconstructed via reverse engineering of AVServicesd.dylib
// Protocol + concrete implementations for video/photo data sources

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <Photos/Photos.h>
#import <PhotosUI/PhotosUI.h>

// -----------------------------------------------------------------------
// Protocol: AVSDataProvider
// Implemented by: AVSRemoteDataProvider, AVSLocalDataProvider
// -----------------------------------------------------------------------
@protocol AVSDataProvider <NSObject>

- (void)_avs_dat_popBuf;          // pop/consume next buffer
- (void)_avs_dat_pause;
- (void)_avs_dat_resume;
- (void)_avs_dat_stop;
- (void)_avs_dat_cleanup;
- (void)_avs_dat_dismissPkr;     // dismiss photo picker
- (void)_avs_dat_loadImg:(NSURL *)url;
- (void)_avs_dat_loadVid:(NSURL *)url;
- (void)_avs_dat_cleanExcl:(id)exclusion;
- (BOOL)isVideo;
- (BOOL)isReady;

@end

// -----------------------------------------------------------------------
// AVSRemoteDataProvider — receives frames from PC over WebSocket/USB
// Protocol: wss://<ip>:8765
// Frame message format: { "type": "frame", "data": <base64> }
// Audio message format: { "type": "audio", "rate": <int> }
// -----------------------------------------------------------------------
@interface AVSRemoteDataProvider : NSObject <AVSDataProvider>

@property (nonatomic, assign) BOOL isVideo;
@property (nonatomic, assign) BOOL isReady;
@property (nonatomic, assign) BOOL isRunning;
@property (nonatomic, assign) BOOL isPaused;

// Latest frame (CMSampleBufferRef wrapped)
@property (nonatomic, assign) CMSampleBufferRef latestFrame;
@property (nonatomic, assign) CMSampleBufferRef lastBlendedBuffer;

// Transition support
@property (nonatomic, strong) id<AVSDataProvider> transitionFromSource;
@property (nonatomic, strong) id<AVSDataProvider> transitionTarget;

@end

// -----------------------------------------------------------------------
// AVSLocalDataProvider — plays back local video/photo from gallery
// Uses AVAssetReader + AVAssetReaderTrackOutput for frame extraction
// -----------------------------------------------------------------------
@interface AVSLocalDataProvider : NSObject
    <AVSDataProvider, PHPickerViewControllerDelegate>

@property (nonatomic, strong) AVAsset            *videoAsset;
@property (nonatomic, strong) AVAssetReader      *assetReader;
@property (nonatomic, strong) AVAssetReaderTrackOutput *trackOutput;
@property (nonatomic, strong) AVAssetReaderAudioMixOutput *audioOutput;

@property (nonatomic, assign) BOOL isVideo;
@property (nonatomic, assign) BOOL isReady;
@property (nonatomic, assign) BOOL isRunning;
@property (nonatomic, assign) BOOL isPaused;

@property (nonatomic, copy)   NSString *currentMediaPath;
@property (nonatomic, strong) UIWindow *pickerWindow;

// Loop / advance
@property (nonatomic, assign) int  _framesAdvanced;
@property (nonatomic, strong) id   _nextLoopReader;  // next AVAssetReader for seamless loop

// Callback invoked with each decoded frame (set by AVSFrameCoordinator.setDataSource:)
@property (nonatomic, copy) void(^_avs_cfg_onDec)(CMSampleBufferRef frame);

- (void)setAssetReader:(AVAssetReader *)reader;
- (void)setAudioOutput:(AVAssetReaderAudioMixOutput *)output;

@end
