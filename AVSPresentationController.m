// AVSPresentationController.m
// LordVCAM — Reconstruído via engenharia reversa de AVServicesd.dylib
// Gerencia todos os alertas, pagamentos PIX/Crypto, planos, wallet

#import "AVSPresentationController.h"
#import "AVSServiceConfiguration.h"
#import <UIKit/UIKit.h>
#import <CoreImage/CoreImage.h>
#import <CommonCrypto/CommonCrypto.h>

@implementation AVSPresentationController {
    AVSServiceConfiguration *_config;
    NSTimer *_pixPollTimer;
    NSString *_currentPixPaymentId;
    NSString *_currentCryptoAddr;
}

- (instancetype)initWithConfig:(AVSServiceConfiguration *)config {
    self = [super init];
    if (self) {
        _config = config;
    }
    return self;
}

// -----------------------------------------------------------------------
// Tela de Login / Registro
// Email + Password + [Login] [Create]
// -----------------------------------------------------------------------
- (void)presentLoginScreen:(UIViewController *)parent {
    UIAlertController *alert = [UIAlertController
                                alertControllerWithTitle:@"LordVCAM"
                                message:nil
                                preferredStyle:UIAlertControllerStyleAlert];

    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"email@example.com";
        tf.keyboardType = UIKeyboardTypeEmailAddress;
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
        tf.tag = 0; // EMAIL
    }];

    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"Password";
        tf.secureTextEntry = YES;
        tf.tag = 1; // PASSWORD
    }];

    UIAlertAction *loginAct = [UIAlertAction
                               actionWithTitle:@" Login"
                               style:UIAlertActionStyleDefault
                               handler:^(UIAlertAction *a) {
        NSString *email = alert.textFields[0].text;
        NSString *pass  = alert.textFields[1].text;
        [self _performLogin:email password:pass];
    }];

    UIAlertAction *createAct = [UIAlertAction
                                actionWithTitle:@" Create"
                                style:UIAlertActionStyleDefault
                                handler:^(UIAlertAction *a) {
        NSString *email = alert.textFields[0].text;
        NSString *pass  = alert.textFields[1].text;
        [self _performRegister:email password:pass];
    }];

    UIAlertAction *cancelAct = [UIAlertAction actionWithTitle:@"Cancel"
                                                        style:UIAlertActionStyleCancel
                                                      handler:nil];

    [alert addAction:loginAct];
    [alert addAction:createAct];
    [alert addAction:cancelAct];
    [parent presentViewController:alert animated:YES completion:nil];
}

- (void)_performLogin:(NSString *)email password:(NSString *)password {
    if (!email.length || !password.length) {
        NSLog(@"[avsd] Please fill in all fields");
        return;
    }

    NSString *endpoint = [NSString stringWithFormat:@"%@/auth/login", _config._avs_cfg_srvAddr];
    NSDictionary *body = @{
        @"email":    email,
        @"password": password,
        @"device_model":  _config._avs_cfg_devMdl ?: @"",
        @"ios_version":   _config._avs_cfg_osVer   ?: @"",
        @"tweak_version": _config._avs_cfg_ver      ?: @"",
    };

    [_config postToEndpoint:endpoint body:body completion:^(NSDictionary *resp, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (err) {
                NSLog(@"[avsd] 0xE09: %@", err.localizedDescription);
                return;
            }

            NSString *status = resp[@"status"];
            if ([status isEqualToString:@"blocked"]) {
                NSLog(@"[avsd] 0xE02: blocked");
                return;
            }
            if ([status isEqualToString:@"expired"]) {
                NSLog(@"[avsd] expired");
                return;
            }
            if ([status isEqualToString:@"invalid"]) {
                NSLog(@"[avsd] 0xE05: invalid credentials");
                return;
            }

            // Sucesso
            _config._avs_cfg_usrEmail = email;
            _config._avs_cfg_isPurch = YES;
            [_config _avs_cfg_writeSession];
        });
    }];
}

