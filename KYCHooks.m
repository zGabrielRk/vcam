// KYCHooks.m
// LordVCAM — Reconstruído via engenharia reversa de AVServicesd.dylib
// Entry point do tweak: hooks via CydiaSubstrate em mediaserverd e SpringBoard

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <substrate.h>
#import <dlfcn.h>
#import <signal.h>
#import <execinfo.h>
#import <mach/mach.h>

#import "AVSFrameCoordinator.h"
#import "AVSRenderPipeline.h"
#import "AVSMediaDecoder.h"
#import "AVSAudioBridge.h"
#import "AVSPreferencePanel.h"
#import "AVSWSProtocol.h"

// Singleton global do coordinator
static AVSFrameCoordinator *gCoordinator = nil;
static AVSPreferencePanel  *gPanel       = nil;

// -----------------------------------------------------------------------
// Ponteiros originais de funções hookadas
// -----------------------------------------------------------------------

// BWNodeOutput
static void (*orig_BWNodeOutput_dealloc)(id self, SEL _cmd);

// AVCaptureConnection - método principal de entrega de frame
typedef void (*CopyNextFrameFunc)(id, SEL, CMSampleBufferRef, int);
static CopyNextFrameFunc orig_copyNextFrame = NULL;

// FigCaptureClientSessionMonitor
typedef id (*SessionMonitorInitFunc)(id, SEL);
static SessionMonitorInitFunc orig_sessionMonitorInit = NULL;

// AVCapturePhotoOutput
typedef void (*PhotoOutputFunc)(id, SEL, id, id);
static PhotoOutputFunc orig_photoOutput = NULL;

// -----------------------------------------------------------------------
// Crash handler: captura SIGSEGV/SIGBUS/SIGFPE
// Escreve em /var/tmp/com.apple.avfcache/crash.txt
// -----------------------------------------------------------------------
static void avs_signal_handler(int signum, siginfo_t *info, void *context) {
    const char *sigName;
    switch (signum) {
        case SIGSEGV: sigName = "SIGSEGV"; break;
        case SIGBUS:  sigName = "SIGBUS";  break;
        case SIGFPE:  sigName = "SIGFPE";  break;
        default:      sigName = "UNKNOWN"; break;
    }

    ucontext_t *uc = (ucontext_t *)context;
    void *pc = (void *)__darwin_arm_thread_state64_get_pc(uc->uc_mcontext->__ss);
    void *lr = (void *)__darwin_arm_thread_state64_get_lr(uc->uc_mcontext->__ss);
    void *fp = (void *)__darwin_arm_thread_state64_get_fp(uc->uc_mcontext->__ss);

    // Symbolicate PC
    Dl_info pcInfo = {0}, lrInfo = {0};
    dladdr(pc, &pcInfo);
    dladdr(lr, &lrInfo);

    // Stack trace
    void *frames[32];
    int frameCount = backtrace(frames, 32);
    char **symbols = backtrace_symbols(frames, frameCount);

    // Monta log
    NSMutableString *log = [NSMutableString string];
    [log appendFormat:@"AVServicesd\n"];
    [log appendFormat:@" Signal %s (%d)\n", sigName, signum];
    [log appendFormat:@"Signal %s at address %p\n\n", sigName, info->si_addr];
    [log appendFormat:@"PC=0x%llx (%s+0x%llx) LR=0x%llx (%s+0x%llx) FP=0x%llx\n",
        (uint64_t)pc,
        pcInfo.dli_sname ?: "?",
        (uint64_t)pc - (uint64_t)pcInfo.dli_saddr,
        (uint64_t)lr,
        lrInfo.dli_sname ?: "?",
        (uint64_t)lr - (uint64_t)lrInfo.dli_saddr,
        (uint64_t)fp
    ];

    // Registros ARM64
    uint64_t *x = (uint64_t *)&uc->uc_mcontext->__ss.__x[0];
    [log appendFormat:@"  x0=0x%llx x1=0x%llx x2=0x%llx x3=0x%llx\n", x[0],x[1],x[2],x[3]];
    [log appendFormat:@"  x19=0x%llx x20=0x%llx x21=0x%llx x22=0x%llx\n\n", x[19],x[20],x[21],x[22]];

    [log appendFormat:@"Stack:\n"];
    for (int i = 0; i < frameCount; i++) {
        Dl_info fi = {0};
        dladdr(frames[i], &fi);
        if (fi.dli_sname) {
            [log appendFormat:@"  %d: %s + %ld\n", i, fi.dli_sname,
                (long)((uint64_t)frames[i] - (uint64_t)fi.dli_saddr)];
        } else {
            [log appendFormat:@"  %d: %p\n", i, frames[i]];
        }
    }
    free(symbols);

    // Escreve em disco
    [log writeToFile:@"/var/tmp/com.apple.avfcache/crash.txt"
          atomically:NO
            encoding:NSUTF8StringEncoding
               error:nil];

    // Re-raise para crash nativo
    signal(signum, SIG_DFL);
    raise(signum);
}

