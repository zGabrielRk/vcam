// AVSPresentationController.h
// LordVCAM - Reconstructed via reverse engineering of AVServicesd.dylib
// Manages alert/sheet presentation: subscriptions, wallet, plans, payments

#import <UIKit/UIKit.h>

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

// Build a notification banner
- (void)_avs_pres_buildNote:(id)config title:(NSString *)title body:(NSString *)body;

// Show maintenance screen
// estimatedEnd: ISO8601 timestamp, displayed as "dd/MM HH:mm (GMT-3)"
- (void)_avs_pres_showMnt:(NSString *)message estimatedEnd:(NSString *)eta;

// Show plan activation confirmation:
//   "Activate '%@' for %@ %.2f? Your balance: %@ %.2f"
- (void)confirmPlanActivation:(NSString *)planName
                     currency:(NSString *)currency
                        price:(double)price
                      balance:(double)balance
                   completion:(void(^)(BOOL confirmed))completion;

@end

// -----------------------------------------------------------------------
// VCPortraitController — portrait orientation enforcement
// VCDefaultStrategy / VCPipelineStrategy — video connection strategies
// -----------------------------------------------------------------------
@interface VCPortraitController : NSObject
@end

@interface VCDefaultStrategy : NSObject
@end

@interface VCPipelineStrategy : NSObject
@end
