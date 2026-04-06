// AVSFrameCoordinator.h
// LordVCAM - Reconstructed via reverse engineering of AVServicesd.dylib
// Central coordinator: hooks AVFoundation camera pipeline, injects frames

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <AVFoundation/AVFoundation.h>
#import "AVSRenderPipeline.h"

@protocol AVSDataProvider;

// Injected via CydiaSubstrate into mediaserverd / SpringBoard
// Hooks: AVCaptureConnection, FigCaptureClientSessionMonitor, BWNodeOutput
@interface AVSFrameCoordinator : NSObject

// Render pipeline (exposed for UI delegation)
@property (nonatomic, readonly) AVSRenderPipeline *renderPipeline;

// Current source (stream / gallery / local)
@property (nonatomic, strong) id<AVSDataProvider> _avs_cfg_curSrc;

// Stats
@property (nonatomic, assign) double   _avs_cfg_frmAge;   // age of latest frame (s)
@property (nonatomic, assign) double   _avs_cfg_lastRecv; // timestamp last received
@property (nonatomic, assign) double   _avs_cfg_decEMA;   // decode EMA latency
@property (nonatomic, copy)   NSString *_avs_cfg_curFmt;  // format string e.g. "420v"
@property (nonatomic, copy)   NSString *_avs_cfg_sessFmt; // session format

// State flags
@property (nonatomic, assign) BOOL _avs_cfg_replOn;  // replacement enabled
@property (nonatomic, assign) BOOL _avs_cfg_feedOn;  // feed active
@property (nonatomic, assign) BOOL _avs_cfg_loopOn;  // loop mode
@property (nonatomic, assign) BOOL _avs_cfg_prevOn;  // preview enabled
@property (nonatomic, assign) BOOL _avs_cfg_moveOn;  // live motion enabled
@property (nonatomic, assign) BOOL _avs_cfg_audioOn; // audio replacement
@property (nonatomic, assign) BOOL _avs_cfg_grainOn; // grain/film grain effect
@property (nonatomic, assign) BOOL _avs_cfg_fxOn;    // filters enabled
@property (nonatomic, assign) BOOL _avs_cfg_fbOn;    // framebuffer output
@property (nonatomic, assign) BOOL _avs_cfg_floatOn; // floating window visible
@property (nonatomic, assign) BOOL _avs_cfg_prlxOn;  // parallax effect
@property (nonatomic, assign) BOOL _avs_cfg_inTrans; // in transition
@property (nonatomic, assign) BOOL _avs_cfg_edCamMode; // edit cam mode
@property (nonatomic, assign) BOOL _avs_cfg_stallRec;  // stall recovery
@property (nonatomic, assign) BOOL _avs_cfg_prevEn;    // preview enabled

// Per-frame injection log counters
@property (nonatomic, assign) int _avs_cfg_frmDec;   // frames decoded
@property (nonatomic, assign) int _avs_cfg_frmSub;   // frames submitted
@property (nonatomic, assign) int _avs_cfg_frmRecv;  // frames received
@property (nonatomic, assign) int _avs_cfg_frmProc;  // frames processed
@property (nonatomic, assign) int _avs_cfg_frmDlvr;  // frames delivered
@property (nonatomic, assign) int _avs_cfg_frmSkip;  // frames skipped
@property (nonatomic, assign) int _avs_cfg_decErr;   // decode errors
@property (nonatomic, assign) int _avs_cfg_blendCnt; // blend count

// Timing
@property (nonatomic, assign) double _avs_cfg_srvEnc;      // server encode time
@property (nonatomic, assign) double _avs_cfg_srvPipe;     // server pipeline time
@property (nonatomic, assign) double _avs_cfg_srvJitter;   // network jitter
@property (nonatomic, assign) double _avs_cfg_lastProcMs;  // last process ms
@property (nonatomic, assign) double _avs_cfg_lastDec;     // last decode ts
@property (nonatomic, assign) double _avs_cfg_lastStall;   // last stall ts

// Latest sample buffers
@property (nonatomic, assign) CMSampleBufferRef _avs_cfg_lastPB;      // last pixel buffer
@property (nonatomic, assign) CMSampleBufferRef latestFrame;          // latest injected frame

