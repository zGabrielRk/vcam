// KYCHooks.m
// LordVCAM — Reconstruído via engenharia reversa de AVServicesd.dylib
// Entry point do tweak: hooks via CydiaSubstrate em mediaserverd e SpringBoard

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#import <substrate.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <signal.h>
#import <execinfo.h>
#import <mach/mach.h>
#import <os/log.h>
#import <QuartzCore/QuartzCore.h>

#import "AVSFrameCoordinator.h"
#import "AVSRenderPipeline.h"
#import "AVSMediaDecoder.h"
#import "AVSStreamTransport.h"
#import "AVSAudioBridge.h"
#import "AVSPreferencePanel.h"
#import "AVSServiceConfiguration.h"
#import "AVSWSProtocol.h"
#import "AVSDataProvider.h"
#include <notify.h>

// -----------------------------------------------------------------------
// File-based logging — immune to iOS syslog filtering
// -----------------------------------------------------------------------
static NSString *const kAVSLogPath = @"/var/tmp/com.apple.avfcache/avsd.log";
static NSLock *gLogLock = nil;

void AVSLogWrite(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSString *ts = [NSString stringWithFormat:@"%.3f", CACurrentMediaTime()];
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", ts, msg];

    if (!gLogLock) gLogLock = [[NSLock alloc] init];
    [gLogLock lock];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kAVSLogPath];
    if (!fh) {
        [@"" writeToFile:kAVSLogPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        fh = [NSFileHandle fileHandleForWritingAtPath:kAVSLogPath];
    }
    [fh seekToEndOfFile];
    [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [fh closeFile];
    [gLogLock unlock];

    os_log_error(OS_LOG_DEFAULT, "%{public}@", msg);
}

// Singleton global do coordinator
static AVSFrameCoordinator *gCoordinator = nil;
static AVSPreferencePanel  *gPanel       = nil;
static AVSServiceConfiguration *gConfig  = nil;
static AVSLocalDataProvider *gMediaserverdProvider = nil;

// -----------------------------------------------------------------------
// Ponteiros originais de funções hookadas
// -----------------------------------------------------------------------

// BWNodeOutput
static void (*orig_BWNodeOutput_dealloc)(id self, SEL _cmd);

// AVCaptureConnection - método principal de entrega de frame
typedef void (*CopyNextFrameFunc)(id, SEL, CMSampleBufferRef, int);
static CopyNextFrameFunc orig_copyNextFrame __attribute__((unused)) = NULL;

// FigCaptureClientSessionMonitor
typedef id (*SessionMonitorInitFunc)(id, SEL);
static SessionMonitorInitFunc orig_sessionMonitorInit = NULL;

// AVCapturePhotoOutput
typedef void (*PhotoOutputFunc)(id, SEL, id, id);
static PhotoOutputFunc orig_photoOutput __attribute__((unused)) = NULL;

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
static _Atomic(int) gHookCallCount = 0;
static CMSampleBufferRef hook_BWNodeOutput_copyNextSampleBuffer(id self, SEL _cmd) {
    CMSampleBufferRef orig = orig_BWNodeOutput_copyNextSampleBuffer(self, _cmd);
    int count = ++gHookCallCount;
    if (count == 1 || count % 300 == 0) {
        NSLog(@"[avsd] BWNodeOutput hook called #%d, gCoordinator=%p replOn=%d feedOn=%d lastPB=%p",
              count, gCoordinator,
              gCoordinator ? (int)gCoordinator._avs_cfg_replOn : -1,
              gCoordinator ? (int)gCoordinator._avs_cfg_feedOn : -1,
              gCoordinator ? (void *)gCoordinator._avs_cfg_lastPB : NULL);
    }
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
static _Atomic(int) gFrameCounter = 0;

// Hook no callback de entrega de frame ao app
typedef void (*SampleBufferDelegateFunc)(id, SEL, id, CMSampleBufferRef, id);
static SampleBufferDelegateFunc orig_captureOutput_didOutputSampleBuffer;

static _Atomic(int) gDelegateHookEntryCount = 0;
static void hook_captureOutput_didOutputSampleBuffer(
    id self, SEL _cmd,
    id captureOutput,
    CMSampleBufferRef sampleBuffer,
    id connection
) {
    int entry = ++gDelegateHookEntryCount;
    if (entry == 1 || entry % 300 == 0) {
        NSLog(@"[avsd] delegate hook called #%d coord=%p replOn=%d feedOn=%d lastPB=%p",
              entry, gCoordinator,
              gCoordinator ? (int)gCoordinator._avs_cfg_replOn : -1,
              gCoordinator ? (int)gCoordinator._avs_cfg_feedOn : -1,
              gCoordinator ? (void *)gCoordinator._avs_cfg_lastPB : NULL);
    }
    if (!gCoordinator || !gCoordinator._avs_cfg_replOn) {
        orig_captureOutput_didOutputSampleBuffer(self, _cmd, captureOutput, sampleBuffer, connection);
        return;
    }

    int n = ++gFrameCounter;

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
    CFRelease(replacement); // injectReplacementForFrame: retorna com retain
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
typedef void (*AddAuxImagesFunc)(id, SEL, int, CMSampleBufferRef, id, id, id, BOOL);
static AddAuxImagesFunc orig_addAuxImages;
static void hook_addAuxImages(id self, SEL _cmd, int scheme,
                               CMSampleBufferRef sampleBuf, id meta,
                               id settings, id flags, BOOL embedThumb) {
    // Se replacement ativo, substitui o sample buffer antes de encodar
    CMSampleBufferRef replacement = NULL;
    if (gCoordinator) {
        replacement = [gCoordinator injectReplacementForFrame:sampleBuf];
        if (replacement != sampleBuf) sampleBuf = replacement;
        else replacement = NULL; // não precisa release
    }
    orig_addAuxImages(self, _cmd, scheme, sampleBuf, meta, settings, flags, embedThumb);
    if (replacement) CFRelease(replacement);
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
        gConfig = [[AVSServiceConfiguration alloc] init];
        gPanel  = [[AVSPreferencePanel alloc] init];
        gPanel.coordinator = gCoordinator;
        [gPanel setupWindows];
        NSLog(@"[avsd] SpringBoard UI initialized");

        // Diagnostic: check if mediaserverd loaded the tweak after 5 seconds
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{
            NSFileManager *fm = [NSFileManager defaultManager];
            BOOL msLoaded = [fm fileExistsAtPath:@"/var/tmp/com.apple.avfcache/probe_mediaserverd.txt"];
            NSString *status;
            if (msLoaded) {
                status = @"mediaserverd: OK | Select Gallery";
            } else {
                status = @"Camera app mode | Select Gallery";
            }
            gPanel.statsLabel.text = status;
            NSLog(@"[avsd] DIAGNOSTIC: mediaserverd=%d", msLoaded);
        });
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

// Forward declarations — defined below the constructor
static void AVSFrameCoordinator_setup_mediaserverd(void);
static void AVSFrameCoordinator_setup_springboard(void);
static void AVSFrameCoordinator_setup_uikit_app(void);

// Forward declarations for hooks/handlers used in setup functions
typedef void (*AddAuxImagesScaleFunc)(id, SEL, int, CMSampleBufferRef, id, id, float, id, BOOL);
static AddAuxImagesScaleFunc orig_addAuxImagesScale;
static void hook_addAuxImagesScale(id self, SEL _cmd, int scheme,
                                    CMSampleBufferRef sampleBuf, id meta,
                                    id settings, float scaleFactor,
                                    id flags, BOOL embedThumb);
static void (*orig_handleHomeGesture)(id, SEL, id);
static void hook_handleHomeGesture(id self, SEL _cmd, id gesture);
static void _handleApplicationStateChange(CFNotificationCenterRef center,
                                           void *observer,
                                           CFStringRef name,
                                           const void *object,
                                           CFDictionaryRef userInfo);

// -----------------------------------------------------------------------
// Constructor: injetado em cada processo pelo CydiaSubstrate
// -----------------------------------------------------------------------
__attribute__((constructor))
static void avs_ctor(void) {
    // Earliest possible log — before any ObjC allocation
    os_log_error(OS_LOG_DEFAULT, "[avsd] ctor ENTRY — dylib loaded");

    @autoreleasepool {
        NSString *processName = [NSProcessInfo processInfo].processName;
        NSLog(@"[avsd-KYC] ctor starting in %@", processName);
        os_log_error(OS_LOG_DEFAULT, "[avsd-KYC] ctor starting in %{public}@", processName);

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
    gConfig = [[AVSServiceConfiguration alloc] init];
    NSLog(@"[avsd-KYC] KYCCore initialized");

    // Listen for gallery changes from SpringBoard via Darwin notification
    int galleryToken = 0;
    notify_register_dispatch("com.apple.avsd.vmirror", &galleryToken,
        dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0),
        ^(int token) {
            AVSLogWrite(@"[avsd-KYC] Gallery notification received in mediaserverd");
            NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:
                @"/var/tmp/com.apple.avfcache/gallery_prefs.plist"];
            if (!prefs) {
                // Gallery cleared
                [gCoordinator enableReplacement:NO];
                if (gMediaserverdProvider) {
                    [gMediaserverdProvider _avs_dat_stop];
                    gMediaserverdProvider = nil;
                }
                AVSLogWrite(@"[avsd-KYC] Gallery cleared in mediaserverd");
                return;
            }
            NSString *path = prefs[@"path"];
            BOOL isVideo = [prefs[@"isVideo"] boolValue];
            if (!path.length) return;

            // Create local data provider and load the media
            AVSLocalDataProvider *provider = [[AVSLocalDataProvider alloc] init];
            gMediaserverdProvider = provider;
            [gCoordinator setDataSource:provider];
            NSURL *url = [NSURL fileURLWithPath:path];
            if (isVideo) {
                [provider _avs_dat_loadVid:url];
            } else {
                [provider _avs_dat_loadImg:url];
            }
            [gCoordinator enableReplacement:YES];
            AVSLogWrite(@"[avsd-KYC] Gallery loaded in mediaserverd: %@ (video=%d)", path, isVideo);
        });
    AVSLogWrite(@"[avsd-KYC] Gallery notification listener registered");

    // Diagnostic: scan for camera pipeline classes in mediaserverd
    {
        NSArray *classesToProbe = @[
            @"BWNodeOutput", @"BWNode", @"BWNodeInput",
            @"BWFigCaptureDevice", @"BWFigCaptureStream",
            @"BWSourceNode", @"BWCameraSourceNode",
            @"FigCaptureSource", @"FigCaptureStream",
            @"FigCaptureSourceNode", @"FigCaptureDevice",
            @"FigCaptureClientSessionMonitor",
            @"BWPhotoEncoderNode", @"BWStillImageScalerNode",
            @"CMCaptureDevice", @"CMCaptureSession",
            @"CMCaptureOutput", @"CMCaptureVideoDataOutput",
        ];
        NSMutableArray *found = [NSMutableArray array];
        NSMutableArray *missing = [NSMutableArray array];
        for (NSString *name in classesToProbe) {
            if (NSClassFromString(name)) {
                [found addObject:name];
            } else {
                [missing addObject:name];
            }
        }
        NSLog(@"[avsd-KYC] DIAG mediaserverd classes FOUND: %@", found);
        NSLog(@"[avsd-KYC] DIAG mediaserverd classes MISSING: %@", missing);

        // Also scan for any class containing "Node" or "Output" or "Capture"
        unsigned int classCount = 0;
        Class *allClasses = objc_copyClassList(&classCount);
        NSMutableArray *nodeClasses = [NSMutableArray array];
        for (unsigned int i = 0; i < classCount && nodeClasses.count < 40; i++) {
            NSString *cn = NSStringFromClass(allClasses[i]);
            if ([cn hasPrefix:@"BW"] || [cn hasPrefix:@"FigCapture"] ||
                [cn hasPrefix:@"CMCapture"]) {
                [nodeClasses addObject:cn];
            }
        }
        free(allClasses);
        NSLog(@"[avsd-KYC] DIAG BW/FigCapture/CMCapture classes: %@", nodeClasses);
    }

    // Hook BWNodeOutput
    Class bwNodeOutputClass = NSClassFromString(@"BWNodeOutput");
    if (bwNodeOutputClass) {
        MSHookMessageEx(bwNodeOutputClass,
                        sel_registerName("dealloc"),
                        (IMP)hook_BWNodeOutput_dealloc,
                        (IMP *)&orig_BWNodeOutput_dealloc);

        SEL copyNextSel = NSSelectorFromString(@"copyNextSampleBuffer");
        if ([bwNodeOutputClass instancesRespondToSelector:copyNextSel]) {
            MSHookMessageEx(bwNodeOutputClass,
                            copyNextSel,
                            (IMP)hook_BWNodeOutput_copyNextSampleBuffer,
                            (IMP *)&orig_BWNodeOutput_copyNextSampleBuffer);
            NSLog(@"[avsd-KYC] BWNodeOutput.copyNextSampleBuffer hooked OK");
        } else {
            NSLog(@"[avsd-KYC] WARNING: BWNodeOutput exists but copyNextSampleBuffer NOT found!");
            // List all methods on BWNodeOutput
            unsigned int mc = 0;
            Method *methods = class_copyMethodList(bwNodeOutputClass, &mc);
            NSMutableArray *sels = [NSMutableArray array];
            for (unsigned int i = 0; i < mc; i++) {
                [sels addObject:NSStringFromSelector(method_getName(methods[i]))];
            }
            free(methods);
            NSLog(@"[avsd-KYC] BWNodeOutput methods: %@", sels);
        }
        NSLog(@"[avsd-KYC] KYCMetadata initialized");
    } else {
        NSLog(@"[avsd-KYC] WARNING: BWNodeOutput class NOT FOUND in mediaserverd!");
    }

    // Hook FigCaptureClientSessionMonitor
    Class figMonitorClass = NSClassFromString(@"FigCaptureClientSessionMonitor");
    if (figMonitorClass) {
        MSHookMessageEx(figMonitorClass,
                        @selector(init),
                        (IMP)hook_FigCaptureClientSessionMonitor_init,
                        (IMP *)&orig_sessionMonitorInit);
        NSLog(@"[avsd-KYC] KYCSession initialized (FigCaptureClientSessionMonitor)");
    } else {
        NSLog(@"[avsd-KYC] WARNING: FigCaptureClientSessionMonitor NOT FOUND");
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

        // Segunda variante com scaleFactor: (A14+ / iPhone 12+)
        SEL addAuxScaleSel = NSSelectorFromString(
            @"_addAuxImagesIfNeededForEncodingScheme:sampleBuffer:metadata:stillImageSettings:scaleFactor:processingFlags:embedThumbToCompressedImage:");
        if ([photoEncoderClass instancesRespondToSelector:addAuxScaleSel]) {
            MSHookMessageEx(photoEncoderClass, addAuxScaleSel,
                            (IMP)hook_addAuxImagesScale,
                            (IMP *)&orig_addAuxImagesScale);
            NSLog(@"[avsd-KYC] KYCPhotoEncoder scaleFactor variant hooked (A14+)");
        }
    }

    // Hook orientação via FBSOrientationUpdate
    Class fbsOrientClass = NSClassFromString(@"FBSOrientationUpdate");
    if (fbsOrientClass) {
        NSLog(@"[avsd-KYC] KYCOrientation initialized (FBSOrientationUpdate)");
    }

    NSLog(@"[avsd-KYC] init complete");
}

// -----------------------------------------------------------------------
// Hook de Volume: Volume+ e Volume- simultâneos → toggle do painel
// Baseado nos seletores do binário original:
//   increaseVolume / decreaseVolume (SpringBoard)
//   handleVolumeUpButtonPress / handleVolumeDownButtonPress (tweak)
//   _avs_ov_showPnlC (combo toggle)
// -----------------------------------------------------------------------
static _Atomic(double) gVolUpTime  = 0;
static _Atomic(double) gVolDownTime = 0;
static const double kVolumeComboWindow = 0.4; // segundos para considerar combo

static void (*orig_increaseVolume)(id, SEL);
static void (*orig_decreaseVolume)(id, SEL);

static void hook_increaseVolume(id self, SEL _cmd) {
    gVolUpTime = CACurrentMediaTime();
    // Se Volume- foi pressionado dentro da janela de combo → toggle painel
    if ((gVolUpTime - gVolDownTime) < kVolumeComboWindow && gVolDownTime > 0) {
        gVolUpTime = 0;
        gVolDownTime = 0;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (gPanel) [gPanel _togglePanel];
        });
        return; // engole o evento de volume
    }
    orig_increaseVolume(self, _cmd);
}

