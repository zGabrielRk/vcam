// AVSFrameCoordinator.m
// LordVCAM — Reconstruído via engenharia reversa de AVServicesd.dylib
// Classe central: orquestra toda a pipeline de injeção de frames

#import "AVSFrameCoordinator.h"
#import "AVSMediaDecoder.h"
#import "AVSRenderPipeline.h"
#import "AVSAudioBridge.h"
#import "AVSMotionSynthesizer.h"
#import "AVSFormatAnalyzer.h"
#import "AVSDataProvider.h"
#import "AVSWSProtocol.h"
#import <QuartzCore/QuartzCore.h>
#import <CommonCrypto/CommonCrypto.h>
#include <sys/socket.h>
#include <netdb.h>
#include <arpa/inet.h>
#include <netinet/in.h>

// Intervalo de sync com servidor (1s)
static const NSTimeInterval kSyncInterval  = 1.0;
// Intervalo de tracking de métricas (5s)
static const NSTimeInterval kTrackInterval = 5.0;
// Threshold de frame stale antes de marcar como erro (ms)
static const double kStaleFrameThresholdMs = 250.0;

@implementation AVSFrameCoordinator {
    AVSMediaDecoder       *_decoder;
    AVSRenderPipeline     *_renderPipeline;
    AVSAudioBridge        *_audioBridge;
    AVSMotionSynthesizer  *_motionSynth;
    AVSFormatAnalyzer     *_formatAnalyzer;

    NSLock          *_frameLock;
    NSLock          *_eventLock;
    NSMutableArray  *_pendingEvents; // substituição thread-safe de _avs_cfg_pendMsgs

    double _lastFrameDeliveryTime;
    double _lastSyncTime;
    int    _framesSinceLastSync;

    // EMA de latência de decodificação (α = 0.1)
    double _decodeEMA;
    BOOL   _firstDecodeEMA;

    // Guarda de registro de notificação de lock screen
    BOOL   _lockStateRegistered;
}

// Propriedades com underscore inicial: o compilador sintetiza ivar com duplo-underscore
// (ex.: _avs_cfg_replOn → __avs_cfg_replOn). @synthesize explícito cria o ivar esperado.
@synthesize _avs_cfg_replOn     = _avs_cfg_replOn;
@synthesize _avs_cfg_feedOn     = _avs_cfg_feedOn;
@synthesize _avs_cfg_lastPB     = _avs_cfg_lastPB;
@synthesize _avs_cfg_lastRecv   = _avs_cfg_lastRecv;
@synthesize _avs_cfg_stallRec   = _avs_cfg_stallRec;
@synthesize _avs_cfg_frmSkip    = _avs_cfg_frmSkip;
@synthesize _avs_cfg_frmDlvr   = _avs_cfg_frmDlvr;
@synthesize _avs_cfg_frmDec    = _avs_cfg_frmDec;
@synthesize _avs_cfg_frmProc   = _avs_cfg_frmProc;
@synthesize _avs_cfg_frmSub    = _avs_cfg_frmSub;
@synthesize _avs_cfg_curFmt    = _avs_cfg_curFmt;
@synthesize _avs_cfg_fxOn      = _avs_cfg_fxOn;
@synthesize _avs_cfg_vidRot    = _avs_cfg_vidRot;
@synthesize _avs_cfg_grainOn   = _avs_cfg_grainOn;
@synthesize _avs_cfg_blendCnt  = _avs_cfg_blendCnt;
@synthesize _avs_cfg_lastProcMs= _avs_cfg_lastProcMs;
@synthesize _avs_cfg_decEMA    = _avs_cfg_decEMA;
@synthesize _avs_cfg_onDec     = _avs_cfg_onDec;