// Connection / session state
@property (nonatomic, copy)   NSString *_avs_cfg_connSt;   // connection state string
@property (nonatomic, assign) int       _avs_cfg_msgRecv;  // messages received
@property (nonatomic, assign) int       _avs_cfg_msgSent;  // messages sent
@property (nonatomic, assign) int       _avs_cfg_reconAtt; // reconnect attempts
@property (nonatomic, assign) int       _avs_cfg_reconCnt; // reconnect count
@property (nonatomic, assign) double    _avs_cfg_lastMsgT; // last message time
@property (nonatomic, strong) NSObject<OS_dispatch_source> *_avs_cfg_syncTimer;
@property (nonatomic, strong) NSObject<OS_dispatch_source> *_avs_cfg_trkTimer;
@property (nonatomic, strong) NSTimer  *_avs_cfg_wPollTmr; // wallet poll timer
@property (nonatomic, assign) double    _avs_cfg_wPollStart;
@property (nonatomic, copy)   NSString *_avs_cfg_wPollT;

// Pending messages queue
@property (nonatomic, strong) NSArray  *_avs_cfg_pendMsgs;
@property (nonatomic, strong) NSDictionary *_avs_cfg_pendNote;

// Notification / banner
@property (nonatomic, strong) UIWindow *_avs_cfg_bannerWin;
@property (nonatomic, strong) UIWindow *_avs_cfg_valBanWin;
@property (nonatomic, copy)   NSString *_avs_cfg_banText;
@property (nonatomic, copy)   NSString *_avs_cfg_banExp;
@property (nonatomic, assign) BOOL      _avs_cfg_banType;
@property (nonatomic, assign) BOOL      _avs_cfg_notifDC;

// Auth / account
@property (nonatomic, copy)   NSString *_avs_cfg_usrEmail;
@property (nonatomic, copy)   NSString *_avs_cfg_remaining; // time remaining string
@property (nonatomic, copy)   NSString *_avs_cfg_expiry;
@property (nonatomic, assign) BOOL      _avs_cfg_isPurch;   // is purchased/active
@property (nonatomic, assign) BOOL      _avs_cfg_hsOk;      // handshake ok
@property (nonatomic, strong) NSNumber *_avs_cfg_wPayId;    // wallet payment id
@property (nonatomic, assign) double    _avs_cfg_wLastAmt;
@property (nonatomic, assign) double    _avs_cfg_balance;
@property (nonatomic, strong) NSArray  *_avs_cfg_avPlans;   // available plans
@property (nonatomic, assign) double    _avs_cfg_planMin;   // minimum plan price

// Device / build info
@property (nonatomic, copy)   NSString *_avs_cfg_ver;       // tweak version
@property (nonatomic, copy)   NSString *_avs_cfg_bldVer;    // build version
@property (nonatomic, copy)   NSString *_avs_cfg_latest;    // latest available version
@property (nonatomic, copy)   NSString *_avs_cfg_hwMdl;     // hw model e.g. "iPhone15,2"
@property (nonatomic, copy)   NSString *_avs_cfg_devMdl;    // device model name
@property (nonatomic, copy)   NSString *_avs_cfg_devNm;     // device name
@property (nonatomic, copy)   NSString *_avs_cfg_osVer;     // iOS version
@property (nonatomic, copy)   NSString *_avs_cfg_sysId;     // system ID (UDID-like)
@property (nonatomic, copy)   NSString *_avs_cfg_chipVal;   // chip identifier
@property (nonatomic, copy)   NSString *_avs_cfg_digest;    // binary digest/hash
@property (nonatomic, copy)   NSString *_avs_cfg_fpMethod;  // fingerprint method
@property (nonatomic, copy)   NSString *_avs_cfg_kcAnchor;  // keychain anchor
@property (nonatomic, copy)   NSString *_avs_cfg_mode;      // current mode
@property (nonatomic, copy)   NSString *_avs_cfg_netAddr;   // server address
@property (nonatomic, copy)   NSString *_avs_cfg_srvAddr;   // server address