static void hook_decreaseVolume(id self, SEL _cmd) {
    gVolDownTime = CACurrentMediaTime();
    // Se Volume+ foi pressionado dentro da janela de combo → toggle painel
    if ((gVolDownTime - gVolUpTime) < kVolumeComboWindow && gVolUpTime > 0) {
        gVolUpTime = 0;
        gVolDownTime = 0;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (gPanel) [gPanel _togglePanel];
        });
        return;
    }
    orig_decreaseVolume(self, _cmd);
}

// -----------------------------------------------------------------------
// Setup para SpringBoard (UI flutuante)
// -----------------------------------------------------------------------
static void AVSFrameCoordinator_setup_springboard(void) {
    // Hook Volume+/- no SpringBoard para combo de atalho
    // iOS versions use different selectors for volume handling
    Class springBoardClass = NSClassFromString(@"SpringBoard");
    if (springBoardClass) {
        // Try modern selectors first, fall back to legacy
        NSArray *upSelectors = @[@"handleVolumeUpButtonPress", @"increaseVolume:forSource:", @"increaseVolume"];
        NSArray *dnSelectors = @[@"handleVolumeDownButtonPress", @"decreaseVolume:forSource:", @"decreaseVolume"];

        BOOL hookedUp = NO, hookedDn = NO;
        for (NSString *selName in upSelectors) {
            SEL sel = NSSelectorFromString(selName);
            if ([springBoardClass instancesRespondToSelector:sel]) {
                MSHookMessageEx(springBoardClass, sel,
                                (IMP)hook_increaseVolume,
                                (IMP *)&orig_increaseVolume);
                NSLog(@"[avsd-KYC] Volume UP hooked via %@", selName);
                hookedUp = YES;
                break;
            }
        }
        for (NSString *selName in dnSelectors) {
            SEL sel = NSSelectorFromString(selName);
            if ([springBoardClass instancesRespondToSelector:sel]) {
                MSHookMessageEx(springBoardClass, sel,
                                (IMP)hook_decreaseVolume,
                                (IMP *)&orig_decreaseVolume);
                NSLog(@"[avsd-KYC] Volume DOWN hooked via %@", selName);
                hookedDn = YES;
                break;
            }
        }
        if (hookedUp && hookedDn) {
            NSLog(@"[avsd-KYC] Volume combo hook installed");
        } else {
            NSLog(@"[avsd-KYC] WARNING: Volume hook incomplete (up=%d dn=%d)", hookedUp, hookedDn);
        }
    }

    // Hook home gesture para esconder painel ao sair do app
    Class sbHomeGesture = NSClassFromString(@"SBHomeHardwareButton");
    if (!sbHomeGesture) sbHomeGesture = NSClassFromString(@"SBSystemGestureManager");
    if (sbHomeGesture) {
        SEL homeGestureSel = NSSelectorFromString(@"_handleHomeGesture:");
        if ([sbHomeGesture instancesRespondToSelector:homeGestureSel]) {
            MSHookMessageEx(sbHomeGesture, homeGestureSel,
                            (IMP)hook_handleHomeGesture,
                            (IMP *)&orig_handleHomeGesture);
            NSLog(@"[avsd-KYC] Home gesture hook installed");
        }
    }

    // Observa mudança de app em primeiro plano
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        NULL,
        _handleApplicationStateChange,
        CFSTR("com.apple.springboard.activeapp"),
        NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately
    );

    // Observa UIApplicationDidFinishLaunching via NSNotificationCenter
    // (UIKit notifications are NSNotification, not CFNotification)
    [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidFinishLaunchingNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
        NSLog(@"[avsd] UIApplicationDidFinishLaunching received");
        handleApplicationLaunched(NULL, NULL, NULL, NULL, NULL);
    }];

    // Observa estado de lock
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        NULL,
        handleLockStateChange,
        CFSTR("com.apple.springboard.lockstate"),
        NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately
    );

    // Fallback: se o SpringBoard já terminou de iniciar antes do tweak carregar,
    // a notificação já foi postada e o observer acima nunca vai disparar.
    // Also serves as safety net if NSNotification is never delivered.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (!gPanel) {
            NSLog(@"[avsd] Fallback timer: gPanel is nil, initializing UI now");
            handleApplicationLaunched(NULL, NULL, NULL, NULL, NULL);
        } else {
            NSLog(@"[avsd] Fallback timer: gPanel already exists, skipping");
        }
    });

    NSLog(@"[avsd-KYC] SpringBoard setup complete (observers registered)");
}