// -----------------------------------------------------------------------
// Init
// -----------------------------------------------------------------------
- (instancetype)init {
    self = [super init];
    if (self) {
        _frameLock     = [[NSLock alloc] init];
        _eventLock     = [[NSLock alloc] init];
        _pendingEvents = [[NSMutableArray alloc] init];
        _decodeEMA  = 0.0;
        _firstDecodeEMA = YES;

        // Inicializa subsistemas
        _decoder       = [[AVSMediaDecoder alloc] init];
        _renderPipeline= [[AVSRenderPipeline alloc] init];
        _audioBridge   = [[AVSAudioBridge alloc] init];
        _motionSynth   = [[AVSMotionSynthesizer alloc] init];
        _formatAnalyzer= [[AVSFormatAnalyzer alloc] init];

        // Estado inicial
        self._avs_cfg_replOn  = NO;
        self._avs_cfg_feedOn  = NO;
        self._avs_cfg_loopOn  = YES;
        self._avs_cfg_prevOn  = YES;
        self._avs_cfg_audioOn = NO;
        self._avs_cfg_fxOn    = NO;
        self._avs_cfg_grainOn = NO;
        self._avs_cfg_moveOn  = NO;
        self._avs_cfg_floatOn = YES;
        self._avs_cfg_prlxOn  = NO;
        self._avs_cfg_inTrans = NO;
        self._avs_cfg_prevEn  = YES;
        self._avs_cfg_stallRec= YES;
        self._avs_cfg_fbOn    = NO;
        self._avs_cfg_loggedFirst = NO;
        self._avs_cfg_isPurch = NO;

        // Contadores zerados
        self._avs_cfg_frmDec  = 0;
        self._avs_cfg_frmSub  = 0;
        self._avs_cfg_frmRecv = 0;
        self._avs_cfg_frmProc = 0;
        self._avs_cfg_frmDlvr = 0;
        self._avs_cfg_frmSkip = 0;
        self._avs_cfg_decErr  = 0;
        self._avs_cfg_blendCnt= 0;
        self._avs_cfg_msgRecv = 0;
        self._avs_cfg_msgSent = 0;
        self._avs_cfg_reconAtt= 0;
        self._avs_cfg_reconCnt= 0;
        self._avs_cfg_pbSpeed = 1;
        self._avs_cfg_motGain = 0.3;
        self._avs_cfg_vidFPS  = 30;
        self._avs_cfg_vidRot  = 0;

        // Configura callback do decoder: frame decodificado → pipeline de render
        __weak typeof(self) ws = self;
        _decoder._avs_cfg_onDec = ^(CMSampleBufferRef frame) {
            [ws _onFrameDecoded:frame];
        };

        // Configura timers
        [self _avs_cfg_startTrk];
        [self _startSyncTimer];
    }
    return self;
}

- (void)dealloc {
    [self _avs_cfg_stopTrk];
    if (self._avs_cfg_syncTimer) {
        dispatch_source_cancel(self._avs_cfg_syncTimer);
    }
    [_motionSynth stop];
}

// -----------------------------------------------------------------------
// Frame delivery pipeline
// Chamado por KYCHooks ao interceptar um frame do BWNodeOutput/AVCaptureConnection
// -----------------------------------------------------------------------
- (CMSampleBufferRef)injectReplacementForFrame:(CMSampleBufferRef)original {
    // Direct ivar reads: fast-exit guards on camera hook hot path (every frame)
    if (!_avs_cfg_replOn || !_avs_cfg_feedOn) {
        return original;
    }

    [_frameLock lock];
    CMSampleBufferRef replacement = _avs_cfg_lastPB;
    if (replacement) CFRetain(replacement);
    [_frameLock unlock];

    if (!replacement) {
        return original;
    }

    // Verifica se frame está stale
    double now = CACurrentMediaTime();
    double ageMs = (now - _avs_cfg_lastRecv) * 1000.0;
    if (ageMs > kStaleFrameThresholdMs && _avs_cfg_stallRec) {
        _avs_cfg_frmSkip++;
        CFRelease(replacement);
        return original;
    }

    _avs_cfg_frmDlvr++;
    return replacement; // caller deve CFRelease o original se substituir
}

