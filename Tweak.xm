// Tweak.xm — LordVCAM Gallery Virtual Camera
// Minimal, single-file implementation matching original architecture.
// SpringBoard: floating button + gallery picker + IOSurface publish
// mediaserverd: listen for gallery notification + BWNodeOutput hook
// UIKit apps: hook AVCaptureVideoDataOutput delegates

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Photos/Photos.h>
#import <PhotosUI/PhotosUI.h>
// IOSurface — forward declarations (header not in Theos SDK)
typedef struct __IOSurface *IOSurfaceRef;
extern uint32_t IOSurfaceGetID(IOSurfaceRef surface);
extern IOSurfaceRef IOSurfaceLookup(uint32_t csid);
extern size_t IOSurfaceGetWidth(IOSurfaceRef surface);
extern size_t IOSurfaceGetHeight(IOSurfaceRef surface);
extern kern_return_t IOSurfaceLock(IOSurfaceRef surface, uint32_t options, uint32_t *seed);
extern kern_return_t IOSurfaceUnlock(IOSurfaceRef surface, uint32_t options, uint32_t *seed);
extern IOSurfaceRef CVPixelBufferGetIOSurface(CVPixelBufferRef pixelBuffer);
extern CVReturn CVPixelBufferCreateWithIOSurface(CFAllocatorRef allocator, IOSurfaceRef surface, CFDictionaryRef pixelBufferAttributes, CVPixelBufferRef *pixelBufferOut);
#define kIOSurfaceLockReadOnly 0x00000001
#import <QuartzCore/QuartzCore.h>
#import <substrate.h>
#import <notify.h>
#import <dlfcn.h>
#import <objc/runtime.h>

// ============================================================
// Constants
// ============================================================
#define kGalleryNotify   "com.avsd.prerender"
#define kStateNotify     "com.avsd.gallery.state"
#define kCacheDir        @"/var/tmp/com.apple.avfcache"

// ============================================================
// Shared globals (per-process)
// ============================================================
static BOOL gActive = NO;
static CVPixelBufferRef gReplacementPB = NULL;

// ============================================================
// MEDIASERVERD — frame replacement in camera daemon
// ============================================================

static IOSurfaceRef gAttachedSurface = NULL;
static uint32_t gLastSID = 0;

static void mediaserverd_onFrame(int token) {
    uint64_t state = 0;
    notify_get_state(token, &state);
    uint32_t sid = (uint32_t)state;
    if (sid == 0) return;

    if (sid != gLastSID || !gAttachedSurface) {
        if (gAttachedSurface) CFRelease(gAttachedSurface);
        gAttachedSurface = IOSurfaceLookup(sid);
        gLastSID = sid;
        if (gAttachedSurface) {
            NSLog(@"[vcam] attached surface %u (%zux%zu)", sid,
                  IOSurfaceGetWidth(gAttachedSurface),
                  IOSurfaceGetHeight(gAttachedSurface));
        } else {
            NSLog(@"[vcam] IOSurfaceLookup(%u) FAILED", sid);
            return;
        }
    }
    if (!gAttachedSurface) return;

    CVPixelBufferRef newPB = NULL;
    CVPixelBufferCreateWithIOSurface(NULL, gAttachedSurface, NULL, &newPB);
    if (newPB) {
        CVPixelBufferRef old = gReplacementPB;
        gReplacementPB = newPB;
        if (old) CVPixelBufferRelease(old);
    }
}

static void mediaserverd_onState(int token) {
    uint64_t state = 0;
    notify_get_state(token, &state);
    gActive = (state != 0);
    NSLog(@"[vcam] active=%d", gActive);
    if (!gActive) {
        CVPixelBufferRef old = gReplacementPB;
        gReplacementPB = NULL;
        if (old) CVPixelBufferRelease(old);
    }
}

// --- BWNodeOutput hook (Logos %group for mediaserverd only) ---
%group MediaServerd