static void avs_setup_crash_handler(void) {
    struct sigaction sa = {0};
    sa.sa_sigaction = avs_signal_handler;
    sa.sa_flags = SA_SIGINFO | SA_RESETHAND;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGBUS,  &sa, NULL);
    sigaction(SIGFPE,  &sa, NULL);
}

// -----------------------------------------------------------------------
// Hook: BWNodeOutput - ponto de injeção na pipeline de câmera
// BWNodeOutput é o nó de saída do grafo de captura em mediaserverd
// -----------------------------------------------------------------------
static void hook_BWNodeOutput_dealloc(id self, SEL _cmd) {
    NSLog(@"[avsd] BWNodeOutput dealloc");
    orig_BWNodeOutput_dealloc(self, _cmd);
}

// Hook no método de output do BWNodeOutput que entrega frames
// Assinatura: -[BWNodeOutput copyNextSampleBuffer]
static CMSampleBufferRef (*orig_BWNodeOutput_copyNextSampleBuffer)(id, SEL);
static CMSampleBufferRef hook_BWNodeOutput_copyNextSampleBuffer(id self, SEL _cmd) {
    CMSampleBufferRef orig = orig_BWNodeOutput_copyNextSampleBuffer(self, _cmd);
    if (!gCoordinator) return orig;

    // injectReplacementForFrame: é thread-safe (usa _frameLock internamente)
    CMSampleBufferRef replacement = [gCoordinator injectReplacementForFrame:orig];
    if (replacement == orig) return orig;

    if (orig) CFRelease(orig);
    return replacement; // já retido por injectReplacementForFrame:
}

// -----------------------------------------------------------------------
// Hook: AVCaptureConnection - injeção de frame em apps com câmera
//
// Log de injeção (de __cstring):
//   [avsd] [WK] #N SKIP double-inj WxH      → já injetado, pula
//   [avsd] [WK] #N ORIG (no source) WxH     → sem fonte, passa original
//   [avsd] [WK] #N ORIG (no rotatedPB yet)  → sem frame rotacionado ainda
//   [avsd] [WK] #N NO-PROCESSED (raw) WxH   → modo raw sem processamento
//   [avsd-AUDIT] #N dst path=VT             → fast path via VideoToolbox
//   [avsd] [WK] #N SLOW-PATH               → software fallback
//   [avsd-CACHE-AUDIT] #N dst cache front   → auditoria de cache
// -----------------------------------------------------------------------

// Contadores de injeção por sessão
static int gFrameCounter = 0;

// Hook no callback de entrega de frame ao app
typedef void (*SampleBufferDelegateFunc)(id, SEL, id, CMSampleBufferRef, id);
static SampleBufferDelegateFunc orig_captureOutput_didOutputSampleBuffer;

