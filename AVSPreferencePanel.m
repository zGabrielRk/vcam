// AVSPreferencePanel.m
// LordVCAM — Reconstruído via engenharia reversa de AVServicesd.dylib
// Painel de controle flutuante injetado no SpringBoard

#import "AVSPreferencePanel.h"
#import "AVSFrameCoordinator.h"
#import "AVSDataProvider.h"
#import <PhotosUI/PhotosUI.h>

@interface AVSPreferencePanel () <PHPickerViewControllerDelegate>
@end

static CGFloat const kPanelWidth   = 320.0f;
static CGFloat const kPanelHeight  = 460.0f;
static CGFloat const kButtonSize   = 52.0f;
static NSString *const kDefaultIP  = @"192.168.0.1";
static NSString *const kTelegramURL = @"https://t.me/LordVCAM";
static NSString *const kTelegramSupport = @"https://t.me/lordvcam777";

@implementation AVSPreferencePanel {
    NSTimer              *_idleTimer;
    CGFloat               _keyboardOffset;
    BOOL                  _isRegisterMode;
    CGPoint               _dragStartPoint;
    AVSLocalDataProvider *_activeLocalProvider;  // retained while gallery source is active
    UIWindow             *_pickerHostWindow;     // dismissed after picker completes
}

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
    [self _createMenuWindow];
    [self _createPreviewWindow];
    [self _createEyedropperWindow];
}

// -----------------------------------------------------------------------
// Botão flutuante (shortcut)
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
    [self.floatingButton addTarget:self action:@selector(_togglePanel)
               forControlEvents:UIControlEventTouchUpInside];

    // Drag para reposicionar
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

    // Limita à tela
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

    // Blur de fundo
    UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark];
    self.panelBlur = [[UIVisualEffectView alloc] initWithEffect:blur];
    self.panelBlur.frame = self.panelWindow.bounds;
    [self.panelWindow addSubview:self.panelBlur];

    // Conteúdo
    [self _buildPanelContent];

    // Drag para mover painel
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
                                   initWithTarget:self action:@selector(_handlePanelDrag:)];
    [self.panelWindow addGestureRecognizer:pan];
}

- (void)_buildPanelContent {
    UIView *content = self.panelBlur.contentView;

    // Header: "LordVCAM v1.x"
    UILabel *title = [UILabel new];
    title.frame = CGRectMake(16, 12, kPanelWidth - 32, 24);
    title.text = [NSString stringWithFormat:@"LordVCAM "];
    title.textColor = [UIColor whiteColor];
    title.font = [UIFont boldSystemFontOfSize:16];
    [content addSubview:title];

    // Linha divisória
    UIView *div = [[UIView alloc] initWithFrame:CGRectMake(0, 44, kPanelWidth, 0.5)];
    div.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.2];
    [content addSubview:div];

    // Campo IP + botão conectar
    self.ipField = [[UITextField alloc] initWithFrame:CGRectMake(16, 56, 180, 38)];
    self.ipField.placeholder = kDefaultIP;
    self.ipField.text = kDefaultIP;
    self.ipField.borderStyle = UITextBorderStyleRoundedRect;
    self.ipField.keyboardType = UIKeyboardTypeDecimalPad;
    self.ipField.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.1];
    self.ipField.textColor = [UIColor whiteColor];
    self.ipField.delegate = self;
    [content addSubview:self.ipField];

    self.connectButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.connectButton.frame = CGRectMake(204, 56, 100, 38);
    [self.connectButton setTitle:@" Connect" forState:UIControlStateNormal];
    [self.connectButton setImage:[UIImage systemImageNamed:@"bolt.fill"] forState:UIControlStateNormal];
    self.connectButton.backgroundColor = [UIColor systemBlueColor];
    self.connectButton.tintColor = [UIColor whiteColor];
    self.connectButton.layer.cornerRadius = 8;
    [self.connectButton addTarget:self action:@selector(_connectTapped)
                 forControlEvents:UIControlEventTouchUpInside];
    [content addSubview:self.connectButton];

    // Stats label
    self.statsLabel = [UILabel new];
    self.statsLabel.frame = CGRectMake(16, 100, kPanelWidth - 32, 44);
    self.statsLabel.text = @"Waiting for frames...";
    self.statsLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.7];
    self.statsLabel.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
    self.statsLabel.numberOfLines = 2;
    [content addSubview:self.statsLabel];

    // Menu de modos (Stream / Gallery / Disable)
    [self _buildModeMenu:content];

    // Seção de controles de câmera
    [self _buildCameraControls:content];

    // Switch de replacement
    [self _buildReplacementSwitch:content];

    // Switch de áudio
    [self _buildAudioSwitch:content];

    // Spinner de loading
    self.spinner = [[UIActivityIndicatorView alloc]
                    initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.center = CGPointMake(kPanelWidth / 2, kPanelHeight / 2);
    self.spinner.color = [UIColor whiteColor];
    self.spinner.hidden = YES;
    [content addSubview:self.spinner];
}

