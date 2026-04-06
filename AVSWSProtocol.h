// AVSWSProtocol.h
// LordVCAM — Constantes e utilidades do protocolo LordVCAM (compartilhado entre transportes)

#ifndef AVSWSProtocol_h
#define AVSWSProtocol_h

#ifdef __OBJC__
#import <Foundation/Foundation.h>
#endif

#include <notify.h>

// -----------------------------------------------------------------------
// Tipos de mensagem JSON do protocolo de controle
// Declarados como extern para evitar ODR violation (uma cópia por TU).
// Definidos em AVSWSProtocol.m.
// -----------------------------------------------------------------------
#ifdef __OBJC__
extern NSString * const kAVSWSMsgPing;
extern NSString * const kAVSWSMsgPong;
extern NSString * const kAVSWSMsgDisconnect;
#endif

// Porta padrão do servidor LordVCAM
static const int kAVSWSDefaultPort = 8765;

// -----------------------------------------------------------------------
// Consulta canônica de estado de lock screen.
// Usa notify_get_state (token Darwin) — mais barato que SBLockScreenManager.
// Passa NOTIFY_TOKEN_INVALID para usar o fallback via SBLockScreenManager.
// -----------------------------------------------------------------------
#ifdef __OBJC__
static inline BOOL AVSLockStateQuery(int notifyToken) {
    if (notifyToken != NOTIFY_TOKEN_INVALID) {
        uint64_t state = 0;
        notify_get_state(notifyToken, &state);
        return (state != 0);
    }
    // Fallback via SBLockScreenManager (para chamadores sem token)
    Class sbMgr = NSClassFromString(@"SBLockScreenManager");
    if (sbMgr) {
        id shared = [sbMgr performSelector:@selector(sharedInstance)];
        if (shared) return [[shared valueForKey:@"isUILocked"] boolValue];
    }
    return NO;
}
#endif

// -----------------------------------------------------------------------
// SPKI header extraction for certificate pinning.
// Prepends the standard ASN.1 header to a raw RSA/EC public key so that
// SHA256(header + publicKey) produces the canonical SPKI pin hash.
// -----------------------------------------------------------------------
NSData *VCSPKIHeaderForPublicKey(SecKeyRef publicKey);

#endif

#endif /* AVSWSProtocol_h */