// -----------------------------------------------------------------------
// Callback interno: frame decodificado pelo AVSMediaDecoder
// -----------------------------------------------------------------------
- (void)_onFrameDecoded:(CMSampleBufferRef)frame {
    if (!frame) return;

    double t0 = CACurrentMediaTime();
    // Direct ivar access: eliminates objc_msgSend overhead at 30-60fps
    _avs_cfg_frmDec++;
    _avs_cfg_lastRecv = t0;

    // Detecta formato em cada frame para manter FPS atualizado
    [_formatAnalyzer _avs_fa_detect:frame];
    _avs_cfg_curFmt = [_formatAnalyzer _avs_fa_info];

    // Aplica pipeline de render (filtros de cor, rotação, zoom, pan)
    CMSampleBufferRef processed = frame;
    if (_avs_cfg_fxOn || _avs_cfg_vidRot != 0 || _avs_cfg_grainOn) {
        processed = [_renderPipeline processFrame:frame];
        _avs_cfg_frmProc++;
    } else {
        CFRetain(processed);
    }

    // Blending de frames consecutivos
    if (_renderPipeline.blendEnabled && _avs_cfg_lastPB) {
        _avs_cfg_blendCnt++;
    }

    // Atualiza latest frame (thread-safe) — set ivar diretamente para evitar deadlock
    [_frameLock lock];
    CMSampleBufferRef old = _avs_cfg_lastPB;
    _avs_cfg_lastPB = processed;
    if (old) CFRelease(old);
    CMSampleBufferRef oldLatest = _latestFrame;
    _latestFrame = processed;
    CFRetain(_latestFrame);
    if (oldLatest) CFRelease(oldLatest);
    [_frameLock unlock];

    _avs_cfg_frmSub++;

    // Atualiza EMA de latência de decodificação
    double procMs = (CACurrentMediaTime() - t0) * 1000.0;
    _avs_cfg_lastProcMs = procMs;
    if (_firstDecodeEMA) {
        _decodeEMA = procMs;
        _firstDecodeEMA = NO;
    } else {
        _decodeEMA = 0.9 * _decodeEMA + 0.1 * procMs;
    }
    _avs_cfg_decEMA = _decodeEMA;

    // Invoke decode callback para preview
    void (^onDec)(CMSampleBufferRef) = _avs_cfg_onDec;
    if (onDec) {
        onDec(processed);
    }

    _framesSinceLastSync++;
}

// -----------------------------------------------------------------------
// Submissão de frame bruto (NAL) vindo da rede
// Chamado por AVSStreamTransport ao receber mensagem de frame
// -----------------------------------------------------------------------
- (void)submitNALData:(NSData *)data sequenceNumber:(int)seq serverTimestamp:(double)srvTs {
    double now = CACurrentMediaTime();

    self._avs_cfg_frmRecv++;

    // Calcula jitter do servidor.
    // IMPORTANTE: jitter usa _avs_cfg_srvEnc (valor anterior) ANTES de sobrescrevê-lo.
    // Não reordenar essas duas linhas.
    if (srvTs > 0) {
        double rtt    = now - srvTs;
        double jitter = fabs(rtt - self._avs_cfg_srvEnc);   // lê valor anterior
        self._avs_cfg_srvJitter = 0.95 * self._avs_cfg_srvJitter + 0.05 * jitter * 1000.0;
        self._avs_cfg_srvEnc    = rtt * 1000.0;             // sobrescreve depois
    }

    // Verifica stale (frame antigo demais: descarta)
    if (self._avs_cfg_frmAge > 0 && self._avs_cfg_frmAge > kStaleFrameThresholdMs / 1000.0) {
        self._avs_cfg_frmSkip++;
        return;
    }

    self._avs_cfg_frmAge = now - self._avs_cfg_lastDec;
    self._avs_cfg_lastDec = now;

    [_decoder _avs_dec_process:data sequenceNumber:seq];
}