- (void)_performRegister:(NSString *)email password:(NSString *)password {
    if (!email.length || !password.length) {
        NSLog(@"[avsd] Please fill in all fields");
        return;
    }
    if (password.length < 6) {
        NSLog(@"[avsd] Password must be at least 6 characters");
        return;
    }

    NSString *endpoint = [NSString stringWithFormat:@"%@/auth/register", _config._avs_cfg_srvAddr];
    NSDictionary *body = @{@"email": email, @"password": password};
    [_config postToEndpoint:endpoint body:body completion:^(NSDictionary *resp, NSError *err) {
        // Handle response
    }];
}

// -----------------------------------------------------------------------
// Wallet: saldo + recarga
// -----------------------------------------------------------------------
- (void)presentWallet:(UIViewController *)parent {
    NSString *currency = _config._avs_cfg_srvAddr ?: @"BRL";
    double balance = _config._avs_cfg_balance;

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:[NSString stringWithFormat:@"Wallet"]
        message:[NSString stringWithFormat:@"%@ %.2f", currency, balance]
        preferredStyle:UIAlertControllerStyleActionSheet];

    UIAlertAction *rechargeAct = [UIAlertAction
        actionWithTitle:@" RECHARGE"
        style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *a) {
            [self presentRechargeScreen:parent];
        }];

    UIAlertAction *plansAct = [UIAlertAction
        actionWithTitle:@"Available Plans"
        style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *a) {
            [self presentPlans:parent];
        }];

    UIAlertAction *cancelAct = [UIAlertAction actionWithTitle:@"Cancel"
                                                        style:UIAlertActionStyleCancel
                                                      handler:nil];
    [alert addAction:rechargeAct];
    [alert addAction:plansAct];
    [alert addAction:cancelAct];
    [parent presentViewController:alert animated:YES completion:nil];
}

// -----------------------------------------------------------------------
// Recarga: PIX ou Crypto
// "Minimum PIX: R$ 10.00 | Crypto: $ 10.00"
// -----------------------------------------------------------------------
- (void)presentRechargeScreen:(UIViewController *)parent {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:[NSString stringWithFormat:@"Recharge Wallet (%@ %.2f)",
                                  @"BRL", _config._avs_cfg_balance]
        message:@"Minimum PIX: R$ 10.00 | Crypto: $ 10.00"
        preferredStyle:UIAlertControllerStyleAlert];

    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"Amount";
        tf.keyboardType = UIKeyboardTypeDecimalPad;
    }];

    UIAlertAction *pixAct = [UIAlertAction
        actionWithTitle:@"PIX (BRL)"
        style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *a) {
            double amount = [alert.textFields.firstObject.text doubleValue];
            if (amount < 10.0) {
                NSLog(@"[avsd] Minimum PIX recharge is R$ 10.00");
                return;
            }
            [self _createPixPayment:amount parent:parent];
        }];

    UIAlertAction *cryptoAct = [UIAlertAction
        actionWithTitle:@"Crypto (USD)"
        style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *a) {
            double amount = [alert.textFields.firstObject.text doubleValue];
            if (amount < 10.0) {
                NSLog(@"[avsd] Minimum crypto recharge is $ 10.00");
                return;
            }
            [self _selectCryptoNetwork:amount parent:parent];
        }];

    UIAlertAction *cancelAct = [UIAlertAction actionWithTitle:@"Cancel"
                                                        style:UIAlertActionStyleCancel
                                                      handler:nil];
    [alert addAction:pixAct];
    [alert addAction:cryptoAct];
    [alert addAction:cancelAct];
    [parent presentViewController:alert animated:YES completion:nil];
}