static void hook_captureOutput_didOutputSampleBuffer(
    id self, SEL _cmd,
    id captureOutput,
    CMSampleBufferRef sampleBuffer,
    id connection
) {
    if (!gCoordinator || !gCoordinator._avs_cfg_replOn) {
        orig_captureOutput_didOutputSampleBuffer(self, _cmd, captureOutput, sampleBuffer, connection);
        return;
    }

    gFrameCounter++;
    int n = gFrameCounter;

    // Verifica double-injection (se já foi marcado como injetado)
    // CMSampleBufferGetAttachmentArray detecta marcador "_avs_inj"
    CMAttachmentBearerRef bearer = (CMAttachmentBearerRef)sampleBuffer;
    CFTypeRef injMark = CMGetAttachment(bearer, CFSTR("_avs_inj"), NULL);
    if (injMark) {
        size_t w = CVPixelBufferGetWidth(CMSampleBufferGetImageBuffer(sampleBuffer));
        size_t h = CVPixelBufferGetHeight(CMSampleBufferGetImageBuffer(sampleBuffer));
        NSLog(@"[avsd] [WK] #%d SKIP double-inj %zux%zu", n, w, h);
        orig_captureOutput_didOutputSampleBuffer(self, _cmd, captureOutput, sampleBuffer, connection);
        return;
    }

    // Obtém frame substituto de forma thread-safe
    CMSampleBufferRef replacement = [gCoordinator injectReplacementForFrame:sampleBuffer];
    if (replacement == sampleBuffer) {
        CVImageBufferRef imgBuf = CMSampleBufferGetImageBuffer(sampleBuffer);
        size_t w = CVPixelBufferGetWidth(imgBuf);
        size_t h = CVPixelBufferGetHeight(imgBuf);
        NSLog(@"[avsd] [WK] #%d ORIG (no source at all) %zux%zu", n, w, h);
        orig_captureOutput_didOutputSampleBuffer(self, _cmd, captureOutput, sampleBuffer, connection);
        return;
    }

    CVImageBufferRef dstImg = CMSampleBufferGetImageBuffer(sampleBuffer);
    CVImageBufferRef srcImg = CMSampleBufferGetImageBuffer(replacement);

    size_t dstW = CVPixelBufferGetWidth(dstImg);
    size_t dstH = CVPixelBufferGetHeight(dstImg);
    size_t srcW = CVPixelBufferGetWidth(srcImg);

    // Fast path: VT (VideoToolbox) para escalar/converter
    // [avsd-AUDIT] #N dst=WxH(ar) src=WxH(ar) crop=N% front=N path=VT
    float dstAR = (float)dstW / dstH;
    float srcAR = (float)srcW / CVPixelBufferGetHeight(srcImg);
    BOOL isFront = NO; // detectado via AVCaptureDevicePosition
    NSLog(@"[avsd-AUDIT] #%d dst=%zux%zu(%.2f) src=%zux%zu(%.2f) crop=%.0f%% front=%d path=VT",
          n, dstW, dstH, dstAR, srcW, CVPixelBufferGetHeight(srcImg), srcAR,
          100.0f * MIN(dstAR/srcAR, srcAR/dstAR), isFront ? 1 : 0);

    // Marca como injetado
    CMSetAttachment(bearer, CFSTR("_avs_inj"), kCFBooleanTrue,
                    kCMAttachmentMode_ShouldPropagate);

    // Entrega frame substituto
    orig_captureOutput_didOutputSampleBuffer(self, _cmd, captureOutput, replacement, connection);
}

// -----------------------------------------------------------------------
// Hook: FigCaptureClientSessionMonitor - monitora sessões de captura
// -----------------------------------------------------------------------
static id hook_FigCaptureClientSessionMonitor_init(id self, SEL _cmd) {
    id result = orig_sessionMonitorInit(self, _cmd);
    NSLog(@"[avsd-KYC] KYCSession initialized (FigCaptureClientSessionMonitor)");
    return result;
}

// -----------------------------------------------------------------------
// Hook: _addAuxImagesIfNeededForEncodingScheme - injeção em fotos
// -----------------------------------------------------------------------
typedef void (*AddAuxImagesFunc)(id, SEL, int, CMSampleBufferRef, id, id, id);
static AddAuxImagesFunc orig_addAuxImages;
static void hook_addAuxImages(id self, SEL _cmd, int scheme,
                               CMSampleBufferRef sampleBuf, id meta,
                               id settings, id flags) {
    // Se replacement ativo, substitui o sample buffer antes de encodar
    if (gCoordinator) {
        CMSampleBufferRef replacement = [gCoordinator injectReplacementForFrame:sampleBuf];
        if (replacement != sampleBuf) sampleBuf = replacement;
    }
    orig_addAuxImages(self, _cmd, scheme, sampleBuf, meta, settings, flags);
}

