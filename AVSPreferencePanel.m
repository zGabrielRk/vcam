// AVSPreferencePanel.m
// LordVCAM — Reconstruído via engenharia reversa de AVServicesd.dylib
// Painel de controle flutuante injetado no SpringBoard

#import "AVSPreferencePanel.h"
#import "AVSFrameCoordinator.h"
#import "AVSDataProvider.h"
#import <PhotosUI/PhotosUI.h>

@interface AVSPreferencePanel () <PHPickerViewControllerDelegate>
@end

static CGFloat const kPanelWidth   = 300.0f;
static CGFloat const kPanelHeight  = 480.0f;
static CGFloat const kButtonSize   = 52.0f;
static CGFloat const kPad          = 16.0f;

@implementation AVSPreferencePanel {
    NSTimer              *_idleTimer;
    CGFloat               _keyboardOffset;
    BOOL                  _isRegisterMode;
    CGPoint               _dragStartPoint;
    AVSLocalDataProvider *_activeLocalProvider;
    UIWindow             *_pickerHostWindow;
}
@synthesize _panelDragStart = _panelDragStart;

- (instancetype)init {
    self = [super init];
    if (self) {
        _menuMode = 0;
        _panelVisible = NO;
        _panelCentered = YES;
        _isDragging = NO;
        _isRegisterMode = NO;
        _keyboardOffset = 0;
    }
    return self;
}

// -----------------------------------------------------------------------
// Setup: cria todas as janelas
// -----------------------------------------------------------------------
- (void)setupWindows {
    [self _createFloatingButton];
    [self _createPanelWindow];
    [self _createPreviewWindow];
    [self _createEyedropperWindow];
}

// -----------------------------------------------------------------------
// Botão flutuante
// -----------------------------------------------------------------------
- (void)_createFloatingButton {
    UIWindowScene *scene = (UIWindowScene *)[UIApplication.sharedApplication.connectedScenes
                                             anyObject];

    self.buttonWindow = [[UIWindow alloc] initWithWindowScene:scene];
    self.buttonWindow.windowLevel = UIWindowLevelAlert + 100;
    self.buttonWindow.backgroundColor = [UIColor clearColor];
    self.buttonWindow.frame = CGRectMake(20, 120, kButtonSize, kButtonSize);
    self.buttonWindow.hidden = NO;

    self.floatingButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.floatingButton.frame = self.buttonWindow.bounds;
    self.floatingButton.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.7];
    self.floatingButton.layer.cornerRadius = kButtonSize / 2;
    self.floatingButton.layer.borderWidth = 1.5;
    self.floatingButton.layer.borderColor = [UIColor systemBlueColor].CGColor;
    [self.floatingButton setImage:[UIImage systemImageNamed:@"camera.fill"]
                         forState:UIControlStateNormal];
    self.floatingButton.tintColor = [UIColor whiteColor];
    [self.floatingButton addTarget:self action:@selector(_togglePanel)
               forControlEvents:UIControlEventTouchUpInside];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
                                   initWithTarget:self action:@selector(_handleButtonDrag:)];
    [self.floatingButton addGestureRecognizer:pan];

    [self.buttonWindow addSubview:self.floatingButton];
}

- (void)_handleButtonDrag:(UIPanGestureRecognizer *)gr {
    CGPoint translation = [gr translationInView:self.buttonWindow];
    if (gr.state == UIGestureRecognizerStateBegan) {
        _dragStartPoint = self.buttonWindow.frame.origin;
    }
    CGRect frame = self.buttonWindow.frame;
    frame.origin.x = _dragStartPoint.x + translation.x;
    frame.origin.y = _dragStartPoint.y + translation.y;

    CGRect screen = UIScreen.mainScreen.bounds;
    frame.origin.x = MAX(0, MIN(frame.origin.x, screen.size.width - kButtonSize));
    frame.origin.y = MAX(20, MIN(frame.origin.y, screen.size.height - kButtonSize - 20));
    self.buttonWindow.frame = frame;
}

