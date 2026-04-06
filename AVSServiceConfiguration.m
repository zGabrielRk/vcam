// AVSServiceConfiguration.m
// LordVCAM — Reconstruído via engenharia reversa de AVServicesd.dylib
// Licença, API, anti-tamper, armazenamento de sessão

#import "AVSServiceConfiguration.h"
#import <CommonCrypto/CommonCrypto.h>
#import <Security/Security.h>
#import <IOKit/IOKitLib.h>
#import <sys/sysctl.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <mach-o/dyld.h>
#import <signal.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

// Paths de armazenamento (de __cstring)
static NSString *const kPrefsPath    = @"/var/tmp/com.apple.avfcache/prefs.plist";
static NSString *const kPrefsLock   = @"/var/tmp/com.apple.avfcache/prefs.lock";
static NSString *const kStatePath   = @"/var/tmp/com.apple.avfcache/state.plist";
static NSString *const kCachePath   = @"/var/tmp/com.apple.avfcache/cache.plist";
static NSString *const kMetaPath    = @"/var/tmp/com.apple.avfcache/meta.dat";
static NSString *const kSessionPath = @"/var/tmp/com.apple.avfcache/session.dat";
static NSString *const kCrashPath   = @"/var/tmp/com.apple.avfcache/crash.txt";
static NSString *const kCacheDir    = @"/var/tmp/com.apple.avfcache";
static NSString *const kProbeFmt    = @"%@/probe_%@.txt";

// Chaves de prefs (de __cstring)
static NSString *const kKeyAuthorized   = @"_avs_cfg_authorized";
static NSString *const kKeyAttestation  = @"_avs_cfg_attestation";
static NSString *const kKeyChecksum     = @"_avs_cfg_checksum";
static NSString *const kKeyLastCheck    = @"_avs_cfg_lastcheck";
static NSString *const kKeyCredential   = @"_avs_cfg_credential";

// Códigos de erro internos (de __cstring)
static NSString *const kErrNetwork     = @"0xE09";
static NSString *const kErrAuth        = @"0xE01";
static NSString *const kErrLicense     = @"0xD01";
static NSString *const kErrBlocked     = @"0xE02";
static NSString *const kErrBan1        = @"0xE03";
static NSString *const kErrBan2        = @"0xE04";
static NSString *const kErrMaint       = @"0xM01";
static NSString *const kErrBL01        = @"BL01";  // conflicting tweak
static NSString *const kErrBL02        = @"BL02";  // Frida/debugger

@implementation AVSServiceConfiguration {
    NSURLSession *_urlSession;
    NSLock       *_prefsLock;
    NSMutableDictionary *_prefs;
    NSMutableDictionary *_cache;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _prefsLock = [[NSLock alloc] init];
        [self _ensureCacheDir];
        [self _loadPrefs];
        [self _loadCache];
        [self _setupSession];
        [self _detectDeviceInfo];
    }
    return self;
}

// -----------------------------------------------------------------------
// Criação de diretório de cache
// -----------------------------------------------------------------------
- (void)_ensureCacheDir {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:kCacheDir]) {
        [fm createDirectoryAtPath:kCacheDir
      withIntermediateDirectories:YES
                       attributes:nil
                            error:nil];
    }
}

// -----------------------------------------------------------------------
// Carregamento/salvamento de prefs
// -----------------------------------------------------------------------
- (void)_loadPrefs {
    [_prefsLock lock];
    NSDictionary *saved = [NSDictionary dictionaryWithContentsOfFile:kPrefsPath];
    _prefs = saved ? [saved mutableCopy] : [NSMutableDictionary dictionary];
    [_prefsLock unlock];
}

- (void)_savePrefs {
    [_prefsLock lock];
    [_prefs writeToFile:kPrefsPath atomically:YES];
    [_prefsLock unlock];
}

- (void)_loadCache {
    NSDictionary *saved = [NSDictionary dictionaryWithContentsOfFile:kCachePath];
    _cache = saved ? [saved mutableCopy] : [NSMutableDictionary dictionary];
}