%hook BWNodeOutput
- (CMSampleBufferRef)copyNextSampleBuffer {
    CMSampleBufferRef orig = %orig;
    if (!gActive || !gReplacementPB) return orig;

    CMVideoFormatDescriptionRef fmt = NULL;
    CMVideoFormatDescriptionCreateForImageBuffer(NULL, gReplacementPB, &fmt);
    if (!fmt) return orig;

    CMSampleTimingInfo timing = {
        .duration              = CMTimeMake(1, 30),
        .presentationTimeStamp = CMClockGetTime(CMClockGetHostTimeClock()),
        .decodeTimeStamp       = kCMTimeInvalid
    };
    CMSampleBufferRef replacement = NULL;
    CMSampleBufferCreateForImageBuffer(NULL, gReplacementPB, YES,
                                       NULL, NULL, fmt, &timing, &replacement);
    CFRelease(fmt);

    if (replacement) {
        if (orig) CFRelease(orig);
        return replacement;
    }
    return orig;
}
%end

%end // group MediaServerd

// ============================================================
// UIKIT APPS — hook AVCaptureVideoDataOutput delegates
// ============================================================
typedef void (*SBDelegateFunc)(id, SEL, id, CMSampleBufferRef, id);
static SBDelegateFunc orig_captureDelegate = NULL;

static void hook_captureDelegate(id self, SEL _cmd, id output,
                                  CMSampleBufferRef sampleBuffer, id connection) {
    if (gActive && gReplacementPB) {
        CMVideoFormatDescriptionRef fmt = NULL;
        CMVideoFormatDescriptionCreateForImageBuffer(NULL, gReplacementPB, &fmt);
        if (fmt) {
            CMSampleTimingInfo timing = {
                .duration = CMTimeMake(1, 30),
                .presentationTimeStamp = CMClockGetTime(CMClockGetHostTimeClock()),
                .decodeTimeStamp = kCMTimeInvalid
            };
            CMSampleBufferRef rep = NULL;
            CMSampleBufferCreateForImageBuffer(NULL, gReplacementPB, YES,
                                               NULL, NULL, fmt, &timing, &rep);
            CFRelease(fmt);
            if (rep) {
                orig_captureDelegate(self, _cmd, output, rep, connection);
                CFRelease(rep);
                return;
            }
        }
    }
    orig_captureDelegate(self, _cmd, output, sampleBuffer, connection);
}

// ============================================================
// SPRINGBOARD — Floating button + Gallery picker
// ============================================================

@interface VCamPanel : NSObject <PHPickerViewControllerDelegate>
@property (nonatomic, strong) UIWindow *btnWindow;
@property (nonatomic, strong) UIButton *floatBtn;
@property (nonatomic, strong) UIWindow *pickerWindow;
@property (nonatomic) CVPixelBufferRef sharedPB;
@property (nonatomic) int galleryToken;
@property (nonatomic) int stateToken;
@property (nonatomic, strong) dispatch_source_t videoTimer;
@property (nonatomic, strong) AVAssetReader *videoReader;
@property (nonatomic, strong) AVAssetReaderTrackOutput *videoOutput;
@property (nonatomic, strong) AVAsset *videoAsset;
@property (nonatomic) BOOL videoPlaying;
- (void)setup;
@end

static VCamPanel *gPanel = nil;

@implementation VCamPanel

- (void)dealloc {
    if (self.sharedPB) CVPixelBufferRelease(self.sharedPB);
}