// -----------------------------------------------------------------------
// Painel principal
// -----------------------------------------------------------------------
- (void)_createPanelWindow {
    UIWindowScene *scene = (UIWindowScene *)[UIApplication.sharedApplication.connectedScenes
                                             anyObject];
    self.panelWindow = [[UIWindow alloc] initWithWindowScene:scene];
    self.panelWindow.windowLevel = UIWindowLevelAlert + 50;
    self.panelWindow.hidden = YES;

    CGRect screen = UIScreen.mainScreen.bounds;
    self.panelWindow.frame = CGRectMake(
        (screen.size.width - kPanelWidth) / 2,
        (screen.size.height - kPanelHeight) / 2,
        kPanelWidth, kPanelHeight
    );
    self.panelWindow.layer.cornerRadius = 16;
    self.panelWindow.clipsToBounds = YES;

    UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark];
    self.panelBlur = [[UIVisualEffectView alloc] initWithEffect:blur];
    self.panelBlur.frame = self.panelWindow.bounds;
    [self.panelWindow addSubview:self.panelBlur];

    [self _buildPanelContent];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
                                   initWithTarget:self action:@selector(_handlePanelDrag:)];
    [self.panelWindow addGestureRecognizer:pan];
}

// -----------------------------------------------------------------------
// Layout do painel — gallery-only
// -----------------------------------------------------------------------
- (void)_buildPanelContent {
    UIView *c = self.panelBlur.contentView;
    CGFloat y = 0;
    CGFloat w = kPanelWidth;

    // ---- Header ----
    y = 12;
    UILabel *title = [UILabel new];
    title.frame = CGRectMake(kPad, y, w - kPad * 2, 24);
    title.text = @"LordVCAM";
    title.textColor = [UIColor whiteColor];
    title.font = [UIFont boldSystemFontOfSize:17];
    [c addSubview:title];

    y = 42;
    UIView *div = [[UIView alloc] initWithFrame:CGRectMake(0, y, w, 0.5)];
    div.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.2];
    [c addSubview:div];

    // ---- Source buttons: Gallery / Disable ----
    y = 54;
    CGFloat btnW = (w - kPad * 2 - 10) / 2;

    self.galleryButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.galleryButton.frame = CGRectMake(kPad, y, btnW, 38);
    [self.galleryButton setImage:[UIImage systemImageNamed:@"photo.on.rectangle"] forState:UIControlStateNormal];
    [self.galleryButton setTitle:@" Gallery" forState:UIControlStateNormal];
    self.galleryButton.tintColor = [UIColor whiteColor];
    self.galleryButton.backgroundColor = [[UIColor systemBlueColor] colorWithAlphaComponent:0.6];
    self.galleryButton.layer.cornerRadius = 10;
    self.galleryButton.tag = 0;
    [self.galleryButton addTarget:self action:@selector(_modeTapped:)
                 forControlEvents:UIControlEventTouchUpInside];
    [c addSubview:self.galleryButton];

    UIButton *disableBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    disableBtn.frame = CGRectMake(kPad + btnW + 10, y, btnW, 38);
    [disableBtn setImage:[UIImage systemImageNamed:@"nosign"] forState:UIControlStateNormal];
    [disableBtn setTitle:@" Disable" forState:UIControlStateNormal];
    disableBtn.tintColor = [UIColor whiteColor];
    disableBtn.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.15];
    disableBtn.layer.cornerRadius = 10;
    disableBtn.tag = 1;
    [disableBtn addTarget:self action:@selector(_modeTapped:)
         forControlEvents:UIControlEventTouchUpInside];
    [c addSubview:disableBtn];

    // ---- Status ----
    y = 102;
    self.statsLabel = [UILabel new];
    self.statsLabel.frame = CGRectMake(kPad, y, w - kPad * 2, 36);
    self.statsLabel.text = @"Select a photo or video from Gallery.";
    self.statsLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.6];
    self.statsLabel.font = [UIFont systemFontOfSize:12];
    self.statsLabel.numberOfLines = 2;
    [c addSubview:self.statsLabel];

    // ---- Divider ----
    y = 142;
    UIView *div2 = [[UIView alloc] initWithFrame:CGRectMake(kPad, y, w - kPad * 2, 0.5)];
    div2.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.1];
    [c addSubview:div2];

    // ---- Camera controls: 2 rows x 3 ----
    y = 154;
    [self _buildCameraControls:c atY:y];

    // ---- Pan arrows: cross layout ----
    y = 256;
    [self _buildPanControls:c atY:y];

    // ---- Divider ----
    y = 362;
    UIView *div3 = [[UIView alloc] initWithFrame:CGRectMake(kPad, y, w - kPad * 2, 0.5)];
    div3.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.1];
    [c addSubview:div3];

    // ---- Switches ----
    y = 374;
    [self _buildReplacementSwitch:c atY:y];
    y = 416;
    [self _buildAudioSwitch:c atY:y];

    // ---- Spinner ----
    self.spinner = [[UIActivityIndicatorView alloc]
                    initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.center = CGPointMake(w / 2, kPanelHeight / 2);
    self.spinner.color = [UIColor whiteColor];
    self.spinner.hidden = YES;
    [c addSubview:self.spinner];
}