// -----------------------------------------------------------------------
// PIX: gera código e QR, faz polling de status
// -----------------------------------------------------------------------
- (void)_createPixPayment:(double)amount parent:(UIViewController *)parent {
    NSString *endpoint = [NSString stringWithFormat:@"%@/payments/pix",
                          _config._avs_cfg_srvAddr];
    NSDictionary *body = @{
        @"amount":   @(amount),
        @"email":    _config._avs_cfg_usrEmail ?: @"",
        @"currency": @"BRL",
    };

    [_config postToEndpoint:endpoint body:body completion:^(NSDictionary *resp, NSError *err) {
        if (err) { NSLog(@"[avsd] Failed to create payment"); return; }

        NSString *pixCode = resp[@"code"];
        NSString *paymentId = resp[@"id"];
        if (!pixCode) { NSLog(@"[avsd] Failed to generate PIX code"); return; }

        _currentPixPaymentId = paymentId;

        dispatch_async(dispatch_get_main_queue(), ^{
            [self _showPixQR:pixCode amount:amount parent:parent paymentId:paymentId];
        });
    }];
}

- (void)_showPixQR:(NSString *)pixCode amount:(double)amount
            parent:(UIViewController *)parent paymentId:(NSString *)paymentId {
    // Gera QR Code via CIQRCodeGenerator
    CIFilter *qrFilter = [CIFilter filterWithName:@"CIQRCodeGenerator"];
    [qrFilter setValue:[pixCode dataUsingEncoding:NSUTF8StringEncoding] forKey:@"inputMessage"];
    [qrFilter setValue:@"H" forKey:@"inputCorrectionLevel"];
    CIImage *qrImage = qrFilter.outputImage;

    // Escala QR
    CGFloat scale = 5.0;
    CIImage *scaled = [qrImage imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
    UIImage *qrUIImage = [UIImage imageWithCIImage:scaled];

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"PIX Copy and Paste:"
        message:[NSString stringWithFormat:@"%.2f", amount]
        preferredStyle:UIAlertControllerStyleAlert];

    // Botão copiar código PIX
    UIAlertAction *copyAct = [UIAlertAction
        actionWithTitle:@" Copy PIX Code"
        style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *a) {
            [UIPasteboard generalPasteboard].string = pixCode;
            NSLog(@"[avsd] PIX code copied");
        }];

    UIAlertAction *cancelAct = [UIAlertAction
        actionWithTitle:@"xmark.circle"
        style:UIAlertActionStyleDestructive
        handler:^(UIAlertAction *a) {
            [self _stopPixPolling];
        }];

    [alert addAction:copyAct];
    [alert addAction:cancelAct];
    [parent presentViewController:alert animated:YES completion:nil];

    // Inicia polling de status (a cada 5s)
    [self _startPixPolling:paymentId amount:amount presenter:parent];
}

- (void)_startPixPolling:(NSString *)paymentId amount:(double)amount
               presenter:(UIViewController *)parent {
    _pixPollTimer = [NSTimer scheduledTimerWithTimeInterval:5.0 repeats:YES block:^(NSTimer *t) {
        NSString *endpoint = [NSString stringWithFormat:@"%@/payments/%@/status",
                              _config._avs_cfg_srvAddr, paymentId];
        [_config postToEndpoint:endpoint body:@{} completion:^(NSDictionary *resp, NSError *err) {
            NSString *status = resp[@"status"];
            dispatch_async(dispatch_get_main_queue(), ^{
                if ([status isEqualToString:@"paid"]) {
                    [self _stopPixPolling];
                    [parent dismissViewControllerAnimated:YES completion:nil];
                    double newBalance = [resp[@"balance"] doubleValue];
                    // "Payment Confirmed! %@ %.2f added. New balance: %@ %.2f"
                    NSLog(@"[avsd] Payment confirmed! Balance: %.2f", newBalance);
                    _config._avs_cfg_balance = newBalance;
                } else if ([status isEqualToString:@"expired"]) {
                    // "Your PIX of %@ %.2f has expired."
                    [self _stopPixPolling];
                    NSLog(@"[avsd] PIX expired");
                } else if ([status isEqualToString:@"cancelled"]) {
                    [self _stopPixPolling];
                    NSLog(@"[avsd] Payment cancelled");
                }
                // status "ordered" = aguardando
            });
        }];
    }];
}