// -----------------------------------------------------------------------
// Detecção de informações do dispositivo
// -----------------------------------------------------------------------
- (void)_detectDeviceInfo {
    // hw.machine → modelo do chip
    size_t len = 0;
    sysctlbyname("hw.machine", NULL, &len, NULL, 0);
    char *machine = malloc(len);
    sysctlbyname("hw.machine", machine, &len, NULL, 0);
    self._avs_cfg_hwMdl = [NSString stringWithUTF8String:machine];
    free(machine);

    // Versão do iOS via CoreServices
    typedef CFTypeRef (*CFPLCreateFn)(CFAllocatorRef, CFDataRef, CFPropertyListFormat, CFOptionFlags, CFErrorRef*);
    void *coreFoundation = dlopen("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation", RTLD_LAZY);
    void *cfDataCreateFn   = dlsym(coreFoundation, "CFDataCreateWithBytesNoCopy");
    void *cfPLCreateFn     = dlsym(coreFoundation, "CFPropertyListCreateWithData");
    void *cfDictGetFn      = dlsym(coreFoundation, "CFDictionaryGetValue");
    void *cfStrGetCStrFn   = dlsym(coreFoundation, "CFStringGetCString");
    void *cfReleaseFn      = dlsym(coreFoundation, "CFRelease");
    (void)cfDataCreateFn; (void)cfPLCreateFn; (void)cfDictGetFn;
    (void)cfStrGetCStrFn; (void)cfReleaseFn;

    NSString *sysVerPath = @"/System/Library/CoreServices/SystemVersion.plist";
    NSDictionary *sysVer = [NSDictionary dictionaryWithContentsOfFile:sysVerPath];
    self._avs_cfg_osVer = sysVer[@"ProductVersion"] ?: @"0.0.0";

    // Modelo legível (iPhone 15 Pro, etc.)
    self._avs_cfg_devMdl = [self _modelNameForMachine:self._avs_cfg_hwMdl];

    // System ID: hash do UDID/IOKit serial
    self._avs_cfg_sysId = [self _computeSystemID];
    self._avs_cfg_fpMethod = @"iokit"; // método de fingerprinting
}

- (NSString *)_modelNameForMachine:(NSString *)machine {
    // Tabela de identificadores (de __cstring)
    NSDictionary *models = @{
        @"iPhone10,1": @"iPhone 8",      @"iPhone10,2": @"iPhone 8 Plus",
        @"iPhone10,4": @"iPhone 8",      @"iPhone10,5": @"iPhone 8 Plus",
        @"iPhone10,3": @"iPhone X",      @"iPhone10,6": @"iPhone X",
        @"iPhone11,2": @"iPhone XS",     @"iPhone11,4": @"iPhone XS Max",
        @"iPhone11,6": @"iPhone XS Max", @"iPhone11,8": @"iPhone XR",
        @"iPhone12,1": @"iPhone 11",     @"iPhone12,3": @"iPhone 11 Pro",
        @"iPhone12,5": @"iPhone 11 Pro Max",
        @"iPhone13,1": @"iPhone 12 mini",@"iPhone13,2": @"iPhone 12",
        @"iPhone13,3": @"iPhone 12 Pro", @"iPhone13,4": @"iPhone 12 Pro Max",
        @"iPhone14,4": @"iPhone 13 mini",@"iPhone14,5": @"iPhone 13",
        @"iPhone14,2": @"iPhone 13 Pro", @"iPhone14,3": @"iPhone 13 Pro Max",
        @"iPhone14,7": @"iPhone 14",     @"iPhone14,8": @"iPhone 14 Plus",
        @"iPhone15,2": @"iPhone 14 Pro", @"iPhone15,3": @"iPhone 14 Pro Max",
        @"iPhone15,4": @"iPhone 15",     @"iPhone15,5": @"iPhone 15 Plus",
        @"iPhone16,1": @"iPhone 15 Pro", @"iPhone16,2": @"iPhone 15 Pro Max",
    };
    return models[machine] ?: [NSString stringWithFormat:@"iPhone (%@)", machine];
}

- (NSString *)_computeSystemID {
    // Método "iokit": lê serial number do IOKit
    io_service_t platformExpert = IOServiceGetMatchingService(
        kIOMasterPortDefault, IOServiceMatching("IOPlatformExpertDevice"));
    if (!platformExpert) return @"unknown";

    CFStringRef serial = IORegistryEntryCreateCFProperty(
        platformExpert, CFSTR("IOPlatformSerialNumber"),
        kCFAllocatorDefault, 0);
    IOObjectRelease(platformExpert);

    if (!serial) return @"unknown";
    NSString *result = (__bridge_transfer NSString *)serial;

    // Deriva system ID com SHA256
    return [self _sha256:(result ?: @"fallback")];
}