// -----------------------------------------------------------------------
// Camera control grid: zoom, rotate, flip, reset
// -----------------------------------------------------------------------
- (void)_buildCameraControls:(UIView *)content atY:(CGFloat)baseY {
    CGFloat btnSz = 44;
    CGFloat gap   = 6;
    // Center the 3-button row
    CGFloat totalW = btnSz * 3 + gap * 2;
    CGFloat startX = (kPanelWidth - totalW) / 2;

    struct { NSString *icon; SEL action; } btns[] = {
        { @"plus.magnifyingglass",   @selector(zoomIn)   },
        { @"minus.magnifyingglass",  @selector(zoomOut)  },
        { @"rotate.right",          @selector(rotRight)  },
        { @"rotate.left",           @selector(rotLeft)   },
        { @"arrow.left.and.right.righttriangle.left.righttriangle.right", @selector(flipH) },
        { @"arrow.counterclockwise", @selector(_resetAll) },
    };

    for (int i = 0; i < 6; i++) {
        int col = i % 3;
        int row = i / 3;
        CGFloat x = startX + col * (btnSz + gap);
        CGFloat y = baseY + row * (btnSz + gap);

        UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
        btn.frame = CGRectMake(x, y, btnSz, btnSz);
        [btn setImage:[UIImage systemImageNamed:btns[i].icon] forState:UIControlStateNormal];
        btn.tintColor = [UIColor whiteColor];
        btn.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.12];
        btn.layer.cornerRadius = 10;
        [btn addTarget:self action:btns[i].action forControlEvents:UIControlEventTouchUpInside];
        [content addSubview:btn];
    }
}

// -----------------------------------------------------------------------
// Pan arrows in cross pattern
// -----------------------------------------------------------------------
- (void)_buildPanControls:(UIView *)content atY:(CGFloat)baseY {
    CGFloat btnSz = 42;
    CGFloat gap   = 4;
    CGFloat cx    = kPanelWidth / 2; // center X

    // Up
    self.panUpBtn = [self _makeControlBtn:@"arrow.up" action:@selector(panUp)
        frame:CGRectMake(cx - btnSz/2, baseY, btnSz, btnSz) parent:content];
    // Left
    self.panLeftBtn = [self _makeControlBtn:@"arrow.left" action:@selector(panLeft)
        frame:CGRectMake(cx - btnSz - btnSz/2 - gap, baseY + btnSz + gap, btnSz, btnSz) parent:content];
    // Right
    self.panRightBtn = [self _makeControlBtn:@"arrow.right" action:@selector(panRight)
        frame:CGRectMake(cx + btnSz/2 + gap, baseY + btnSz + gap, btnSz, btnSz) parent:content];
    // Down
    self.panDownBtn = [self _makeControlBtn:@"arrow.down" action:@selector(panDown)
        frame:CGRectMake(cx - btnSz/2, baseY + (btnSz + gap) * 2, btnSz, btnSz) parent:content];
}