- (void)_buildModeMenu:(UIView *)content {
    // tag 0 = Gallery, tag 1 = Disable
    NSArray *modes = @[
        @[@"photo.on.rectangle", @" Gallery"],
        @[@"nosign",             @" Disable"],
    ];

    CGFloat x = 16;
    for (NSArray *mode in modes) {
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
        btn.frame = CGRectMake(x, 152, 140, 36);
        [btn setImage:[UIImage systemImageNamed:mode[0]] forState:UIControlStateNormal];
        [btn setTitle:mode[1] forState:UIControlStateNormal];
        btn.tintColor = [UIColor whiteColor];
        btn.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.15];
        btn.layer.cornerRadius = 8;
        btn.tag = [modes indexOfObject:mode];
        [btn addTarget:self action:@selector(_modeTapped:) forControlEvents:UIControlEventTouchUpInside];
        [content addSubview:btn];
        x += 148;
    }
}

- (void)_buildCameraControls:(UIView *)content {
    // Grade de botões: zoom, rotação, flip, pan
    struct { NSString *icon; SEL action; } btns[] = {
        { @"plus.magnifyingglass",   @selector(zoomIn) },
        { @"minus.magnifyingglass",  @selector(zoomOut) },
        { @"rotate.right",           @selector(rotRight) },
        { @"rotate.left",            @selector(rotLeft) },
        { @"arrow.left.and.right.righttriangle.left.righttriangle.right", @selector(flipH) },
        { @"arrow.counterclockwise", @selector(_resetAll) },
    };

    CGFloat x = 16;
    CGFloat y = 200;
    for (int i = 0; i < 6; i++) {
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
        btn.frame = CGRectMake(x, y, 44, 44);
        [btn setImage:[UIImage systemImageNamed:[NSString stringWithUTF8String:btns[i].icon.UTF8String]]
             forState:UIControlStateNormal];
        btn.tintColor = [UIColor whiteColor];
        btn.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.15];
        btn.layer.cornerRadius = 8;
        [btn addTarget:self action:btns[i].action forControlEvents:UIControlEventTouchUpInside];
        [content addSubview:btn];
        x += 50;
        if (i == 2) { x = 16; y += 52; }
    }

    // Pan: cima, baixo, esquerda, direita
    self.panUpBtn    = [self _makeControlBtn:@"arrow.up"    action:@selector(panUp)    frame:CGRectMake(126, 196, 44, 44) parent:content];
    self.panDownBtn  = [self _makeControlBtn:@"arrow.down"  action:@selector(panDown)  frame:CGRectMake(126, 248, 44, 44) parent:content];
    self.panLeftBtn  = [self _makeControlBtn:@"arrow.left"  action:@selector(panLeft)  frame:CGRectMake( 76, 222, 44, 44) parent:content];
    self.panRightBtn = [self _makeControlBtn:@"arrow.right" action:@selector(panRight) frame:CGRectMake(176, 222, 44, 44) parent:content];
}

- (UIButton *)_makeControlBtn:(NSString *)icon action:(SEL)action
                         frame:(CGRect)frame parent:(UIView *)parent {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    btn.frame = frame;
    [btn setImage:[UIImage systemImageNamed:icon] forState:UIControlStateNormal];
    btn.tintColor = [UIColor whiteColor];
    btn.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.15];
    btn.layer.cornerRadius = 8;
    [btn addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [parent addSubview:btn];
    return btn;
}

