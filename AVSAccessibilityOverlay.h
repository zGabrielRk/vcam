// AVSAccessibilityOverlay.h
// LordVCAM - Reconstructed via reverse engineering of AVServicesd.dylib
// Accessibility overlay: detects foreground app, hides UI when needed

#import <UIKit/UIKit.h>

// Uses _accessibilityFrontMostApplication to detect current foreground app.
// Hides panel when camera app (com.apple.camera) is in foreground.
// Monitors com.apple.springboard.lockstate for lock/unlock events.

@interface AVSAccessibilityOverlay : NSObject

// Fires when foreground app changes
- (void)_avs_ov_showPnl;
- (void)_avs_ov_hidePnl;
- (void)_avs_ov_updIcon;

// Combo toggle (Volume+Volume- simultaneous)
- (void)_avs_ov_showPnlC;

// Video control update
- (void)_avs_ov_updVidCtrl:(NSDictionary *)state;

// Registered via CFNotificationCenter for lock state
@property (nonatomic, assign) BOOL _isScreenLocked;

@end