- (UIButton *)_makeControlBtn:(NSString *)icon action:(SEL)action
                         frame:(CGRect)frame parent:(UIView *)parent {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    btn.frame = frame;
    [btn setImage:[UIImage systemImageNamed:icon] forState:UIControlStateNormal];
    btn.tintColor = [UIColor whiteColor];
    btn.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.12];
    btn.layer.cornerRadius = 10;
    [btn addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [parent addSubview:btn];
    return btn;
}

// -----------------------------------------------------------------------
// Switches
// -----------------------------------------------------------------------
- (void)_buildReplacementSwitch:(UIView *)content atY:(CGFloat)y {
    UILabel *lbl = [UILabel new];
    lbl.frame = CGRectMake(kPad, y + 5, 180, 20);
    lbl.text = @"Enable Replacement";
    lbl.textColor = [UIColor whiteColor];
    lbl.font = [UIFont systemFontOfSize:14];
    [content addSubview:lbl];

    self._avs_cfg_rplSw = [[UISwitch alloc] init];
    self._avs_cfg_rplSw.frame = CGRectMake(kPanelWidth - 67, y, 51, 31);
    self._avs_cfg_rplSw.onTintColor = [UIColor systemBlueColor];
    [self._avs_cfg_rplSw addTarget:self action:@selector(_avs_cfg_rplChg:)
                  forControlEvents:UIControlEventValueChanged];
    [content addSubview:self._avs_cfg_rplSw];
}

- (void)_buildAudioSwitch:(UIView *)content atY:(CGFloat)y {
    UILabel *lbl = [UILabel new];
    lbl.frame = CGRectMake(kPad, y + 5, 180, 20);
    lbl.text = @"Audio Source";
    lbl.textColor = [UIColor whiteColor];
    lbl.font = [UIFont systemFontOfSize:14];
    [content addSubview:lbl];

    self._avs_cfg_aRplSw = [[UISwitch alloc] init];
    self._avs_cfg_aRplSw.frame = CGRectMake(kPanelWidth - 67, y, 51, 31);
    self._avs_cfg_aRplSw.onTintColor = [UIColor systemGreenColor];
    [self._avs_cfg_aRplSw addTarget:self action:@selector(_avs_cfg_aRplChg:)
                   forControlEvents:UIControlEventValueChanged];
    [content addSubview:self._avs_cfg_aRplSw];
}

// -----------------------------------------------------------------------
// Ações
// -----------------------------------------------------------------------
- (void)_modeTapped:(UIButton *)btn {
    int mode = (int)btn.tag;
    self.activeBgButton = btn;

    if (mode == 0) {
        [self _openGalleryPicker];
    } else if (mode == 1) {
        [self.coordinator enableReplacement:NO];
        self._avs_cfg_rplSw.on = NO;
        self.statsLabel.text = @"Disabled. Select Gallery to pick media.";
    }
}

- (void)_openGalleryPicker {
    AVSLogWrite(@"[avsd-UI] Opening gallery picker, coordinator=%p", self.coordinator);
    AVSLocalDataProvider *provider = [[AVSLocalDataProvider alloc] init];
    _activeLocalProvider = provider;

    PHPickerConfiguration *config = [[PHPickerConfiguration alloc]
                                     initWithPhotoLibrary:[PHPhotoLibrary sharedPhotoLibrary]];
    config.filter = [PHPickerFilter anyFilterMatchingSubfilters:@[
        PHPickerFilter.videosFilter,
        PHPickerFilter.imagesFilter,
    ]];
    config.selectionLimit = 1;

    PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:config];
    picker.delegate = self;

    UIWindowScene *scene = (UIWindowScene *)[UIApplication.sharedApplication.connectedScenes anyObject];
    _pickerHostWindow = [[UIWindow alloc] initWithWindowScene:scene];
    _pickerHostWindow.windowLevel = UIWindowLevelAlert + 150;
    UIViewController *hostVC = [[UIViewController alloc] init];
    _pickerHostWindow.rootViewController = hostVC;
    _pickerHostWindow.hidden = NO;

    [hostVC presentViewController:picker animated:YES completion:nil];
}