- (void)_buildReplacementSwitch:(UIView *)content {
    UILabel *lbl = [UILabel new];
    lbl.frame = CGRectMake(16, 310, 180, 20);
    lbl.text = @"Enable Replacement";
    lbl.textColor = [UIColor whiteColor];
    lbl.font = [UIFont systemFontOfSize:14];
    [content addSubview:lbl];

    self._avs_cfg_rplSw = [[UISwitch alloc] init];
    self._avs_cfg_rplSw.frame = CGRectMake(kPanelWidth - 70, 305, 51, 31);
    self._avs_cfg_rplSw.onTintColor = [UIColor systemBlueColor];
    [self._avs_cfg_rplSw addTarget:self action:@selector(_avs_cfg_rplChg:)
                  forControlEvents:UIControlEventValueChanged];
    [content addSubview:self._avs_cfg_rplSw];
}

- (void)_buildAudioSwitch:(UIView *)content {
    UILabel *lbl = [UILabel new];
    lbl.frame = CGRectMake(16, 348, 180, 20);
    lbl.text = @"Audio Source";
    lbl.textColor = [UIColor whiteColor];
    lbl.font = [UIFont systemFontOfSize:14];
    [content addSubview:lbl];

    self._avs_cfg_aRplSw = [[UISwitch alloc] init];
    self._avs_cfg_aRplSw.frame = CGRectMake(kPanelWidth - 70, 343, 51, 31);
    self._avs_cfg_aRplSw.onTintColor = [UIColor systemGreenColor];
    [self._avs_cfg_aRplSw addTarget:self action:@selector(_avs_cfg_aRplChg:)
                   forControlEvents:UIControlEventValueChanged];
    [content addSubview:self._avs_cfg_aRplSw];
}

// -----------------------------------------------------------------------
// Menu dropdown (criado por setupWindows)
// -----------------------------------------------------------------------
- (void)_createMenuWindow {
    UIWindowScene *scene = (UIWindowScene *)[UIApplication.sharedApplication.connectedScenes anyObject];
    self.menuWindow = [[UIWindow alloc] initWithWindowScene:scene];
    self.menuWindow.windowLevel = UIWindowLevelAlert + 90;
    self.menuWindow.backgroundColor = [UIColor clearColor];
    self.menuWindow.hidden = YES;

    UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterialDark];
    UIVisualEffectView *blurView = [[UIVisualEffectView alloc] initWithEffect:blur];
    blurView.frame = self.menuWindow.bounds;
    blurView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    blurView.layer.cornerRadius = 14;
    blurView.clipsToBounds = YES;
    [self.menuWindow addSubview:blurView];
}

// -----------------------------------------------------------------------
// Ações dos botões de controle
// -----------------------------------------------------------------------
- (void)_loopBtnTapped {
    // Toggle loop mode on the active data source
    NSLog(@"[avsd] Loop toggle");
}

- (void)_connectTapped {
    NSString *ip = self.ipField.text;
    if (!ip || ip.length == 0) ip = kDefaultIP;
    // Notifica coordinator
    NSLog(@"[avsd] Connecting to %@", ip);
}

- (void)_modeTapped:(UIButton *)btn {
    // tag 0 = Gallery, tag 1 = Disable
    int mode = (int)btn.tag;
    self.activeBgButton = btn;

    if (mode == 0) {
        [self _openGalleryPicker];
    } else if (mode == 1) {
        [self.coordinator enableReplacement:NO];
        self._avs_cfg_rplSw.on = NO;
    }
}

