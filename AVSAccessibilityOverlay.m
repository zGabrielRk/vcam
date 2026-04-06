// AVSAccessibilityOverlay.m
// LordVCAM — Reconstruído via engenharia reversa de AVServicesd.dylib
// Monitora app em primeiro plano e oculta painel quando necessário

#import "AVSAccessibilityOverlay.h"
#import "AVSWSProtocol.h"
#import <UIKit/UIKit.h>
#import <notify.h>

// Darwin notifications registradas no binário (__cstring):
//   com.apple.springboard.lockstate
//   com.apple.springboard.hasBlankedScreen
static NSString *const kBundleCamera      = @"com.apple.camera";
static NSString *const kNotifOverlayShow  = @"com.avsd.overlay.show";
static NSString *const kNotifOverlayHide  = @"com.avsd.overlay.hide";
static NSString *const kNotifOverlayIcon  = @"com.avsd.overlay.updIcon";

// -----------------------------------------------------------------------
// Callbacks Darwin (C puro — registradas com CFNotificationCenter)
// -----------------------------------------------------------------------
static void _avs_ov_onLock(CFNotificationCenterRef center,
                            void *observer,
                            CFStringRef name,
                            const void *object,
                            CFDictionaryRef userInfo)
{
    AVSAccessibilityOverlay *overlay = (__bridge AVSAccessibilityOverlay *)observer;

    BOOL isLocked = AVSLockStateQuery(overlay->_lockNotifyToken);
    overlay._isScreenLocked = isLocked;

    dispatch_async(dispatch_get_main_queue(), ^{
        if (isLocked) {
            [overlay _avs_ov_hidePnl];
        } else {
            [overlay _avs_ov_updIcon];
        }
    });
}

static void _avs_ov_onBlank(CFNotificationCenterRef center,
                             void *observer,
                             CFStringRef name,
                             const void *object,
                             CFDictionaryRef userInfo)
{
    AVSAccessibilityOverlay *overlay = (__bridge AVSAccessibilityOverlay *)observer;
    dispatch_async(dispatch_get_main_queue(), ^{
        [overlay _avs_ov_hidePnl];
    });
}

@implementation AVSAccessibilityOverlay {
    NSTimer *_foregroundCheckTimer;
    NSString *_lastFrontBundleId;
    int       _lockNotifyToken;         // token registrado uma vez em init
    SEL       _frontAppSel;             // cache do SEL privado
    BOOL      _frontAppSelResponds;     // cache do respondsToSelector: (invariante)
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _isScreenLocked    = NO;
        _lastFrontBundleId = nil;
        _lockNotifyToken   = NOTIFY_TOKEN_INVALID;
        _frontAppSel       = NSSelectorFromString(@"_accessibilityFrontMostApplication");
        _frontAppSelResponds = [[UIApplication sharedApplication] respondsToSelector:_frontAppSel];
        [self _registerNotifications];
        [self _startForegroundMonitor];
    }
    return self;
}

- (void)dealloc {
    [_foregroundCheckTimer invalidate];
    CFNotificationCenterRef darwin = CFNotificationCenterGetDarwinNotifyCenter();
    CFNotificationCenterRemoveObserver(darwin, (__bridge void *)self, NULL, NULL);
    if (_lockNotifyToken != NOTIFY_TOKEN_INVALID) {
        notify_cancel(_lockNotifyToken);
    }
}

// -----------------------------------------------------------------------
// Registro de notificações Darwin
// -----------------------------------------------------------------------
- (void)_registerNotifications {
    CFNotificationCenterRef darwin = CFNotificationCenterGetDarwinNotifyCenter();

    CFNotificationCenterAddObserver(
        darwin,
        (__bridge void *)self,
        _avs_ov_onLock,
        CFSTR("com.apple.springboard.lockstate"),
        NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately
    );

    CFNotificationCenterAddObserver(
        darwin,
        (__bridge void *)self,
        _avs_ov_onBlank,
        CFSTR("com.apple.springboard.hasBlankedScreen"),
        NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately
    );

    // Registra token uma única vez para leitura eficiente do estado de lock
    notify_register_check("com.apple.springboard.lockstate", &_lockNotifyToken);
}

// -----------------------------------------------------------------------
// Monitor de app em primeiro plano (polling a cada 0.5s)
// Usa _accessibilityFrontMostApplication da API privada do SpringBoard
// -----------------------------------------------------------------------
- (void)_startForegroundMonitor {
    __weak typeof(self) ws = self;
    _foregroundCheckTimer = [NSTimer timerWithTimeInterval:0.5
                                                   repeats:YES
                                                     block:^(NSTimer *t) {
        [ws _checkForegroundApp];
    }];
    [[NSRunLoop mainRunLoop] addTimer:_foregroundCheckTimer forMode:NSDefaultRunLoopMode];
}

- (void)_checkForegroundApp {
    // SEL e respondsToSelector: são invariantes — cached em init
    if (!_frontAppSelResponds) return;

    NSString *frontBundle = nil;
    id springBoard = [UIApplication sharedApplication];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    id frontApp = [springBoard performSelector:_frontAppSel];
#pragma clang diagnostic pop
    frontBundle = [frontApp valueForKey:@"bundleIdentifier"];

    if (!frontBundle) return;
    if ([frontBundle isEqualToString:_lastFrontBundleId]) return;

    _lastFrontBundleId = frontBundle;

    // Oculta o painel quando o app de câmera está em primeiro plano
    BOOL isCameraApp = [frontBundle isEqualToString:kBundleCamera];
    if (isCameraApp) {
        [self _avs_ov_hidePnl];
    } else {
        [self _avs_ov_updIcon];
    }
}

// -----------------------------------------------------------------------
// Operações de visibilidade do painel
// Essas implementações delegam ao AVSPreferencePanel via notificação local
// -----------------------------------------------------------------------
- (void)_avs_ov_showPnl {
    if (_isScreenLocked) return;
    [[NSNotificationCenter defaultCenter]
        postNotificationName:kNotifOverlayShow object:nil];
}

- (void)_avs_ov_hidePnl {
    [[NSNotificationCenter defaultCenter]
        postNotificationName:kNotifOverlayHide object:nil];
}

- (void)_avs_ov_updIcon {
    [[NSNotificationCenter defaultCenter]
        postNotificationName:kNotifOverlayIcon object:nil];
}

// Combo toggle: chamado pelo hook de Volume+Volume- simultâneos
- (void)_avs_ov_showPnlC {
    if (_isScreenLocked) return;
    // Toggle: se visível esconde, se escondido mostra
    [[NSNotificationCenter defaultCenter]
        postNotificationName:kNotifOverlayShow object:@{@"combo": @YES}];
}

// Atualiza controles de vídeo (play/pause/seek) na overlay
- (void)_avs_ov_updVidCtrl:(NSDictionary *)state {
    [[NSNotificationCenter defaultCenter]
        postNotificationName:kNotifOverlayIcon object:state];
}

@end