// -----------------------------------------------------------------------
// PHPickerViewControllerDelegate
// -----------------------------------------------------------------------
- (void)picker:(PHPickerViewController *)picker
didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:^{
        self->_pickerHostWindow.hidden = YES;
        self->_pickerHostWindow = nil;
    }];

    PHPickerResult *result = results.firstObject;
    if (!result) {
        _activeLocalProvider = nil;
        return;
    }

    NSItemProvider *itemProvider = result.itemProvider;

    if ([itemProvider hasItemConformingToTypeIdentifier:@"public.movie"]) {
        self.statsLabel.text = @"Loading video...";
        [itemProvider loadFileRepresentationForTypeIdentifier:@"public.movie"
                                           completionHandler:^(NSURL *url, NSError *err) {
            if (!url) return;
            NSURL *tmpURL = [[NSURL fileURLWithPath:NSTemporaryDirectory()]
                             URLByAppendingPathComponent:url.lastPathComponent];
            [[NSFileManager defaultManager] copyItemAtURL:url toURL:tmpURL error:nil];
            dispatch_async(dispatch_get_main_queue(), ^{
                AVSLogWrite(@"[avsd-UI] Loading video: %@", tmpURL.path);
                [self.coordinator setDataSource:self->_activeLocalProvider];
                [self->_activeLocalProvider _avs_dat_loadVid:tmpURL];
                [self.coordinator enableReplacement:YES];
                self._avs_cfg_rplSw.on = YES;
                self.statsLabel.text = @"Video loaded. Replacement active.";
                AVSLogWrite(@"[avsd-UI] Video setup complete. replOn=%d feedOn=%d",
                      self.coordinator._avs_cfg_replOn, self.coordinator._avs_cfg_feedOn);
            });
        }];
    } else if ([itemProvider hasItemConformingToTypeIdentifier:@"public.image"]) {
        self.statsLabel.text = @"Loading image...";
        [itemProvider loadFileRepresentationForTypeIdentifier:@"public.image"
                                           completionHandler:^(NSURL *url, NSError *err) {
            if (!url) return;
            dispatch_async(dispatch_get_main_queue(), ^{
                AVSLogWrite(@"[avsd-UI] Loading image: %@", url.path);
                [self.coordinator setDataSource:self->_activeLocalProvider];
                [self->_activeLocalProvider _avs_dat_loadImg:url];
                [self.coordinator enableReplacement:YES];
                self._avs_cfg_rplSw.on = YES;
                self.statsLabel.text = @"Image loaded. Replacement active.";
                AVSLogWrite(@"[avsd-UI] Image setup complete. replOn=%d feedOn=%d",
                      self.coordinator._avs_cfg_replOn, self.coordinator._avs_cfg_feedOn);
            });
        }];
    }
}

- (void)zoomIn    { [self.coordinator.renderPipeline zoomIn];        }
- (void)zoomOut   { [self.coordinator.renderPipeline zoomOut];       }
- (void)rotRight  { [self.coordinator.renderPipeline rotateRight];   }
- (void)rotLeft   { [self.coordinator.renderPipeline rotateLeft];    }
- (void)flipH     { [self.coordinator.renderPipeline flipHorizontal];}
- (void)panUp     { [self.coordinator.renderPipeline panUp];         }
- (void)panDown   { [self.coordinator.renderPipeline panDown];       }
- (void)panLeft   { [self.coordinator.renderPipeline panLeft];       }
- (void)panRight  { [self.coordinator.renderPipeline panRight];      }
- (void)gammaUp   { [self.coordinator.renderPipeline gammaUp];       }
- (void)_resetAll { [self.coordinator.renderPipeline _avs_fp_resetFlags]; }