- (void)setup {
    _galleryToken = NOTIFY_TOKEN_INVALID;
    _stateToken = NOTIFY_TOKEN_INVALID;
    notify_register_check(kGalleryNotify, &_galleryToken);
    notify_register_check(kStateNotify, &_stateToken);

    UIWindowScene *scene = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]]) { scene = (UIWindowScene *)s; break; }
    }
    if (!scene) {
        NSLog(@"[vcam] ERROR: no UIWindowScene");
        return;
    }

    // Floating button
    _btnWindow = [[UIWindow alloc] initWithWindowScene:scene];
    _btnWindow.windowLevel = UIWindowLevelAlert + 100;
    _btnWindow.frame = CGRectMake(20, 120, 52, 52);
    _btnWindow.backgroundColor = [UIColor clearColor];
    _btnWindow.clipsToBounds = NO;
    _btnWindow.rootViewController = [[UIViewController alloc] init];
    _btnWindow.rootViewController.view.backgroundColor = [UIColor clearColor];

    _floatBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    _floatBtn.frame = CGRectMake(0, 0, 52, 52);
    _floatBtn.backgroundColor = [[UIColor systemBlueColor] colorWithAlphaComponent:0.85];
    _floatBtn.layer.cornerRadius = 26;
    _floatBtn.clipsToBounds = YES;
    _floatBtn.layer.shadowColor = [UIColor blackColor].CGColor;
    _floatBtn.layer.shadowOpacity = 0.4;
    _floatBtn.layer.shadowOffset = CGSizeMake(0, 2);
    [_floatBtn setImage:[UIImage systemImageNamed:@"camera.fill"
                               withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:22]]
               forState:UIControlStateNormal];
    _floatBtn.tintColor = [UIColor whiteColor];
    [_floatBtn addTarget:self action:@selector(_btnTap) forControlEvents:UIControlEventTouchUpInside];

    UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc]
                                                initWithTarget:self action:@selector(_btnLongPress:)];
    longPress.minimumPressDuration = 1.0;
    [_floatBtn addGestureRecognizer:longPress];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
                                   initWithTarget:self action:@selector(_btnDrag:)];
    [_floatBtn addGestureRecognizer:pan];

    [_btnWindow.rootViewController.view addSubview:_floatBtn];
    _btnWindow.hidden = NO;

    NSLog(@"[vcam] SpringBoard UI ready (tap=gallery, long-press=disable)");
}

// Tap → open gallery
- (void)_btnTap {
    PHPickerConfiguration *cfg = [[PHPickerConfiguration alloc]
                                  initWithPhotoLibrary:[PHPhotoLibrary sharedPhotoLibrary]];
    cfg.filter = [PHPickerFilter anyFilterMatchingSubfilters:@[
        PHPickerFilter.imagesFilter,
        PHPickerFilter.videosFilter
    ]];
    cfg.selectionLimit = 1;

    PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:cfg];
    picker.delegate = self;

    UIWindowScene *scene = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]]) { scene = (UIWindowScene *)s; break; }
    }

    _pickerWindow = [[UIWindow alloc] initWithWindowScene:scene];
    _pickerWindow.windowLevel = UIWindowLevelAlert + 200;
    _pickerWindow.rootViewController = [[UIViewController alloc] init];
    _pickerWindow.hidden = NO;

    [_pickerWindow.rootViewController presentViewController:picker animated:YES completion:nil];
}

// Long press → disable replacement
- (void)_btnLongPress:(UILongPressGestureRecognizer *)gr {
    if (gr.state != UIGestureRecognizerStateBegan) return;
    [self _stopVideo];

    gActive = NO;
    if (_stateToken != NOTIFY_TOKEN_INVALID)
        notify_set_state(_stateToken, 0);
    notify_post(kStateNotify);

    _floatBtn.backgroundColor = [[UIColor systemBlueColor] colorWithAlphaComponent:0.85];
    NSLog(@"[vcam] Disabled");

    // Haptic feedback
    UIImpactFeedbackGenerator *fb = [[UIImpactFeedbackGenerator alloc]
                                     initWithStyle:UIImpactFeedbackStyleHeavy];
    [fb impactOccurred];
}

// Drag button
- (void)_btnDrag:(UIPanGestureRecognizer *)pan {
    CGPoint t = [pan translationInView:_btnWindow];
    CGRect f = _btnWindow.frame;
    f.origin.x += t.x;
    f.origin.y += t.y;
    _btnWindow.frame = f;
    [pan setTranslation:CGPointZero inView:_btnWindow];
}