// -----------------------------------------------------------------------
// Handlers de estado de aplicação e gestos (SpringBoard)
// -----------------------------------------------------------------------
static void _handleApplicationStateChange(CFNotificationCenterRef center,
                                           void *observer,
                                           CFStringRef name,
                                           const void *object,
                                           CFDictionaryRef userInfo) {
    // Detecta mudança de app em primeiro plano
    // Pausa stream quando app de câmera nativo abre para evitar conflito
    NSString *notifName = (__bridge NSString *)name;
    if ([notifName containsString:@"foregroundApp"]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (gPanel) [gPanel forceHideOnLock];
        });
    }
}

// orig_handleHomeGesture declared in forward declarations above
static void hook_handleHomeGesture(id self, SEL _cmd, id gesture) {
    // Esconde painel ao voltar para Home
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gPanel && gPanel.panelVisible) {
            [gPanel dismiss];
        }
    });
    orig_handleHomeGesture(self, _cmd, gesture);
}

// -----------------------------------------------------------------------
// Hook: segunda variante de _addAuxImagesIfNeeded com scaleFactor:
// Presente em dispositivos A14+ (iPhone 12+)
// -----------------------------------------------------------------------
// AddAuxImagesScaleFunc and orig_addAuxImagesScale declared in forward declarations above
static void hook_addAuxImagesScale(id self, SEL _cmd, int scheme,
                                    CMSampleBufferRef sampleBuf, id meta,
                                    id settings, float scaleFactor,
                                    id flags, BOOL embedThumb) {
    CMSampleBufferRef replacement = NULL;
    if (gCoordinator) {
        replacement = [gCoordinator injectReplacementForFrame:sampleBuf];
        if (replacement != sampleBuf) sampleBuf = replacement;
        else replacement = NULL;
    }
    orig_addAuxImagesScale(self, _cmd, scheme, sampleBuf, meta,
                           settings, scaleFactor, flags, embedThumb);
    if (replacement) CFRelease(replacement);
}