- (void)_openGalleryPicker {
    AVSLocalDataProvider *provider = [[AVSLocalDataProvider alloc] init];
    _activeLocalProvider = provider;

    // Wire the coordinator before the picker opens so frames start flowing
    // as soon as the user picks media — no second tap needed.
    [self.coordinator setDataSource:provider];

    PHPickerConfiguration *config = [[PHPickerConfiguration alloc]
                                     initWithPhotoLibrary:[PHPhotoLibrary sharedPhotoLibrary]];
    config.filter = [PHPickerFilter anyFilterMatchingSubfilters:@[
        PHPickerFilter.videosFilter,
        PHPickerFilter.imagesFilter,
    ]];
    config.selectionLimit = 1;

    PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:config];
    picker.delegate = self;

    // SpringBoard has no root view controller; create a host window to present from.
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
        [itemProvider loadFileRepresentationForTypeIdentifier:@"public.movie"
                                           completionHandler:^(NSURL *url, NSError *err) {
            if (!url) return;
            // loadFileRepresentation gives a temporary URL valid only during the callback;
            // copy to a stable tmp path before returning to the main queue.
            NSURL *tmpURL = [[NSURL fileURLWithPath:NSTemporaryDirectory()]
                             URLByAppendingPathComponent:url.lastPathComponent];
            [[NSFileManager defaultManager] copyItemAtURL:url toURL:tmpURL error:nil];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self->_activeLocalProvider _avs_dat_loadVid:tmpURL];
                [self.coordinator enableReplacement:YES];
            });
        }];
    } else if ([itemProvider hasItemConformingToTypeIdentifier:@"public.image"]) {
        [itemProvider loadFileRepresentationForTypeIdentifier:@"public.image"
                                           completionHandler:^(NSURL *url, NSError *err) {
            if (!url) return;
            dispatch_async(dispatch_get_main_queue(), ^{
                [self->_activeLocalProvider _avs_dat_loadImg:url];
                [self.coordinator enableReplacement:YES];
            });
        }];
    }
}

- (void)_usbTapped {
    // Conecta via USB (127.0.0.1:8765)
    NSLog(@"[avsd] USB mode: 127.0.0.1:8765");
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
    self.coordinator._avs_cfg_replOn = sw.isOn;
    self._avs_cfg_replOn = sw.isOn;
}

- (void)_avs_cfg_aRplChg:(UISwitch *)sw {
    self.coordinator._avs_cfg_audioOn = sw.isOn;
}

// -----------------------------------------------------------------------
// Exibir / ocultar painel
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
    [UIView animateWithDuration:0.2 animations:^{
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
    // Atualiza ícone do botão flutuante baseado no estado
    NSString *iconName = @"camera.fill";

    // Indicadores de estado no ícone (de __cstring: "icon", "wifi", "color")
    if (self._avs_cfg_rplSw.isOn) {
        iconName = @"camera.fill";
    } else {
        iconName = @"nosign";
    }

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
    _menuMode = 1; // Filtros
    NSLog(@"[avsd] Switch to Filters");
}

// -----------------------------------------------------------------------
// Mover painel via drag
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
// Eyedropper window
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
// Notificações / Banners
// -----------------------------------------------------------------------
- (void)_avs_pres_buildNote:(id)config title:(NSString *)title body:(NSString *)body {
    // Cria banner de notificação sobre outras janelas
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

    // Auto-dismiss após 4s
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
    // Mostra tela de manutenção
    // "Scheduled Downtime — Service temporarily unavailable."
    // "ESTIMATED END: %@ (GMT-3)"
    // "Active subscriptions receive time credit for the downtime period."
    NSLog(@"[avsd] Maintenance: %@ ETA: %@", message, eta);
}

// -----------------------------------------------------------------------
// Atualização de estado de conexão na UI
// -----------------------------------------------------------------------
- (void)_avs_pp_updConn {
    BOOL connected = self._avs_cfg_connSt != nil &&
                     [self._avs_cfg_connSt isEqualToString:@"connected"];

    if (connected) {
        [self.connectButton setTitle:@" Disconnect" forState:UIControlStateNormal];
        [self.connectButton setImage:[UIImage systemImageNamed:@"bolt.slash.fill"]
                            forState:UIControlStateNormal];
        self.connectButton.backgroundColor = [UIColor systemRedColor];
    } else {
        [self.connectButton setTitle:@" Connect" forState:UIControlStateNormal];
        [self.connectButton setImage:[UIImage systemImageNamed:@"bolt.fill"]
                            forState:UIControlStateNormal];
        self.connectButton.backgroundColor = [UIColor systemBlueColor];
    }
}

// -----------------------------------------------------------------------
// UITextFieldDelegate
// -----------------------------------------------------------------------
- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

// -----------------------------------------------------------------------
// UIGestureRecognizerDelegate
// -----------------------------------------------------------------------
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gr
shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return YES;
}

@end