// -----------------------------------------------------------------------
// Gerenciamento de fonte de dados
// -----------------------------------------------------------------------
// -----------------------------------------------------------------------
// Conecta um transport (WiFi/USB) ao coordinator
// Registra callbacks de NAL data e áudio PCM
// -----------------------------------------------------------------------
- (void)connectTransport:(AVSStreamTransport *)transport {
    __weak typeof(self) ws = self;
    transport.onNALData = ^(NSData *nalData, int seqnum) {
        [ws submitNALData:nalData sequenceNumber:seqnum serverTimestamp:0];
    };
    transport.onAudioPCM = ^(const float *samples, int count, int channels, double rate) {
        [ws submitAudioPCM:samples count:count channels:channels sampleRate:rate];
    };
}

- (void)setDataSource:(id<AVSDataProvider>)source {
    id<AVSDataProvider> old = self._avs_cfg_curSrc;
    if (old) [old _avs_dat_stop];

    self._avs_cfg_curSrc = source;

    if (source) {
        // Se for AVSLocalDataProvider, registra callback para entrega de frames decodificados
        if ([source isKindOfClass:[AVSLocalDataProvider class]]) {
            __weak typeof(self) ws = self;
            ((AVSLocalDataProvider *)source)._avs_cfg_onDec = ^(CMSampleBufferRef frame) {
                [ws _onFrameDecoded:frame];
            };
        }
        [source _avs_dat_resume];
        self._avs_cfg_feedOn = YES;
        NSLog(@"[avsd] Source set: %@", source);
    } else {
        self._avs_cfg_feedOn = NO;
    }
}

- (void)enableReplacement:(BOOL)enable {
    self._avs_cfg_replOn = enable;
    if (!enable) {
        self._avs_cfg_feedOn = NO;
    }
}

// -----------------------------------------------------------------------
// Audio
// -----------------------------------------------------------------------
- (void)submitAudioPCM:(const float *)samples count:(int)count
              channels:(int)ch sampleRate:(double)rate {
    if (!self._avs_cfg_audioOn) return;
    [_audioBridge _avs_ab_feed:samples count:count channels:ch sampleRate:rate];
}

- (BOOL)consumeAudioPCM:(float *)output count:(int)count
               channels:(int)ch sampleRate:(double)rate {
    if (!self._avs_cfg_audioOn) return NO;
    return [_audioBridge _avs_ab_consume:output count:count channels:ch sampleRate:rate];
}

// -----------------------------------------------------------------------
// Controles da UI → delegados ao render pipeline
// -----------------------------------------------------------------------
- (AVSRenderPipeline *)renderPipeline {
    return _renderPipeline;
}

- (void)setCurrentPanX:(double)x {
    _motionSynth.currentPanX = MAX(-1.0, MIN(x, 1.0));
}

- (void)setLatestFrame:(CMSampleBufferRef)frame {
    // Setter público para uso externo (fora de _frameLock).
    // _onFrameDecoded: escreve _latestFrame diretamente para evitar deadlock.
    [_frameLock lock];
    CMSampleBufferRef old = _latestFrame;
    _latestFrame = frame;
    if (frame) CFRetain(frame);
    if (old)   CFRelease(old);
    [_frameLock unlock];
}

// -----------------------------------------------------------------------
// Timers de sync e tracking
// -----------------------------------------------------------------------
- (void)_avs_cfg_startTrk {
    if (self._avs_cfg_trkTimer) return;

    dispatch_queue_t q = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0);
    self._avs_cfg_trkTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    dispatch_source_set_timer(self._avs_cfg_trkTimer,
                              dispatch_time(DISPATCH_TIME_NOW, kTrackInterval * NSEC_PER_SEC),
                              kTrackInterval * NSEC_PER_SEC,
                              NSEC_PER_SEC / 2);
    __weak typeof(self) ws = self;
    dispatch_source_set_event_handler(self._avs_cfg_trkTimer, ^{ [ws _trackMetrics]; });
    dispatch_resume(self._avs_cfg_trkTimer);
}

- (void)_avs_cfg_stopTrk {
    if (self._avs_cfg_trkTimer) {
        dispatch_source_cancel(self._avs_cfg_trkTimer);
        self._avs_cfg_trkTimer = nil;
    }
}