- (void)_avs_cfg_rplChg:(UISwitch *)sw {
    [self.coordinator enableReplacement:sw.isOn];
    self._avs_cfg_replOn = sw.isOn;
}

- (void)_avs_cfg_aRplChg:(UISwitch *)sw {
    self.coordinator._avs_cfg_audioOn = sw.isOn;
}

// -----------------------------------------------------------------------
// Toggle painel
// -----------------------------------------------------------------------
- (void)_togglePanel {
    if (_panelVisible) {
        [self _avs_ov_hidePnl];
    } else {
        [self _avs_ov_showPnl];
    }
}

- (void)_avs_ov_showPnl {
    _panelVisible = YES;
    self.panelWindow.hidden = NO;
    self.panelWindow.alpha = 0;
    [UIView animateWithDuration:0.25 animations:^{
        self.panelWindow.alpha = 1.0;
    }];
}

- (void)_avs_ov_hidePnl {
    _panelVisible = NO;
    [UIView animateWithDuration:0.2 animations:^{
        self.panelWindow.alpha = 0;
    } completion:^(BOOL finished) {
        self.panelWindow.hidden = YES;
    }];
}

- (void)_avs_ov_updIcon {
    NSString *iconName = self._avs_cfg_rplSw.isOn ? @"camera.fill" : @"nosign";
    [self.floatingButton setImage:[UIImage systemImageNamed:iconName]
                         forState:UIControlStateNormal];
}

- (void)dismiss {
    [self _avs_ov_hidePnl];
}

- (void)repositionPanel {
    CGRect screen = UIScreen.mainScreen.bounds;
    CGRect frame = self.panelWindow.frame;
    frame.origin.x = (screen.size.width - kPanelWidth) / 2;
    frame.origin.y = (screen.size.height - kPanelHeight) / 2;
    self.panelWindow.frame = frame;
    _panelCentered = YES;
}

- (void)forceHideOnLock {
    if (self._isScreenLocked) {
        [self _avs_ov_hidePnl];
    }
}

- (void)cancelIdleTimer {
    [_idleTimer invalidate];
    _idleTimer = nil;
}

- (void)switchToFilters {
    _menuMode = 1;
}

- (void)_loopBtnTapped {
    AVSLogWrite(@"[avsd] Loop toggle");
}

// -----------------------------------------------------------------------
// Drag painel
// -----------------------------------------------------------------------
- (void)_handlePanelDrag:(UIPanGestureRecognizer *)gr {
    CGPoint translation = [gr translationInView:self.panelWindow];
    if (gr.state == UIGestureRecognizerStateBegan) {
        _panelDragStart = self.panelWindow.frame.origin;
        _isDragging = YES;
    }
    CGRect frame = self.panelWindow.frame;
    frame.origin.x = _panelDragStart.x + translation.x;
    frame.origin.y = _panelDragStart.y + translation.y;
    self.panelWindow.frame = frame;

    if (gr.state == UIGestureRecognizerStateEnded) {
        _isDragging = NO;
        _panelCentered = NO;
    }
}

// -----------------------------------------------------------------------
// Preview de vídeo
// -----------------------------------------------------------------------
- (void)_createPreviewWindow {
    UIWindowScene *scene = (UIWindowScene *)[UIApplication.sharedApplication.connectedScenes
                                             anyObject];
    self.previewWindow = [[UIWindow alloc] initWithWindowScene:scene];
    self.previewWindow.windowLevel = UIWindowLevelStatusBar - 1;
    self.previewWindow.hidden = YES;

    self.previewImageView = [[UIImageView alloc] initWithFrame:self.previewWindow.bounds];
    self.previewImageView.contentMode = UIViewContentModeScaleAspectFit;
    self.previewImageView.backgroundColor = [UIColor blackColor];
    [self.previewWindow addSubview:self.previewImageView];
}