// -----------------------------------------------------------------------
// Setup para apps UIKit (câmera, WhatsApp, etc.)
// Hook dinâmico: intercepta setSampleBufferDelegate:queue: para hookar
// o delegate no momento em que o app registra, garantindo que capturamos
// delegates de classes que ainda não existiam no load time.
// -----------------------------------------------------------------------

// Hook: -[AVCaptureVideoDataOutput setSampleBufferDelegate:queue:]
static void (*orig_setSampleBufferDelegate)(id, SEL, id, dispatch_queue_t);
static void hook_setSampleBufferDelegate(id self, SEL _cmd, id delegate, dispatch_queue_t queue) {
    if (delegate) {
        // Hook delegate's method BEFORE calling original — AVFoundation may cache the IMP
        Class cls = [delegate class];
        SEL sel = @selector(captureOutput:didOutputSampleBuffer:fromConnection:);
        Method m = class_getInstanceMethod(cls, sel);
        if (!m) {
            NSLog(@"[avsd-KYC] delegate %s does NOT implement captureOutput:didOutputSampleBuffer:", class_getName(cls));
        } else {
            IMP currentImpl = method_getImplementation(m);
            if (currentImpl == (IMP)hook_captureOutput_didOutputSampleBuffer) {
                NSLog(@"[avsd-KYC] delegate %s already hooked", class_getName(cls));
            } else {
                orig_captureOutput_didOutputSampleBuffer = (SampleBufferDelegateFunc)currentImpl;
                method_setImplementation(m, (IMP)hook_captureOutput_didOutputSampleBuffer);
                NSLog(@"[avsd-KYC] DYNAMIC hook on delegate: %s", class_getName(cls));
            }
        }
    }

    // Call original after hooking so cached IMP points to our hook
    orig_setSampleBufferDelegate(self, _cmd, delegate, queue);
}