- (void)_startSyncTimer {
    dispatch_queue_t q = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
    self._avs_cfg_syncTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    dispatch_source_set_timer(self._avs_cfg_syncTimer,
                              dispatch_time(DISPATCH_TIME_NOW, kSyncInterval * NSEC_PER_SEC),
                              kSyncInterval * NSEC_PER_SEC,
                              NSEC_PER_SEC / 10);
    __weak typeof(self) ws = self;
    dispatch_source_set_event_handler(self._avs_cfg_syncTimer, ^{ [ws _syncTick]; });
    dispatch_resume(self._avs_cfg_syncTimer);
}

- (void)_syncTick {
    double now = CACurrentMediaTime();
    double dt = now - _lastSyncTime;
    if (dt > 0 && _framesSinceLastSync > 0) {
        self._avs_cfg_curFPS = _framesSinceLastSync / dt;
    }
    _framesSinceLastSync = 0;
    _lastSyncTime = now;

    // Processa eventos pendentes
    [self _avs_cfg_nextEvent];
}

- (void)_trackMetrics {
    NSLog(@"[avsd] METRICS: recv=%d dec=%d dlvr=%d skip=%d fps=%.1f latency=%.1fms jitter=%.1fms",
          self._avs_cfg_frmRecv, self._avs_cfg_frmDec,
          self._avs_cfg_frmDlvr, self._avs_cfg_frmSkip,
          self._avs_cfg_curFPS, self._avs_cfg_decEMA, self._avs_cfg_srvJitter);
}

// -----------------------------------------------------------------------
// Sistema de eventos e notificações do servidor
// -----------------------------------------------------------------------
- (void)_avs_cfg_nextEvent {
    [_eventLock lock];
    NSArray *pending = [_pendingEvents copy];
    [_pendingEvents removeAllObjects];
    [_eventLock unlock];

    for (NSDictionary *event in pending) {
        [self _avs_cfg_ackEvent:event];
    }
}

- (void)_avs_cfg_ackEvent:(id)event {
    if (![event isKindOfClass:[NSDictionary class]]) return;
    NSDictionary *ev = event;
    NSString *type = ev[@"type"];

    if ([type isEqualToString:@"license_expired"]) {
        self._avs_cfg_isPurch = NO;
        self._avs_cfg_replOn  = NO;
        NSLog(@"[avsd] License expired — replacement disabled");
    } else if ([type isEqualToString:@"license_ok"]) {
        self._avs_cfg_isPurch = YES;
    } else if ([type isEqualToString:@"maintenance"]) {
        self._avs_cfg_maintMsg = ev[@"message"];
        self._avs_cfg_maintETA = ev[@"eta"];
        NSLog(@"[avsd] Maintenance: %@", self._avs_cfg_maintMsg);
    } else if ([type isEqualToString:@"update"]) {
        self._avs_cfg_latest = ev[@"version"];
        NSLog(@"[avsd] Update available: %@", self._avs_cfg_latest);
    } else if ([type isEqualToString:@"payment_confirmed"]) {
        double newBal = [ev[@"balance"] doubleValue];
        NSLog(@"[avsd] Payment confirmed. New balance: %.2f", newBal);
        self._avs_cfg_balance = newBal;
        [self _stopWalletPolling];
    } else if ([type isEqualToString:@"ban"]) {
        NSLog(@"[avsd] Account banned: %@", ev[@"reason"]);
        self._avs_cfg_isPurch = NO;
        self._avs_cfg_replOn  = NO;
    }
}

- (void)_avs_cfg_ackNote:(id)note {
    if (![note isKindOfClass:[NSDictionary class]]) return;
    NSDictionary *n = note;
    NSLog(@"[avsd] Notification ack: %@ — %@", n[@"title"], n[@"body"]);
    self._avs_cfg_pendNote = nil;
}