// ---- PHPickerViewControllerDelegate ----
- (void)picker:(PHPickerViewController *)picker
  didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:^{
        self->_pickerWindow.hidden = YES;
        self->_pickerWindow = nil;
    }];

    PHPickerResult *result = results.firstObject;
    if (!result) return;

    NSItemProvider *ip = result.itemProvider;

    // IMAGE
    if ([ip hasItemConformingToTypeIdentifier:@"public.image"]) {
        [ip loadObjectOfClass:[UIImage class] completionHandler:^(id<NSItemProviderReading> obj, NSError *err) {
            UIImage *img = (UIImage *)obj;
            if (!img) { NSLog(@"[vcam] image load failed: %@", err); return; }
            dispatch_async(dispatch_get_main_queue(), ^{
                [self _stopVideo];
                [self _publishImage:img];
            });
        }];
        return;
    }

    // VIDEO
    if ([ip hasItemConformingToTypeIdentifier:@"public.movie"]) {
        [ip loadFileRepresentationForTypeIdentifier:@"public.movie"
                                  completionHandler:^(NSURL *url, NSError *err) {
            if (!url) { NSLog(@"[vcam] video load failed: %@", err); return; }
            // Copy to shared dir (provider URL expires after this block)
            NSString *dst = [kCacheDir stringByAppendingPathComponent:@"current.mov"];
            NSFileManager *fm = [NSFileManager defaultManager];
            [fm createDirectoryAtPath:kCacheDir withIntermediateDirectories:YES attributes:nil error:nil];
            [fm removeItemAtPath:dst error:nil];
            NSError *cpErr = nil;
            if (![fm copyItemAtPath:url.path toPath:dst error:&cpErr]) {
                NSLog(@"[vcam] video copy failed: %@", cpErr);
                return;
            }
            NSLog(@"[vcam] video copied to %@", dst);
            dispatch_async(dispatch_get_main_queue(), ^{
                [self _startVideo:[NSURL fileURLWithPath:dst]];
            });
        }];
        return;
    }
}