// -----------------------------------------------------------------------
// Notification handler: UIApplicationDidFinishLaunching
// Disparado em SpringBoard para setup da UI flutuante
// -----------------------------------------------------------------------
static void handleApplicationLaunched(CFNotificationCenterRef center,
                                       void *observer,
                                       CFStringRef name,
                                       const void *object,
                                       CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        gCoordinator = [[AVSFrameCoordinator alloc] init];
        gPanel  = [[AVSPreferencePanel alloc] init];
        gPanel.coordinator = gCoordinator;
        [gPanel setupWindows];
        NSLog(@"[avsd] SpringBoard UI initialized");
    });
}

// -----------------------------------------------------------------------
// Notification handler: lock state (com.apple.springboard.lockstate)
// -----------------------------------------------------------------------
static void handleLockStateChange(CFNotificationCenterRef center,
                                   void *observer,
                                   CFStringRef name,
                                   const void *object,
                                   CFDictionaryRef userInfo) {
    BOOL isLocked = AVSLockStateQuery(NOTIFY_TOKEN_INVALID);

    gPanel._isScreenLocked = isLocked;
    if (isLocked) {
        [gPanel forceHideOnLock];
    }
}

// -----------------------------------------------------------------------
// Probe: escreve arquivo de diagnóstico por processo
// Path: /var/tmp/com.apple.avfcache/probe_<processName>.txt
// -----------------------------------------------------------------------
static void avs_write_probe(NSString *processName) {
    NSString *probePath = [NSString stringWithFormat:@"%@/probe_%@.txt",
                           @"/var/tmp/com.apple.avfcache", processName];

    NSMutableString *probe = [NSMutableString string];
    [probe appendFormat:@"loaded\n"];
    [probe appendFormat:@"process: %@\n", processName];
    [probe appendFormat:@"timestamp: %f\n", CACurrentMediaTime()];

    [probe writeToFile:probePath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSLog(@"[avsd] [PROBE] %@", probePath);
}

// -----------------------------------------------------------------------
// Forward declarations
static void AVSFrameCoordinator_setup_mediaserverd(void);
static void AVSFrameCoordinator_setup_springboard(void);
static void AVSFrameCoordinator_setup_uikit_app(void);

// -----------------------------------------------------------------------
// Constructor: injetado em cada processo pelo CydiaSubstrate
// -----------------------------------------------------------------------
__attribute__((constructor))
static void avs_ctor(void) {
    @autoreleasepool {
        NSString *processName = [NSProcessInfo processInfo].processName;
        NSLog(@"[avsd-KYC] ctor starting in %@", processName);

        // Garante diretório de cache
        [[NSFileManager defaultManager]
         createDirectoryAtPath:@"/var/tmp/com.apple.avfcache"
     withIntermediateDirectories:YES attributes:nil error:nil];

        // Setup crash handler
        avs_setup_crash_handler();

        // Probe de diagnóstico
        avs_write_probe(processName);

        if ([processName isEqualToString:@"mediaserverd"]) {
            AVSFrameCoordinator_setup_mediaserverd();
        } else if ([processName isEqualToString:@"SpringBoard"]) {
            AVSFrameCoordinator_setup_springboard();
        } else {
            AVSFrameCoordinator_setup_uikit_app();
        }
    }
}

// -----------------------------------------------------------------------
// Setup para mediaserverd
// -----------------------------------------------------------------------
static void AVSFrameCoordinator_setup_mediaserverd(void) {
    // Carrega frameworks privados via dlopen
    void *cmCaptureCore = dlopen(
        "/System/Library/PrivateFrameworks/CMCaptureCore.framework/CMCaptureCore", RTLD_LAZY);
    void *cmCapture = dlopen(
        "/System/Library/PrivateFrameworks/CMCapture.framework/CMCapture", RTLD_LAZY);
    void *frontBoard = dlopen(
        "/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices", RTLD_LAZY);
    NSLog(@"[avsd-KYC] dlopen complete");
    (void)cmCaptureCore; (void)cmCapture; (void)frontBoard;

    // Inicializa coordinator global
    gCoordinator = [[AVSFrameCoordinator alloc] init];
    NSLog(@"[avsd-KYC] KYCCore initialized");

    // Hook BWNodeOutput
    Class bwNodeOutputClass = NSClassFromString(@"BWNodeOutput");
    if (bwNodeOutputClass) {
        MSHookMessageEx(bwNodeOutputClass,
                        sel_registerName("dealloc"),
                        (IMP)hook_BWNodeOutput_dealloc,
                        (IMP *)&orig_BWNodeOutput_dealloc);

        SEL copyNextSel = NSSelectorFromString(@"copyNextSampleBuffer");
        MSHookMessageEx(bwNodeOutputClass,
                        copyNextSel,
                        (IMP)hook_BWNodeOutput_copyNextSampleBuffer,
                        (IMP *)&orig_BWNodeOutput_copyNextSampleBuffer);
        NSLog(@"[avsd-KYC] KYCMetadata initialized");
    }

    // Hook FigCaptureClientSessionMonitor
    Class figMonitorClass = NSClassFromString(@"FigCaptureClientSessionMonitor");
    if (figMonitorClass) {
        MSHookMessageEx(figMonitorClass,
                        @selector(init),
                        (IMP)hook_FigCaptureClientSessionMonitor_init,
                        (IMP *)&orig_sessionMonitorInit);
        NSLog(@"[avsd-KYC] KYCSession initialized (FigCaptureClientSessionMonitor)");
    }

    // Hook BWStillImageScalerNode + BWPhotoEncoderNode para fotos
    Class photoEncoderClass = NSClassFromString(@"BWPhotoEncoderNode");
    if (photoEncoderClass) {
        SEL addAuxSel = NSSelectorFromString(
            @"_addAuxImagesIfNeededForEncodingScheme:sampleBuffer:metadata:stillImageSettings:processingFlags:embedThumbToCompressedImage:");
        MSHookMessageEx(photoEncoderClass, addAuxSel,
                        (IMP)hook_addAuxImages,
                        (IMP *)&orig_addAuxImages);
        NSLog(@"[avsd-KYC] KYCPhoto initialized");
        NSLog(@"[avsd-KYC] KYCPhotoEncoder initialized (A11+)");
    }

    // Hook orientação via FBSOrientationUpdate
    Class fbsOrientClass = NSClassFromString(@"FBSOrientationUpdate");
    if (fbsOrientClass) {
        NSLog(@"[avsd-KYC] KYCOrientation initialized (FBSOrientationUpdate)");
    }

    NSLog(@"[avsd-KYC] init complete");
}

// -----------------------------------------------------------------------
// Setup para SpringBoard (UI flutuante)
// -----------------------------------------------------------------------
static void AVSFrameCoordinator_setup_springboard(void) {
    // Observa UIApplicationDidFinishLaunching
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetLocalCenter(),
        NULL,
        handleApplicationLaunched,
        CFSTR("UIApplicationDidFinishLaunching"),
        NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately
    );

    // Observa estado de lock
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        NULL,
        handleLockStateChange,
        CFSTR("com.apple.springboard.lockstate"),
        NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately
    );
}

// -----------------------------------------------------------------------
// Setup para apps UIKit (WebKit, câmera, etc.)
// -----------------------------------------------------------------------
static void AVSFrameCoordinator_setup_uikit_app(void) {
    // Hook AVCaptureVideoDataOutputSampleBufferDelegate
    // para injetar frames em apps que usam câmera via AVFoundation
    Class avCapOutput = NSClassFromString(@"AVCaptureVideoDataOutput");
    if (!avCapOutput) return;

    SEL delegateSel = NSSelectorFromString(
        @"captureOutput:didOutputSampleBuffer:fromConnection:");

    // Note: o delegate é um objeto externo; hook via Method Swizzling
    // nas classes concretas que implementam o delegate
}
