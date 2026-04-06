// AVSServiceConfiguration.h
// LordVCAM - Reconstructed via reverse engineering of AVServicesd.dylib
// License/subscription management, anti-tamper, API client

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

// API base endpoints inferred from strings:
//   POST  {srvAddr}/auth/report-bug
//   GET   {srvAddr}/member
//   GET   {srvAddr}/payments/crypto-currencies?amount=%.2f
//
// Auth headers:
//   Content-Type: application/json
//   User-Agent: CFNetwork/1410.0.3 Darwin/22.6.0
//
// Persistent storage (all in /var/tmp/com.apple.avfcache/):
//   prefs.plist    — feature flags, rotation, pan, speed, etc.
//   prefs.lock     — lock file
//   state.plist    — connection state
//   cache.plist    — cached server response
//   meta.dat       — encrypted metadata
//   session.dat    — session token
//   crash.txt      — crash log
//   probe_<id>.txt — probe output per process

// Anti-tamper / security check error codes (from __cstring):
//   BL01: Conflicting tweak detected
//   BL02: Frida or debugger detected
//   IC02: Internal check 02
//   0xE09: Network error
//   0xE01: Auth error
//   0xD01: License error
//   0xE02: Blocked
//   0xE03, 0xE04: Ban errors
//   0xE05..0xE08: Various API errors
//   0xM01: Maintenance mode
//   ep_0x03, fn_0x07: function hook detection codes

@interface AVSServiceConfiguration : NSObject

@property (nonatomic, copy) NSString *_avs_cfg_ver;       // tweak version e.g. "1.2.3"
@property (nonatomic, copy) NSString *_avs_cfg_bldVer;    // build number
@property (nonatomic, copy) NSString *_avs_cfg_srvAddr;   // API server address
@property (nonatomic, copy) NSString *_avs_cfg_credential;// encrypted credential
@property (nonatomic, copy) NSString *_avs_cfg_sysId;     // system ID

// Fingerprinting
// Methods: "dHash" (device hash), "iokit" (IOKit serial), "fallback"
@property (nonatomic, copy) NSString *_avs_cfg_fpMethod;
@property (nonatomic, copy) NSString *_avs_cfg_digest;    // SHA256 of binary
@property (nonatomic, copy) NSString *_avs_cfg_kcAnchor;  // keychain item

// Anti-tamper checks performed:
//   1. Binary digest vs stored checksum
//   2. Frida detection (ptrace / port check / /proc scan)
//   3. Debugger detection (sysctl P_TRACED)
//   4. Hook detection on system functions (fn_0x07)
//   5. Conflicting tweaks (BL01/BL02)
//   6. SPKI pinning for API TLS

// Security
- (NSString *)_avs_cfg_spkiHash:(NSData *)certData;
- (void)_avs_chk_actLic;         // check/activate license
- (void)_avs_cfg_writeSession;   // persist session to session.dat

// Network
- (void)postToEndpoint:(NSString *)endpoint
                  body:(NSDictionary *)body
            completion:(void(^)(NSDictionary *response, NSError *error))completion;

// Attestation keys (from prefs.plist):
//   _avs_cfg_authorized   BOOL
//   _avs_cfg_attestation  NSString
//   _avs_cfg_checksum     NSString (64-char hex)
//   _avs_cfg_lastcheck    NSString timestamp
//   _avs_cfg_credential   NSString encrypted

// Wallet / subscription state
@property (nonatomic, assign) double   _avs_cfg_balance;
@property (nonatomic, copy)   NSString *_avs_cfg_remaining;
@property (nonatomic, copy)   NSString *_avs_cfg_expiry;
@property (nonatomic, assign) BOOL     _avs_cfg_isPurch;
@property (nonatomic, strong) NSArray  *_avs_cfg_avPlans;
@property (nonatomic, assign) double   _avs_cfg_planMin;

// Payment (wallet)
@property (nonatomic, strong) NSNumber *_avs_cfg_wPayId;
@property (nonatomic, copy)   NSString *_avs_cfg_wPollT;
@property (nonatomic, assign) double   _avs_cfg_wLastAmt;
@property (nonatomic, assign) double   _avs_cfg_wPollStart;
@property (nonatomic, strong) NSTimer  *_avs_cfg_wPollTmr;

// Device info
@property (nonatomic, copy) NSString *_avs_cfg_hwMdl;    // hw model e.g. "iPhone15,2"
@property (nonatomic, copy) NSString *_avs_cfg_devMdl;   // device model name
@property (nonatomic, copy) NSString *_avs_cfg_devNm;    // device name
@property (nonatomic, copy) NSString *_avs_cfg_osVer;    // iOS version
@property (nonatomic, copy) NSString *_avs_cfg_usrEmail; // logged-in user email
@property (nonatomic, copy) NSString *_avs_cfg_chipVal;  // chip identifier

// Connection / runtime state (shared with PresentationController)
@property (nonatomic, copy)   NSString *_avs_cfg_connSt;     // connection state
@property (nonatomic, assign) double    _avs_cfg_curFPS;      // current FPS
@property (nonatomic, assign) double    _avs_cfg_decEMA;      // decode EMA latency
@property (nonatomic, strong) UILabel  *_avs_cfg_statusLabel; // status display label

// Ban state
@property (nonatomic, copy) NSString *_avs_cfg_banText;  // ban reason
@property (nonatomic, assign) BOOL    _avs_cfg_banType;  // ban type
@property (nonatomic, copy) NSString *_avs_cfg_banExp;   // ban expiry

// Error / update / maintenance
@property (nonatomic, copy) NSString *_avs_cfg_lastErr;   // last error
@property (nonatomic, copy) NSString *_avs_cfg_latest;    // latest available version
@property (nonatomic, copy) NSString *_avs_cfg_maintMsg;  // maintenance message
@property (nonatomic, copy) NSString *_avs_cfg_maintETA;  // maintenance ETA

// Callbacks
@property (nonatomic, copy) void(^_avs_cfg_dismissCb)(void);
@property (nonatomic, copy) void(^_avs_cfg_hideCb)(void);

// Lock screen detection
@property (nonatomic, assign) BOOL _isScreenLocked;
// Observed notification: com.apple.springboard.lockstate
// SpringBoard classes hooked: SBLockScreenManager, SBDashBoardLockScreenEnvironment

@end