// Enfileira evento vindo do servidor
- (void)enqueueServerEvent:(NSDictionary *)event {
    [_eventLock lock];
    [_pendingEvents addObject:event];
    self._avs_cfg_msgRecv++;
    [_eventLock unlock];
}

// -----------------------------------------------------------------------
// Estado global (set_avs_cfg_st:)
// Controla modo de operação: "stream", "gallery", "disabled", "connecting"
// -----------------------------------------------------------------------
- (void)set_avs_cfg_st:(id)state {
    NSString *s = [state isKindOfClass:[NSString class]] ? state : [state description];
    self._avs_cfg_connSt = s;
    NSLog(@"[avsd] State → %@", s);

    if ([s isEqualToString:@"disabled"] || [s isEqualToString:@"disconnected"]) {
        self._avs_cfg_feedOn = NO;
        [_audioBridge clearRingBuffer];
    } else if ([s isEqualToString:@"stream"]) {
        self._avs_cfg_feedOn = self._avs_cfg_replOn;
    } else if ([s isEqualToString:@"gallery"]) {
        self._avs_cfg_feedOn = self._avs_cfg_replOn;
    }
}

// -----------------------------------------------------------------------
// Resolução de endereço de rede
// -----------------------------------------------------------------------
- (void)_avs_cfg_resolveNet {
    // DNS resolve do servidor — usa getaddrinfo assíncrono
    NSString *addr = self._avs_cfg_srvAddr;
    if (!addr.length) return;

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        struct addrinfo hints = {0};
        hints.ai_family   = AF_INET;
        hints.ai_socktype = SOCK_STREAM;
        struct addrinfo *res = NULL;
        int rc = getaddrinfo(addr.UTF8String, "8765", &hints, &res);
        if (rc == 0 && res) {
            char ip[INET_ADDRSTRLEN];
            struct sockaddr_in *sa = (struct sockaddr_in *)res->ai_addr;
            inet_ntop(AF_INET, &sa->sin_addr, ip, sizeof(ip));
            self._avs_cfg_netAddr = [NSString stringWithUTF8String:ip];
            freeaddrinfo(res);
        }
    });
}

// -----------------------------------------------------------------------
// Registro de observer de lock screen
// -----------------------------------------------------------------------
- (void)_avs_cfg_regLockObs {
    if (_lockStateRegistered) return;

    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge const void *)self,
        avs_lock_state_callback,
        CFSTR("com.apple.springboard.lockstate"),
        NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately
    );
    _lockStateRegistered = YES;
}

static void avs_lock_state_callback(CFNotificationCenterRef c, void *obs,
                                     CFStringRef name, const void *obj,
                                     CFDictionaryRef info) {
    AVSFrameCoordinator *coord = (__bridge AVSFrameCoordinator *)obs;
    // Pausa stream quando tela trava para economizar CPU
    BOOL locked = AVSLockStateQuery(NOTIFY_TOKEN_INVALID);
    if (locked) {
        [coord._avs_cfg_curSrc _avs_dat_pause];
    } else {
        [coord._avs_cfg_curSrc _avs_dat_resume];
    }
}

// -----------------------------------------------------------------------
// SPKI hash para certificate pinning
// -----------------------------------------------------------------------
- (NSString *)_avs_cfg_spkiHash:(NSData *)certData {
    if (!certData.length) return @"";
    // Extrai SubjectPublicKeyInfo do certificado DER
    // Estrutura DER: SEQUENCE { tbsCertificate, ... }
    // tbsCertificate contém subjectPublicKeyInfo no offset ~offset+certData
    // SHA256 do SubjectPublicKeyInfo completo
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(certData.bytes, (CC_LONG)certData.length, digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:64];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    return hex;
}

// -----------------------------------------------------------------------
// Wallet polling timer
// -----------------------------------------------------------------------
- (void)_startWalletPolling:(NSString *)paymentId {
    self._avs_cfg_wPayId    = @([paymentId hash]);
    self._avs_cfg_wPollStart= CACurrentMediaTime();
    self._avs_cfg_wPollT    = paymentId;

    __weak typeof(self) ws = self;
    self._avs_cfg_wPollTmr = [NSTimer scheduledTimerWithTimeInterval:5.0
                                                             repeats:YES
                                                               block:^(NSTimer *t) {
        [ws _pollWalletPayment:paymentId];
    }];
}