// UI state
@property (nonatomic, copy)   NSString *_avs_cfg_loadName;  // loading name
@property (nonatomic, copy)   NSString *_avs_cfg_lastErr;   // last error string
@property (nonatomic, copy)   NSString *_avs_cfg_maintMsg;  // maintenance message
@property (nonatomic, copy)   NSString *_avs_cfg_maintETA;  // maintenance ETA
@property (nonatomic, assign) BOOL      _avs_cfg_loggedFirst;
@property (nonatomic, assign) int       _avs_cfg_iconSt;    // icon state
@property (nonatomic, assign) int       _avs_cfg_pbSpeed;   // playback speed
@property (nonatomic, assign) double    _avs_cfg_curFPS;    // current FPS
@property (nonatomic, assign) int       _avs_cfg_vidFPS;    // video FPS
@property (nonatomic, assign) int       _avs_cfg_vidRot;    // video rotation

// Gallery state
@property (nonatomic, copy)   NSString *_avs_cfg_galName;   // gallery item name
@property (nonatomic, assign) int       _avs_cfg_galSt;     // gallery state

// Motion
@property (nonatomic, strong) UISwitch *_avs_cfg_motSw;
@property (nonatomic, strong) UILabel  *_avs_cfg_motLbl;
@property (nonatomic, strong) UIButton *_avs_cfg_motPlsBtn;
@property (nonatomic, strong) UIButton *_avs_cfg_motMinBtn;
@property (nonatomic, assign) BOOL      _avs_cfg_motOn;
@property (nonatomic, assign) double    _avs_cfg_motGain;

// UI widgets (password/email fields)
@property (nonatomic, strong) UITextField *_avs_cfg_emailFld;
@property (nonatomic, strong) UITextField *_avs_cfg_passFld;
@property (nonatomic, strong) UILabel     *_avs_cfg_statusLabel;
@property (nonatomic, strong) UIActivityIndicatorView *_avs_cfg_pSpin;

// Callbacks
@property (nonatomic, copy) void(^_avs_cfg_hideCb)(void);
@property (nonatomic, copy) void(^_avs_cfg_onDec)(CMSampleBufferRef);
@property (nonatomic, copy) void(^_avs_cfg_dismissCb)(void);

// Switches
@property (nonatomic, strong) UISwitch *_avs_cfg_aRplSw;  // audio replacement
@property (nonatomic, strong) UISwitch *_avs_cfg_rplSw;   // video replacement

// Main operations
- (void)_avs_cfg_ackEvent:(id)event;
- (void)_avs_cfg_ackNote:(id)note;
- (void)_avs_cfg_aRplChg:(id)sender;
- (void)_avs_cfg_rplChg:(id)sender;
- (void)_avs_cfg_motTogChg:(id)sender;
- (void)_avs_cfg_motPlus;
- (void)_avs_cfg_motMinus;
- (void)_avs_cfg_setPbSpd:(id)speed;
- (void)_avs_cfg_togglePassVis:(id)sender;
- (void)_avs_cfg_resolveNet;
- (void)_avs_cfg_regLockObs;
- (void)_avs_cfg_startTrk;
- (void)_avs_cfg_stopTrk;
- (void)_avs_cfg_writeSession;
- (void)_avs_cfg_nextEvent;
- (NSString *)_avs_cfg_spkiHash:(NSData *)certData;
- (void)set_avs_cfg_st:(id)state;

// Public interface used by KYCHooks and transport classes
- (CMSampleBufferRef)injectReplacementForFrame:(CMSampleBufferRef)original;
- (void)submitNALData:(NSData *)data sequenceNumber:(int)seq serverTimestamp:(double)srvTs;
- (void)submitAudioPCM:(const float *)samples count:(int)count channels:(int)ch sampleRate:(double)rate;
- (BOOL)consumeAudioPCM:(float *)output count:(int)count channels:(int)ch sampleRate:(double)rate;
- (void)setDataSource:(id<AVSDataProvider>)source;
- (void)enableReplacement:(BOOL)enable;
- (void)enqueueServerEvent:(NSDictionary *)event;

// IPC — called from KYCHooks to configure cross-process role
- (void)configureIPCAsProducer;  // SpringBoard
- (void)configureIPCAsConsumer;  // mediaserverd
@end