// ---- Publish a single image ----
- (void)_publishImage:(UIImage *)image {
    CGFloat scale = image.scale;
    size_t w = (size_t)(image.size.width * scale);
    size_t h = (size_t)(image.size.height * scale);
    if (w == 0 || h == 0) return;

    // Cap resolution
    CGFloat maxDim = 1920.0;
    if (w > maxDim || h > maxDim) {
        CGFloat ratio = MIN(maxDim / w, maxDim / h);
        w = (size_t)(w * ratio);
        h = (size_t)(h * ratio);
    }

    NSDictionary *attrs = @{
        (__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
    CVPixelBufferRef pb = NULL;
    if (CVPixelBufferCreate(NULL, w, h, kCVPixelFormatType_32BGRA,
                            (__bridge CFDictionaryRef)attrs, &pb) != kCVReturnSuccess) return;

    CVPixelBufferLockBaseAddress(pb, 0);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(
        CVPixelBufferGetBaseAddress(pb), w, h, 8,
        CVPixelBufferGetBytesPerRow(pb), cs,
        kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(cs);
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), image.CGImage);
    CGContextRelease(ctx);
    CVPixelBufferUnlockBaseAddress(pb, 0);

    [self _publishPixelBuffer:pb];
    NSLog(@"[vcam] image published (%zux%zu)", w, h);
}

// ---- Video playback (30fps loop) ----
- (void)_startVideo:(NSURL *)url {
    [self _stopVideo];

    _videoAsset = [AVAsset assetWithURL:url];
    if (![self _prepareVideoReader]) return;

    _videoPlaying = YES;
    __weak typeof(self) ws = self;
    dispatch_queue_t q = dispatch_queue_create("com.vcam.video", DISPATCH_QUEUE_SERIAL);
    _videoTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    dispatch_source_set_timer(_videoTimer, DISPATCH_TIME_NOW,
                              (uint64_t)(NSEC_PER_SEC / 30), NSEC_PER_SEC / 100);
    dispatch_source_set_event_handler(_videoTimer, ^{
        [ws _videoTick];
    });
    dispatch_resume(_videoTimer);

    // Activate replacement
    gActive = YES;
    if (_stateToken != NOTIFY_TOKEN_INVALID) notify_set_state(_stateToken, 1);
    notify_post(kStateNotify);
    _floatBtn.backgroundColor = [[UIColor systemGreenColor] colorWithAlphaComponent:0.85];

    NSLog(@"[vcam] video started");
}

- (BOOL)_prepareVideoReader {
    NSError *err = nil;
    _videoReader = [AVAssetReader assetReaderWithAsset:_videoAsset error:&err];
    if (!_videoReader) { NSLog(@"[vcam] reader error: %@", err); return NO; }

    AVAssetTrack *track = [[_videoAsset tracksWithMediaType:AVMediaTypeVideo] firstObject];
    if (!track) { NSLog(@"[vcam] no video track"); return NO; }

    NSDictionary *settings = @{
        (__bridge NSString *)kCVPixelBufferPixelFormatTypeKey:
            @(kCVPixelFormatType_32BGRA),
        (__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
    _videoOutput = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track
                                                             outputSettings:settings];
    _videoOutput.alwaysCopiesSampleData = NO;
    [_videoReader addOutput:_videoOutput];

    if (![_videoReader startReading]) {
        NSLog(@"[vcam] reader start failed: %@", _videoReader.error);
        return NO;
    }
    return YES;
}

- (void)_videoTick {
    if (!_videoPlaying || !_videoOutput) return;

    CMSampleBufferRef sample = [_videoOutput copyNextSampleBuffer];
    if (!sample) {
        // Loop: restart reader
        _videoReader = nil;
        _videoOutput = nil;
        if (![self _prepareVideoReader]) {
            [self _stopVideo];
            return;
        }
        sample = [_videoOutput copyNextSampleBuffer];
        if (!sample) return;
    }

    CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sample);
    if (pb) {
        [self _publishPixelBuffer:pb];
    }
    CFRelease(sample);
}

- (void)_stopVideo {
    _videoPlaying = NO;
    if (_videoTimer) {
        dispatch_source_cancel(_videoTimer);
        _videoTimer = nil;
    }
    if (_videoReader) {
        [_videoReader cancelReading];
        _videoReader = nil;
        _videoOutput = nil;
    }
}

// ---- Shared: publish pixel buffer via IOSurface + notify ----
- (void)_publishPixelBuffer:(CVPixelBufferRef)pb {
    IOSurfaceRef surface = CVPixelBufferGetIOSurface(pb);
    if (!surface) {
        NSLog(@"[vcam] ERROR: not IOSurface-backed");
        return;
    }

    // Keep the pixel buffer alive (IOSurface stays valid while CVPixelBuffer is retained)
    CVPixelBufferRef old = self.sharedPB;
    CVPixelBufferRetain(pb);
    self.sharedPB = pb;
    if (old) CVPixelBufferRelease(old);

    uint32_t sid = IOSurfaceGetID(surface);

    // Share IOSurface ID via kernel notification
    if (_galleryToken != NOTIFY_TOKEN_INVALID)
        notify_set_state(_galleryToken, (uint64_t)sid);
    notify_post(kGalleryNotify);

    // Activate
    gActive = YES;
    if (_stateToken != NOTIFY_TOKEN_INVALID)
        notify_set_state(_stateToken, 1);
    notify_post(kStateNotify);

    _floatBtn.backgroundColor = [[UIColor systemGreenColor] colorWithAlphaComponent:0.85];
}

@end

// ============================================================
// CONSTRUCTOR
// ============================================================
%ctor {
    @autoreleasepool {
        NSString *proc = [NSProcessInfo processInfo].processName;
        NSLog(@"[vcam] ===== LOADED in %@ =====", proc);

        // Write probe file for debugging
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm createDirectoryAtPath:kCacheDir withIntermediateDirectories:YES
                       attributes:nil error:nil];
        NSString *probe = [NSString stringWithFormat:@"%@/probe_%@.txt", kCacheDir, proc];
        [[NSString stringWithFormat:@"loaded %@", [NSDate date]]
            writeToFile:probe atomically:YES encoding:NSUTF8StringEncoding error:nil];

        if ([proc isEqualToString:@"mediaserverd"]) {
            NSLog(@"[vcam] Setting up mediaserverd");

            // Load private frameworks
            dlopen("/System/Library/PrivateFrameworks/CMCaptureCore.framework/CMCaptureCore", RTLD_LAZY);
            dlopen("/System/Library/PrivateFrameworks/CMCapture.framework/CMCapture", RTLD_LAZY);

            // Init hooks
            %init(MediaServerd);

            // Listen for gallery frames + state
            dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0);
            int frameToken = NOTIFY_TOKEN_INVALID;
            int stateToken = NOTIFY_TOKEN_INVALID;
            notify_register_dispatch(kGalleryNotify, &frameToken, q,
                                     ^(int t) { mediaserverd_onFrame(t); });
            notify_register_dispatch(kStateNotify, &stateToken, q,
                                     ^(int t) { mediaserverd_onState(t); });

            NSLog(@"[vcam] mediaserverd ready — listening for gallery");

        } else if ([proc isEqualToString:@"SpringBoard"]) {
            // Wait for SpringBoard UI to finish launching
            [[NSNotificationCenter defaultCenter]
                addObserverForName:UIApplicationDidFinishLaunchingNotification
                            object:nil queue:[NSOperationQueue mainQueue]
                        usingBlock:^(NSNotification *n) {
                NSLog(@"[vcam] SpringBoard launched — creating UI");
                gPanel = [[VCamPanel alloc] init];
                [gPanel setup];
            }];

            // Fallback timer
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC),
                           dispatch_get_main_queue(), ^{
                if (!gPanel) {
                    NSLog(@"[vcam] Fallback: creating UI");
                    gPanel = [[VCamPanel alloc] init];
                    [gPanel setup];
                }
            });

        } else {
            // UIKit app — hook camera delegates
            NSLog(@"[vcam] UIKit app — hooking camera delegates");

            // Listen for gallery frames + state (same as mediaserverd)
            dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0);
            int frameToken = NOTIFY_TOKEN_INVALID;
            int stateToken = NOTIFY_TOKEN_INVALID;
            notify_register_dispatch(kGalleryNotify, &frameToken, q,
                                     ^(int t) { mediaserverd_onFrame(t); });
            notify_register_dispatch(kStateNotify, &stateToken, q,
                                     ^(int t) { mediaserverd_onState(t); });

            // Hook all classes implementing AVCaptureVideoDataOutputSampleBufferDelegate
            unsigned int count = 0;
            Class *classes = objc_copyClassList(&count);
            Protocol *proto = @protocol(AVCaptureVideoDataOutputSampleBufferDelegate);
            SEL sel = @selector(captureOutput:didOutputSampleBuffer:fromConnection:);

            for (unsigned int i = 0; i < count; i++) {
                if (class_conformsToProtocol(classes[i], proto)) {
                    Method m = class_getInstanceMethod(classes[i], sel);
                    if (m) {
                        IMP origImp = method_getImplementation(m);
                        if (origImp != (IMP)hook_captureDelegate) {
                            orig_captureDelegate = (SBDelegateFunc)origImp;
                            method_setImplementation(m, (IMP)hook_captureDelegate);
                            NSLog(@"[vcam] hooked delegate: %s", class_getName(classes[i]));
                        }
                    }
                }
            }
            free(classes);
        }
    }
}
