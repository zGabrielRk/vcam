// AVSPreferencePanel.h
// LordVCAM - Reconstructed via reverse engineering of AVServicesd.dylib
// Main UI overlay panel — floating control window injected into SpringBoard

#import <UIKit/UIKit.h>
#import "AVSFrameCoordinator.h"

// The panel is a UIWindow injected into the SpringBoard process.
// Triggered by floating shortcut button (UIWindow with WindowLevel above all).
// Supports both WiFi and USB connection modes.

@interface AVSPreferencePanel : NSObject
    <UITextFieldDelegate, UIGestureRecognizerDelegate>

// Coordinator reference (set by KYCHooks during SpringBoard setup)
@property (nonatomic, weak) AVSFrameCoordinator *coordinator;

// State (used across WiFi/USB connection updates)
@property (nonatomic, copy)   NSString *_avs_cfg_connSt;   // "connected" | "connecting" | "disconnected"
@property (nonatomic, assign) BOOL      _avs_cfg_replOn;   // replacement enabled
@property (nonatomic, assign) BOOL      _avs_cfg_isPurch;  // licensed
@property (nonatomic, assign) BOOL      _isScreenLocked;

// Windows
@property (nonatomic, strong) UIWindow *window;          // main app window
@property (nonatomic, strong) UIWindow *panelWindow;     // control panel window
@property (nonatomic, strong) UIWindow *menuWindow;      // dropdown menu window
@property (nonatomic, strong) UIWindow *previewWindow;   // video preview window
@property (nonatomic, strong) UIWindow *buttonWindow;    // floating button window
@property (nonatomic, strong) UIWindow *eyedropperWindow;// color picker window
@property (nonatomic, strong) UIWindow *_avs_cfg_bannerWin; // notification banner
@property (nonatomic, strong) UIWindow *_avs_cfg_valBanWin; // validation banner

// Panel UI
@property (nonatomic, strong) UIVisualEffectView *panelBlur;
@property (nonatomic, strong) UIView  *panelBackdrop;
@property (nonatomic, strong) UIView  *backdropView;
@property (nonatomic, strong) UIView  *videoSection;
@property (nonatomic, strong) UIView  *videoDivider;
@property (nonatomic, strong) UIView  *bgColorSection;

// Connection UI
@property (nonatomic, strong) UITextField *ipField;          // IP address input
@property (nonatomic, strong) UIButton    *connectButton;    // Connect/Disconnect
@property (nonatomic, strong) UIButton    *stopUSBButton;
@property (nonatomic, strong) UILabel     *statsLabel;       // "RECV 30 DEC 30..."

// Floating window
@property (nonatomic, strong) UIButton *floatingButton;
@property (nonatomic, strong) UISwitch *floatingSwitch;
@property (nonatomic, assign) BOOL      panelVisible;
@property (nonatomic, assign) BOOL      panelCentered;
@property (nonatomic, assign) BOOL      isDragging;
@property (nonatomic, assign) CGPoint   _panelDragStart;

// Gallery / source controls
@property (nonatomic, strong) UIButton *galleryButton;       // "Gallery" — pick video/photo
@property (nonatomic, strong) UIButton *clearGalleryButton;
@property (nonatomic, strong) UIImageView *previewImageView;

// Playback controls (for gallery mode)
@property (nonatomic, strong) UIButton *loopBtn;             // repeat
@property (nonatomic, strong) UIButton *speedButton;         // playback speed

// Camera transform controls
@property (nonatomic, strong) UIButton *zoomInBtn;
@property (nonatomic, strong) UIButton *zoomOutBtn;
@property (nonatomic, strong) UIButton *rotLeftBtn;
@property (nonatomic, strong) UIButton *rotRightBtn;
@property (nonatomic, strong) UIButton *flipHBtn;
@property (nonatomic, strong) UIButton *panLeftBtn;
@property (nonatomic, strong) UIButton *panRightBtn;  // _avs_cfg_motMinBtn
@property (nonatomic, strong) UIButton *panUpBtn;
@property (nonatomic, strong) UIButton *panDownBtn;   // _avs_cfg_motPlsBtn
@property (nonatomic, strong) UIButton *resetBtn;

// Filter controls
@property (nonatomic, strong) UILabel  *brightnessLabel;
@property (nonatomic, strong) UILabel  *contrastLabel;
@property (nonatomic, strong) UILabel  *saturationLabel;
@property (nonatomic, strong) UILabel  *gammaLabel;

// Motion switch
@property (nonatomic, strong) UISwitch *_avs_cfg_motSw;
@property (nonatomic, strong) UILabel  *_avs_cfg_motLbl;