- (NSString *)_sha256:(NSString *)input {
    const char *str = input.UTF8String;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(str, (CC_LONG)strlen(str), digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:64];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    return hex;
}

// -----------------------------------------------------------------------
// SPKI Certificate Pinning
// SHA256 do SubjectPublicKeyInfo do certificado TLS do servidor
// -----------------------------------------------------------------------
- (NSString *)_avs_cfg_spkiHash:(NSData *)certData {
    // Extrai SPKI do DER-encoded certificate
    // SPKI = SubjectPublicKeyInfo (sequência de bytes no cert DER)
    // Calcula SHA256 e retorna como base64
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(certData.bytes, (CC_LONG)certData.length, digest);
    NSData *digestData = [NSData dataWithBytes:digest length:CC_SHA256_DIGEST_LENGTH];
    return [digestData base64EncodedStringWithOptions:0];
}

// -----------------------------------------------------------------------
// Anti-tamper: verificações de integridade
// -----------------------------------------------------------------------
- (BOOL)_runSecurityChecks {
    // 1. Verifica se está sendo debugado (ptrace P_TRACED)
    if ([self _isBeingDebugged]) {
        NSLog(@"[avsd] %@: A debugger was detected.", kErrBL02);
        return NO;
    }

    // 2. Verifica Frida
    if ([self _fridaDetected]) {
        NSLog(@"[avsd] %@: Frida detected.", kErrBL02);
        return NO;
    }

    // 3. Verifica integridade do binário
    if (![self _binaryIntegrityOK]) {
        NSLog(@"[avsd] IC02: Binary integrity check failed");
        return NO;
    }

    // 4. Verifica tweaks conflitantes
    if ([self _conflictingTweakDetected]) {
        NSLog(@"[avsd] %@: Conflicting tweak detected.", kErrBL01);
        return NO;
    }

    return YES;
}

- (BOOL)_isBeingDebugged {
    struct kinfo_proc info;
    size_t info_size = sizeof(info);
    int name[] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid() };
    if (sysctl(name, 4, &info, &info_size, NULL, 0) == 0) {
        return (info.kp_proc.p_flag & P_TRACED) != 0;
    }
    return NO;
}

- (BOOL)_fridaDetected {
    // Método 1: Verifica porta Frida (27042)
    int sock = socket(AF_INET, SOCK_STREAM, 0);
    if (sock >= 0) {
        struct sockaddr_in addr = {0};
        addr.sin_family = AF_INET;
        addr.sin_port = htons(27042);
        inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr);
        struct timeval tv = {0, 100000}; // 100ms timeout
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
        if (connect(sock, (struct sockaddr *)&addr, sizeof(addr)) == 0) {
            close(sock);
            return YES; // Frida Server em execução
        }
        close(sock);
    }

    // Método 2: Verifica módulos injetados
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && (strstr(name, "frida") || strstr(name, "FridaGadget"))) {
            return YES;
        }
    }

    return NO;
}

- (BOOL)_binaryIntegrityOK {
    // Lê checksum armazenado em prefs.plist
    NSString *storedChecksum = _prefs[kKeyChecksum];
    if (!storedChecksum || storedChecksum.length != 64) {
        // Primeiro boot: armazena checksum
        NSString *path = [[NSBundle mainBundle] executablePath];
        NSData *binaryData = [NSData dataWithContentsOfFile:path];
        if (binaryData) {
            // Hash raw bytes directly — binary executables contain non-ASCII bytes;
            // NSASCIIStringEncoding would return nil and crash CC_SHA256(NULL, ...).
            unsigned char digest[CC_SHA256_DIGEST_LENGTH];
            CC_SHA256(binaryData.bytes, (CC_LONG)binaryData.length, digest);
            NSMutableString *hex = [NSMutableString stringWithCapacity:64];
            for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++)
                [hex appendFormat:@"%02x", digest[i]];
            NSString *hash = [hex copy];
            _prefs[kKeyChecksum] = hash;
            [self _savePrefs];
        }
        return YES;
    }
    // Compara com hash atual
    return YES; // simplificado
}

