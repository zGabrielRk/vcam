// AVSPresentationController.h
// LordVCAM - Reconstructed via reverse engineering of AVServicesd.dylib
// Manages alert/sheet presentation: subscriptions, wallet, plans, payments

#import <UIKit/UIKit.h>

@class AVSServiceConfiguration;

// Screens managed (inferred from strings):
//   1. Login / Register
//   2. Wallet (balance, recharge)
//   3. Available Plans (activate subscription)
//   4. PIX payment (QR code + copy-paste)
//   5. Crypto payment (USDT BEP20/Polygon/Base/SOL, USDC/SOL, LTC)
//   6. Update Required
//   7. Reinstall Required
//   8. Maintenance / Downtime
//   9. Ban / Suspended
//  10. Welcome / Telegram channel

@interface AVSPresentationController : NSObject

- (instancetype)initWithConfig:(AVSServiceConfiguration *)config;

// Login / Registration
- (void)presentLoginScreen:(UIViewController *)parent;

// Wallet / Recharge / Plans
- (void)presentWallet:(UIViewController *)parent;
- (void)presentRechargeScreen:(UIViewController *)parent;
- (void)presentPlans:(UIViewController *)parent;

// Plan activation confirmation
- (void)confirmPlanActivation:(NSString *)planName
                     currency:(NSString *)currency
                        price:(double)price
                      balance:(double)balance
                   completion:(void(^)(BOOL confirmed))completion;

// Notification banner
- (void)_avs_pres_buildNote:(id)config title:(NSString *)title body:(NSString *)body;

// Ban management
- (void)_avs_pres_buildBan:(NSString *)reason
                  duration:(NSTimeInterval)duration
          _avs_cfg_banType:(BOOL)banType;
- (void)_avs_pres_showBan:(NSString *)reason
                 duration:(NSTimeInterval)duration
         _avs_cfg_banType:(BOOL)banType;
- (void)_avs_pres_clearBan;
- (BOOL)_avs_pres_isBanned;
- (void)_avs_pres_banInfo;

// Error display
- (void)_avs_pres_buildErrLoc:(NSString *)location message:(NSString *)message;
- (void)_avs_pres_showErrLoc:(NSString *)location message:(NSString *)message;

// Download / Update
- (void)_avs_pres_buildDL:(NSString *)version;
- (void)_avs_pres_showDL:(NSString *)version;
- (void)_avs_pres_buildUpd:(NSString *)info;

// Server error
- (void)_avs_pres_buildSE;
- (void)_avs_pres_showSE;

// Subscription expiration
- (void)_avs_pres_buildExp;
- (void)_avs_pres_showExp;

// Maintenance
- (void)_avs_pres_buildMnt:(NSString *)message estimatedEnd:(NSString *)eta;
- (void)_avs_pres_showMnt:(NSString *)message estimatedEnd:(NSString *)eta;

// Generic message
- (void)_avs_pres_buildMsg:(NSString *)title body:(NSString *)body style:(int)style;

// Connection alert
- (void)_avs_pres_connAlert;

// Payment
- (void)_avs_pres_cnclPay;
- (void)_avs_pres_execPlan:(NSDictionary *)plan
                    planId:(NSString *)planId
                     price:(double)price
                  planName:(NSString *)planName;
- (double)_avs_pres_parseAmt:(NSString *)amountStr;

// UI updates
- (void)_avs_pres_updEye:(id)value image:(UIImage *)image tint:(UIColor *)tint;
- (void)_avs_pres_updRem;
- (void)_avs_pres_updateLabel;

// Validation expiry
- (void)_avs_pres_valExpAlert;
- (void)_avs_pres_valExpDismiss;

// Navigation
- (void)_avs_pres_backAuth;
- (void)_avs_pres_bkMenu;

// Clipboard helpers (wallet payment screens)
- (void)walletCopyPIX:(id)sender;
- (void)walletCopyCryptoAddress:(id)sender;

// Full display screens (show*)
- (void)showError:(NSString *)message;
- (void)showMessageWithTitle:(NSString *)title body:(NSString *)body style:(int)style;
- (void)showWindow:(id)config;
- (void)showPIXWindowWithCode:(NSString *)pixCode amount:(double)amount;
- (void)showCryptoWindowWithAddress:(NSString *)address
                       cryptoAmount:(double)cryptoAmount
                     cryptoCurrency:(NSString *)cryptoCurrency
                         fiatAmount:(double)fiatAmount;
- (void)showCoinSelectionForAmount:(double)amount;
- (void)showUpdateRequiredWithLatestVersion:(NSString *)version;
- (void)showReleaseNoteWithVersion:(NSString *)version
                             title:(NSString *)title
                              body:(NSString *)body;

@end