static void AVSFrameCoordinator_setup_uikit_app(void) {
    // Inicializa coordinator para apps de terceiros
    gCoordinator = [[AVSFrameCoordinator alloc] init];

    // Listen for gallery changes — UIKit apps also need to inject frames
    // in case mediaserverd path doesn't work (e.g. BWNodeOutput not present)
    int galleryToken = 0;
    notify_register_dispatch("com.apple.avsd.vmirror", &galleryToken,
        dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0),
        ^(int token) {
            AVSLogWrite(@"[avsd-KYC] Gallery notification received in UIKit app");
            NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:
                @"/var/tmp/com.apple.avfcache/gallery_prefs.plist"];
            if (!prefs) {
                [gCoordinator enableReplacement:NO];
                if (gMediaserverdProvider) {
                    [gMediaserverdProvider _avs_dat_stop];
                    gMediaserverdProvider = nil;
                }
                return;
            }
            NSString *path = prefs[@"path"];
            BOOL isVideo = [prefs[@"isVideo"] boolValue];
            if (!path.length) return;

            AVSLocalDataProvider *provider = [[AVSLocalDataProvider alloc] init];
            gMediaserverdProvider = provider;
            [gCoordinator setDataSource:provider];
            NSURL *url = [NSURL fileURLWithPath:path];
            if (isVideo) {
                [provider _avs_dat_loadVid:url];
            } else {
                [provider _avs_dat_loadImg:url];
            }
            [gCoordinator enableReplacement:YES];
            AVSLogWrite(@"[avsd-KYC] Gallery loaded in UIKit app: %@ (video=%d)", path, isVideo);
        });
    AVSLogWrite(@"[avsd-KYC] UIKit app gallery notification listener registered");

    // Hook AVCaptureVideoDataOutput para interceptar setSampleBufferDelegate:queue:
    Class avCapOutput = NSClassFromString(@"AVCaptureVideoDataOutput");
    if (!avCapOutput) {
        NSLog(@"[avsd-KYC] AVCaptureVideoDataOutput not found, skipping UIKit hooks");
        return;
    }

    // Hook setSampleBufferDelegate:queue: — catches dynamic delegate registrations
    SEL setDelSel = @selector(setSampleBufferDelegate:queue:);
    MSHookMessageEx(avCapOutput, setDelSel,
                    (IMP)hook_setSampleBufferDelegate,
                    (IMP *)&orig_setSampleBufferDelegate);
    NSLog(@"[avsd-KYC] Hooked AVCaptureVideoDataOutput.setSampleBufferDelegate:queue:");

    // Scan classes at load time that already implement the delegate method
    unsigned int classCount = 0;
    Class *classes = objc_copyClassList(&classCount);
    SEL capSel = @selector(captureOutput:didOutputSampleBuffer:fromConnection:);
    int hookCount = 0;

    for (unsigned int i = 0; i < classCount; i++) {
        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(classes[i], &methodCount);
        BOOL hasMethod = NO;
        for (unsigned int j = 0; j < methodCount; j++) {
            if (method_getName(methods[j]) == capSel) {
                hasMethod = YES;
                break;
            }
        }
        free(methods);

        if (hasMethod) {
            Method m = class_getInstanceMethod(classes[i], capSel);
            if (m) {
                SampleBufferDelegateFunc origImpl = (SampleBufferDelegateFunc)method_getImplementation(m);
                if ((IMP)origImpl != (IMP)hook_captureOutput_didOutputSampleBuffer) {
                    orig_captureOutput_didOutputSampleBuffer = origImpl;
                    method_setImplementation(m, (IMP)hook_captureOutput_didOutputSampleBuffer);
                    NSLog(@"[avsd-KYC] Hooked existing delegate: %s", class_getName(classes[i]));
                    hookCount++;
                }
            }
        }
    }
    free(classes);
    NSLog(@"[avsd-KYC] Load-time scan: hooked %d delegate classes", hookCount);

    NSLog(@"[avsd-KYC] UIKit app setup complete");
}