// -----------------------------------------------------------------------
// Eyedropper
// -----------------------------------------------------------------------
- (void)_createEyedropperWindow {
    UIWindowScene *scene = (UIWindowScene *)[UIApplication.sharedApplication.connectedScenes
                                             anyObject];
    self.eyedropperWindow = [[UIWindow alloc] initWithWindowScene:scene];
    self.eyedropperWindow.windowLevel = UIWindowLevelAlert + 200;
    self.eyedropperWindow.hidden = YES;

    self.eyedropperIndicator = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 20, 20)];
    self.eyedropperIndicator.backgroundColor = [UIColor whiteColor];
    self.eyedropperIndicator.layer.cornerRadius = 10;
    self.eyedropperIndicator.layer.borderWidth = 2;
    self.eyedropperIndicator.layer.borderColor = [UIColor blackColor].CGColor;
    [self.eyedropperWindow addSubview:self.eyedropperIndicator];
}

// -----------------------------------------------------------------------
// Banners
// -----------------------------------------------------------------------
- (void)_avs_pres_buildNote:(id)config title:(NSString *)title body:(NSString *)body {
    UIWindowScene *scene = (UIWindowScene *)[UIApplication.sharedApplication.connectedScenes
                                             anyObject];
    self._avs_cfg_bannerWin = [[UIWindow alloc] initWithWindowScene:scene];
    self._avs_cfg_bannerWin.windowLevel = UIWindowLevelAlert + 300;
    self._avs_cfg_bannerWin.backgroundColor = [UIColor clearColor];

    CGRect screen = UIScreen.mainScreen.bounds;
    self._avs_cfg_bannerWin.frame = CGRectMake(16, 50, screen.size.width - 32, 60);
    self._avs_cfg_bannerWin.layer.cornerRadius = 12;
    self._avs_cfg_bannerWin.clipsToBounds = YES;

    UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterialDark];
    UIVisualEffectView *blurView = [[UIVisualEffectView alloc] initWithEffect:blur];
    blurView.frame = self._avs_cfg_bannerWin.bounds;
    [self._avs_cfg_bannerWin addSubview:blurView];

    UILabel *titleLbl = [UILabel new];
    titleLbl.frame = CGRectMake(12, 8, blurView.bounds.size.width - 24, 20);
    titleLbl.text = title;
    titleLbl.font = [UIFont boldSystemFontOfSize:13];
    titleLbl.textColor = [UIColor whiteColor];
    [blurView.contentView addSubview:titleLbl];

    UILabel *bodyLbl = [UILabel new];
    bodyLbl.frame = CGRectMake(12, 26, blurView.bounds.size.width - 24, 26);
    bodyLbl.text = body;
    bodyLbl.font = [UIFont systemFontOfSize:12];
    bodyLbl.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.8];
    bodyLbl.numberOfLines = 2;
    [blurView.contentView addSubview:bodyLbl];

    self._avs_cfg_bannerWin.hidden = NO;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        [UIView animateWithDuration:0.3 animations:^{
            self._avs_cfg_bannerWin.alpha = 0;
        } completion:^(BOOL done) {
            self._avs_cfg_bannerWin.hidden = YES;
            self._avs_cfg_bannerWin = nil;
        }];
    });
}

- (void)_avs_pres_showMnt:(NSString *)message estimatedEnd:(NSString *)eta {
    AVSLogWrite(@"[avsd] Maintenance: %@ ETA: %@", message, eta);
}

- (void)_avs_pp_updConn {
    // No-op for gallery-only mode
}

// -----------------------------------------------------------------------
// Delegates
// -----------------------------------------------------------------------
- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gr
shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return YES;
}

@end