// Audio replacement switch
@property (nonatomic, strong) UISwitch *_avs_cfg_aRplSw;
@property (nonatomic, strong) UISwitch *_avs_cfg_rplSw;

// Replacement toggle
@property (nonatomic, strong) UIButton *activeBgButton;
@property (nonatomic, strong) UIButton *_accessButton;

// Activity
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UIActivityIndicatorView *_avs_cfg_pSpin;

// Eyedropper
@property (nonatomic, strong) UIView   *eyedropperIndicator;
@property (nonatomic, strong) UIImage  *eyedropperScreenshot;

// Menu mode
// 0 = main, 1 = filters, 2 = controls
@property (nonatomic, assign) int menuMode;

// Panel operations
- (void)_togglePanel;      // volume combo shortcut calls this
- (void)_avs_ov_showPnl;
- (void)_avs_ov_hidePnl;
- (void)_avs_ov_updIcon;  // update floating button icon

// UI actions
- (void)repositionPanel;
- (void)dismiss;
- (void)switchToFilters;
- (void)gammaUp;
- (void)zoomOut;
- (void)panLeft;
- (void)panDown;
- (void)_loopBtnTapped;
- (void)forceHideOnLock;
- (void)setupWindows;
- (void)cancelIdleTimer;
- (void)_avs_pp_updConn;  // update connection state in UI

// Notification panel
- (void)_avs_pres_buildNote:(id)note title:(NSString *)title body:(NSString *)body;
- (void)_avs_pres_showMnt:(NSString *)message estimatedEnd:(NSString *)eta;

// Gallery mode
- (void)_avs_pp_galActive:(BOOL)active;

// Restore connection state after alert/picker dismiss
- (void)_avs_pp_restoreConn;

// UI factory methods
- (UIButton *)_glassButton:(NSString *)title textColor:(UIColor *)textColor
                      icon:(NSString *)icon compact:(BOOL)compact
                     frame:(CGRect)frame action:(SEL)action;
- (UIButton *)_solidButton:(NSString *)title color:(UIColor *)color
                      icon:(NSString *)icon compact:(BOOL)compact
                     frame:(CGRect)frame action:(SEL)action;
- (void)addDividerTo:(UIView *)parent atY:(CGFloat)y;
- (CGFloat)addFilterRow:(NSString *)label value:(float)value
             valueLabel:(UILabel **)outLabel minusAction:(SEL)minus
             plusAction:(SEL)plus toView:(UIView *)parent atY:(CGFloat)y;
- (void)addVersionFooterToContent:(UIView *)content atY:(CGFloat)y innerWidth:(CGFloat)w;
- (void)buildControlsPanel:(UIView *)content y:(CGFloat)y;
- (void)styleTextField:(UITextField *)tf placeholder:(NSString *)placeholder;
- (UIView *)createDismissableBackdrop:(UIView *)parent alpha:(CGFloat)alpha;
- (void)recalcExpiredLayout:(NSDictionary *)info content:(UIView *)content rootView:(UIView *)rootView;

// Mode switching & interactions
- (void)switchToMode:(int)mode;
- (void)onToggleNotification:(NSNotification *)note;
- (void)handleEyedropperTouch:(UIGestureRecognizer *)gr;
- (void)sampleColorAtScreenPoint:(CGPoint)point;
- (void)updateBgButtonSelection:(UIButton *)selected;
- (void)floatingToggleChanged:(id)sender;
- (void)handlePlanPurchase:(NSDictionary *)plan;
- (void)handleCurrencySelection:(NSString *)currency;
- (void)reportBug:(NSString *)subject message:(NSString *)message;
- (void)copyRepoURL:(id)sender;
- (void)positionPanel:(CGPoint)origin;

// Photo / gesture handlers
- (void)loadPhoto:(id)sender;
- (void)handleButtonTap:(UIButton *)btn;
- (void)handleButtonDrag:(UIPanGestureRecognizer *)gr;
- (void)handleWindowDrag:(UIPanGestureRecognizer *)gr;
- (void)singlePressUp:(id)sender;

@end

// -----------------------------------------------------------------------
// Menu items (from __cstring, SF Symbols used as icons):
//   camera.fill      → Stream (WiFi/USB)
//   cable.connector  → USB
//   wifi             → WiFi
//   photo.on.rectangle → Gallery
//   nosign           → Disable
//   bolt.fill        → Connect/Select
//   camera.filters   → Filters
//   slider.horizontal.3 → Controls
//   wallet.pass      → Wallet
//   rectangle.portrait.and.arrow.right → Logout
//   paperplane.fill  → Contact Support
// -----------------------------------------------------------------------
