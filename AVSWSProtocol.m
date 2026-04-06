// AVSWSProtocol.m
// LordVCAM — Definição das constantes de protocolo (uma cópia para toda a dylib)

#import "AVSWSProtocol.h"

NSString * const kAVSWSMsgPing       = @"ping";
NSString * const kAVSWSMsgPong       = @"pong";
NSString * const kAVSWSMsgDisconnect = @"disconnect";

// -----------------------------------------------------------------------
// VCSPKIHeaderForPublicKey: extrai chave pública e prepende ASN.1 header
// para gerar hash SPKI canônico (RFC 7469 public-key-pins)
// -----------------------------------------------------------------------
#import <Security/Security.h>
#import <CommonCrypto/CommonCrypto.h>

// ASN.1 headers para RSA 2048/4096 e EC P-256
static const uint8_t kRSA2048SPKIHeader[] = {
    0x30, 0x82, 0x01, 0x22, 0x30, 0x0d, 0x06, 0x09,
    0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01,
    0x01, 0x05, 0x00, 0x03, 0x82, 0x01, 0x0f, 0x00,
};
static const uint8_t kECDSA256SPKIHeader[] = {
    0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86,
    0x48, 0xce, 0x3d, 0x02, 0x01, 0x06, 0x08, 0x2a,
    0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03,
    0x42, 0x00,
};

NSData *VCSPKIHeaderForPublicKey(SecKeyRef publicKey) {
    if (!publicKey) return nil;

    CFDataRef keyData = SecKeyCopyExternalRepresentation(publicKey, NULL);
    if (!keyData) return nil;

    NSData *rawKey = (__bridge_transfer NSData *)keyData;
    NSMutableData *spki = [NSMutableData data];

    // Seleciona header baseado no tamanho da chave
    NSDictionary *attrs = (__bridge_transfer NSDictionary *)SecKeyCopyAttributes(publicKey);
    NSString *keyType = attrs[(__bridge NSString *)kSecAttrKeyType];

    if ([keyType isEqualToString:(__bridge NSString *)kSecAttrKeyTypeRSA]) {
        [spki appendBytes:kRSA2048SPKIHeader length:sizeof(kRSA2048SPKIHeader)];
    } else if ([keyType isEqualToString:(__bridge NSString *)kSecAttrKeyTypeECSECPrimeRandom]) {
        [spki appendBytes:kECDSA256SPKIHeader length:sizeof(kECDSA256SPKIHeader)];
    }

    [spki appendData:rawKey];
    return spki;
}