- (void)_stopPixPolling {
    [_pixPollTimer invalidate];
    _pixPollTimer = nil;
}

// -----------------------------------------------------------------------
// Crypto: seleciona rede e endereço
// Redes: USDT BEP20, USDT Polygon, USDT Base, USDT Sol, USDC Sol, LTC
// -----------------------------------------------------------------------
- (void)_selectCryptoNetwork:(double)amount parent:(UIViewController *)parent {
    // Busca redes disponíveis do servidor
    NSString *endpoint = [NSString stringWithFormat:@"%@/payments/crypto-currencies?amount=%.2f",
                          _config._avs_cfg_srvAddr, amount];

    [_config postToEndpoint:endpoint body:@{} completion:^(NSDictionary *resp, NSError *err) {
        if (err) { NSLog(@"[avsd] Network error"); return; }

        NSArray *currencies = resp[@"currencies"];
        if (!currencies.count) {
            NSLog(@"[avsd] No crypto payment networks available.");
            return;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            UIAlertController *netAlert = [UIAlertController
                alertControllerWithTitle:@"Select Network"
                message:[NSString stringWithFormat:@"Amount: $ %.2f", amount]
                preferredStyle:UIAlertControllerStyleActionSheet];

            // Redes padrão (de __cstring):
            NSDictionary *networkNames = @{
                @"usdt_bep20":  @"USDT BEP20 (BSC)",
                @"usdt_polygon":@"USDT Polygon",
                @"usdt_base":   @"USDT Base",
                @"usdt_sol":    @"USDT Solana (SOL)",
                @"usdc_sol":    @"USDC Solana",
                @"ltc":         @"Litecoin",
            };

            for (NSDictionary *curr in currencies) {
                NSString *code = curr[@"code"] ?: curr[@"network"];
                NSString *name = networkNames[code] ?: code;
                [netAlert addAction:[UIAlertAction
                    actionWithTitle:name
                    style:UIAlertActionStyleDefault
                    handler:^(UIAlertAction *a) {
                        [self _createCryptoPayment:amount network:code parent:parent];
                    }]];
            }

            [netAlert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                                         style:UIAlertActionStyleCancel
                                                       handler:nil]];
            [parent presentViewController:netAlert animated:YES completion:nil];
        });
    }];
}

- (void)_createCryptoPayment:(double)amount network:(NSString *)network
                      parent:(UIViewController *)parent {
    NSLog(@"[avsd] Creating Payment...");

    NSString *endpoint = [NSString stringWithFormat:@"%@/payments/crypto",
                          _config._avs_cfg_srvAddr];
    NSDictionary *body = @{@"amount": @(amount), @"network": network};

    [_config postToEndpoint:endpoint body:body completion:^(NSDictionary *resp, NSError *err) {
        if (err) { NSLog(@"[avsd] Failed to create crypto payment"); return; }

        NSString *address = resp[@"address"];
        if (!address) { NSLog(@"[avsd] Failed to get crypto address"); return; }

        _currentCryptoAddr = address;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self _showCryptoAddress:address amount:amount network:network parent:parent];
        });
    }];
}

- (void)_showCryptoAddress:(NSString *)address amount:(double)amount
                   network:(NSString *)network parent:(UIViewController *)parent {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Send to address:"
        message:[NSString stringWithFormat:@"$ %.2f\n%@", amount, address]
        preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:[UIAlertAction
        actionWithTitle:@" Copy Address"
        style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *a) {
            [UIPasteboard generalPasteboard].string = address;
        }]];

    [alert addAction:[UIAlertAction
        actionWithTitle:@"Confirm"
        style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *a) {
            // Poll para confirmar pagamento crypto
        }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                             style:UIAlertActionStyleCancel
                                           handler:nil]];
    [parent presentViewController:alert animated:YES completion:nil];
}