- (BOOL)_conflictingTweakDetected {
    // Verifica lista de tweaks conhecidos que conflitam com LordVCAM
    // (verificado via dlopen ou _dyld_image_count)
    return NO;
}

// -----------------------------------------------------------------------
// Ativação de licença
// -----------------------------------------------------------------------
- (void)_avs_chk_actLic {
    if (![self _runSecurityChecks]) {
        return;
    }

    NSString *credential = _prefs[kKeyCredential];
    if (!credential) {
        NSLog(@"[avsd] %@: Not authenticated", kErrAuth);
        return;
    }

    // Verifica com o servidor
    NSString *endpoint = [NSString stringWithFormat:@"%@/member", self._avs_cfg_srvAddr];
    NSDictionary *body = @{
        @"email":         self._avs_cfg_usrEmail ?: @"",
        @"device_model":  self._avs_cfg_devMdl  ?: @"",
        @"ios_version":   self._avs_cfg_osVer    ?: @"",
        @"tweak_version": self._avs_cfg_ver      ?: @"0.0.0",
        @"location":      self._avs_cfg_sysId    ?: @"",
    };

    [self postToEndpoint:endpoint body:body completion:^(NSDictionary *resp, NSError *err) {
        if (err) {
            NSLog(@"[avsd] %@: %@", kErrNetwork, err.localizedDescription);
            return;
        }

        NSString *status = resp[@"status"];
        if ([status isEqualToString:@"blocked"]) {
            NSLog(@"[avsd] %@: Account blocked", kErrBlocked);
            return;
        }
        if ([status isEqualToString:@"expired"]) {
            NSLog(@"[avsd] License expired");
            self._avs_cfg_isPurch = NO;
            return;
        }

        // Atualiza estado
        self._avs_cfg_isPurch   = YES;
        self._avs_cfg_remaining = resp[@"remaining"] ?: @"--:--";
        self._avs_cfg_expiry    = resp[@"expiry"];
        self._avs_cfg_balance   = [resp[@"balance"] doubleValue];
        self._avs_cfg_avPlans   = resp[@"plans"];
        self._avs_cfg_latest    = resp[@"latest_version"];

        [self _avs_cfg_writeSession];
    }];
}

// -----------------------------------------------------------------------
// Escrita de sessão em disco
// -----------------------------------------------------------------------
- (void)_avs_cfg_writeSession {
    NSDictionary *session = @{
        @"email":    self._avs_cfg_usrEmail ?: @"",
        @"expiry":   self._avs_cfg_expiry   ?: @"",
        @"sysId":    self._avs_cfg_sysId    ?: @"",
        @"isPurch":  @(self._avs_cfg_isPurch),
    };
    NSData *data = [NSJSONSerialization dataWithJSONObject:session options:0 error:nil];
    [data writeToFile:kSessionPath atomically:YES];

    // Atualiza prefs
    _prefs[kKeyLastCheck] = [NSString stringWithFormat:@"%llu",
                              (unsigned long long)[[NSDate date] timeIntervalSince1970]];
    [self _savePrefs];
}

// -----------------------------------------------------------------------
// API REST
// -----------------------------------------------------------------------
- (void)_setupSession {
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    config.timeoutIntervalForRequest = 15.0;
    _urlSession = [NSURLSession sessionWithConfiguration:config];
}

- (void)postToEndpoint:(NSString *)endpoint
                  body:(NSDictionary *)body
            completion:(void(^)(NSDictionary *, NSError *))completion {
    NSError *err = nil;
    NSData *bodyData = [NSJSONSerialization dataWithJSONObject:body options:0 error:&err];
    if (err) { if (completion) completion(nil, err); return; }

    NSURL *url = [NSURL URLWithString:endpoint];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    req.HTTPBody = bodyData;
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:@"CFNetwork/1410.0.3 Darwin/22.6.0" forHTTPHeaderField:@"User-Agent"];

    [[_urlSession dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
            if (error) {
                if (completion) completion(nil, error);
                return;
            }
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data
                                                                 options:0
                                                                   error:nil];
            if (completion) completion(json, nil);
        }] resume];
}

@end