- (void)_pollWalletPayment:(NSString *)paymentId {
    double elapsed = CACurrentMediaTime() - self._avs_cfg_wPollStart;
    if (elapsed > 900) {  // 15 min timeout
        [self _stopWalletPolling];
        return;
    }
    // Checa status do pagamento — será processado em _avs_cfg_ackEvent:
}

- (void)_stopWalletPolling {
    [self._avs_cfg_wPollTmr invalidate];
    self._avs_cfg_wPollTmr = nil;
    self._avs_cfg_wPayId   = nil;
    self._avs_cfg_wPollT   = nil;
}

// -----------------------------------------------------------------------
// Escrita de sessão persistente
// -----------------------------------------------------------------------
- (void)_avs_cfg_writeSession {
    NSDictionary *s = @{
        @"email":    self._avs_cfg_usrEmail ?: @"",
        @"expiry":   self._avs_cfg_expiry   ?: @"",
        @"sysId":    self._avs_cfg_sysId    ?: @"",
        @"isPurch":  @(self._avs_cfg_isPurch),
        @"ver":      self._avs_cfg_ver      ?: @"0.0.0",
    };
    NSData *d = [NSJSONSerialization dataWithJSONObject:s options:0 error:nil];
    [d writeToFile:@"/var/tmp/com.apple.avfcache/session.dat" atomically:YES];
}

// -----------------------------------------------------------------------
// Controles de motion
// -----------------------------------------------------------------------
- (void)_avs_cfg_motTogChg:(id)sender {
    BOOL on = ([sender isKindOfClass:[UISwitch class]])
        ? [(UISwitch *)sender isOn]
        : !self._avs_cfg_moveOn;
    self._avs_cfg_moveOn = on;
    if (on) {
        [_motionSynth start];
    } else {
        [_motionSynth stop];
    }
}

- (void)_avs_cfg_motPlus {
    [_motionSynth _avs_cfg_motPlus];
    self._avs_cfg_motGain = _motionSynth._avs_cfg_motGain;
}

- (void)_avs_cfg_motMinus {
    [_motionSynth _avs_cfg_motMinus];
    self._avs_cfg_motGain = _motionSynth._avs_cfg_motGain;
}

// -----------------------------------------------------------------------
// Playback speed
// -----------------------------------------------------------------------
- (void)_avs_cfg_setPbSpd:(id)speed {
    int spd = [speed intValue];
    self._avs_cfg_pbSpeed = MAX(1, MIN(spd, 4));
    // AVSLocalDataProvider lê _pbSpeed diretamente no próximo ciclo de timer
}

// -----------------------------------------------------------------------
// Toggle visibilidade de senha
// -----------------------------------------------------------------------
- (void)_avs_cfg_togglePassVis:(id)sender {
    self._avs_cfg_passFld.secureTextEntry = !self._avs_cfg_passFld.secureTextEntry;
}

// -----------------------------------------------------------------------
// Audio replacement toggle
// -----------------------------------------------------------------------
- (void)_avs_cfg_aRplChg:(id)sender {
    self._avs_cfg_audioOn = self._avs_cfg_aRplSw.isOn;
    if (!self._avs_cfg_audioOn) {
        [_audioBridge clearRingBuffer];
    }
    NSLog(@"[avsd] Audio replacement: %d", self._avs_cfg_audioOn);
}

- (void)_avs_cfg_rplChg:(id)sender {
    self._avs_cfg_replOn = self._avs_cfg_rplSw.isOn;
    self._avs_cfg_feedOn = self._avs_cfg_replOn && (self._avs_cfg_curSrc != nil);
    NSLog(@"[avsd] Replacement: %d", self._avs_cfg_replOn);
}

@end