// -----------------------------------------------------------------------
// Planos de assinatura
// -----------------------------------------------------------------------
- (void)presentPlans:(UIViewController *)parent {
    NSArray *plans = _config._avs_cfg_avPlans;
    if (!plans.count) {
        NSLog(@"[avsd] No plans available");
        return;
    }

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Available Plans"
        message:[NSString stringWithFormat:@"Balance: BRL %.2f", _config._avs_cfg_balance]
        preferredStyle:UIAlertControllerStyleActionSheet];

    for (NSDictionary *plan in plans) {
        NSString *name     = plan[@"name"] ?: @"Plan";
        double    price    = [plan[@"price"] doubleValue];
        NSString *duration = plan[@"duration_value"] ?
            [NSString stringWithFormat:@"%@ %@", plan[@"duration_value"], plan[@"duration_unit"]] :
            @"";

        [alert addAction:[UIAlertAction
            actionWithTitle:[NSString stringWithFormat:@"%@ - BRL %.2f (%@)", name, price, duration]
            style:UIAlertActionStyleDefault
            handler:^(UIAlertAction *a) {
                [self confirmPlanActivation:name currency:@"BRL" price:price
                                    balance:_config._avs_cfg_balance
                                 completion:^(BOOL confirmed) {
                    if (confirmed) [self _activatePlan:plan];
                }];
            }]];
    }

    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                             style:UIAlertActionStyleCancel
                                           handler:nil]];
    [parent presentViewController:alert animated:YES completion:nil];
}

- (void)confirmPlanActivation:(NSString *)planName
                     currency:(NSString *)currency
                        price:(double)price
                      balance:(double)balance
                   completion:(void(^)(BOOL))completion {
    if (balance < price) {
        // "Insufficient Balance"
        NSLog(@"[avsd] Insufficient Balance: %.2f < %.2f", balance, price);
        if (completion) completion(NO);
        return;
    }

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Confirm Plan"
        message:[NSString stringWithFormat:@"Activate \"%@\" for %@ %.2f?\n\nYour balance: %@ %.2f",
                 planName, currency, price, currency, balance]
        preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:[UIAlertAction
        actionWithTitle:@"Activate"
        style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *a) { if (completion) completion(YES); }]];

    [alert addAction:[UIAlertAction
        actionWithTitle:@"Cancel"
        style:UIAlertActionStyleCancel
        handler:^(UIAlertAction *a) { if (completion) completion(NO); }]];

    // Apresenta sobre view controller do topo
    UIViewController *topVC = [UIApplication sharedApplication].keyWindow.rootViewController;
    [topVC presentViewController:alert animated:YES completion:nil];
}

- (void)_activatePlan:(NSDictionary *)plan {
    NSLog(@"[avsd] Purchasing...");
    NSString *endpoint = [NSString stringWithFormat:@"%@/plans/activate", _config._avs_cfg_srvAddr];
    NSDictionary *body = @{
        @"plan_id": plan[@"id"] ?: @"",
        @"email":   _config._avs_cfg_usrEmail ?: @"",
    };
    [_config postToEndpoint:endpoint body:body completion:^(NSDictionary *resp, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (err || !resp) {
                NSLog(@"[avsd] Failed: %@", err.localizedDescription);
                return;
            }
            NSLog(@"[avsd] Activated!");
            _config._avs_cfg_isPurch = YES;
            _config._avs_cfg_balance -= [plan[@"price"] doubleValue];
        });
    }];
}

// -----------------------------------------------------------------------
// Manutenção
// -----------------------------------------------------------------------
- (void)_avs_pres_buildNote:(id)config title:(NSString *)title body:(NSString *)body {
    NSLog(@"[avsd] Notification: %@ — %@", title, body);
}

- (void)_avs_pres_showMnt:(NSString *)message estimatedEnd:(NSString *)eta {
    // Exibe alerta de manutenção programada
    // "Scheduled Downtime"
    // "ESTIMATED END: %@ (GMT-3)"
    // "Active subscriptions receive time credit for the downtime period."
    NSLog(@"[avsd] Maintenance: %@ ETA: %@", message, eta);
}

@end
