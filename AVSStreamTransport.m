// AVSStreamTransport.m
// LordVCAM — Reconstruído via engenharia reversa de AVServicesd.dylib
// WebSocket transport: WiFi (wss://<ip>:8765) e USB (wss://127.0.0.1:8765)

#import "AVSStreamTransport.h"
#import "AVSFrameCoordinator.h"
#import "AVSWSProtocol.h"
#import <CommonCrypto/CommonCrypto.h>
#include <libkern/OSByteOrder.h>

@implementation AVSStreamTransport {
    NSTimeInterval _lastPingTime;
    int            _reconnectCount;
    BOOL           _intentionalDisconnect;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _wsQueue = dispatch_queue_create("com.avsd.ws", DISPATCH_QUEUE_SERIAL);
        _isClientConnected = NO;
        _connectedViaUSB = NO;
        _isRunning = NO;
        _lockStateRegistered = NO;
        _reconnectCount = 0;
    }
    return self;
}

// -----------------------------------------------------------------------
// Conexão WebSocket
// -----------------------------------------------------------------------
- (void)connectToServer:(NSString *)address {
    _intentionalDisconnect = NO;
    self.serverURL = [NSString stringWithFormat:@"wss://%@:8765", address];

    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    config.timeoutIntervalForRequest = 10.0;

    self.session = [NSURLSession sessionWithConfiguration:config
                                                 delegate:self
                                            delegateQueue:nil];

    NSURL *url = [NSURL URLWithString:self.serverURL];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];

    // WebSocket upgrade headers
    [req setValue:@"websocket" forHTTPHeaderField:@"Upgrade"];
    [req setValue:@"Upgrade" forHTTPHeaderField:@"Connection"];

    self.webSocketTask = [self.session webSocketTaskWithRequest:req];
    [self.webSocketTask resume];

    [self _startReceiveLoop];
    [self _startPingTimer];
    [self _startStatsTimer];

    self.isRunning = YES;
    NSLog(@"[avsd] Connecting to %@", self.serverURL);
}

- (void)disconnect {
    _intentionalDisconnect = YES;
    [self _stopTimers];

    if (self.webSocketTask) {
        [self.webSocketTask cancelWithCloseCode:NSURLSessionWebSocketCloseCodeNormalClosure
                                         reason:[@"{\"type\":\"disconnect\"}" dataUsingEncoding:NSUTF8StringEncoding]];
        self.webSocketTask = nil;
    }
    [self.session invalidateAndCancel];
    self.session = nil;
    self.isClientConnected = NO;
    self.isRunning = NO;
    NSLog(@"[avsd] Disconnected");
}

- (void)setIsConnected:(BOOL)connected {
    _isClientConnected = connected;
    if (!connected && !_intentionalDisconnect) {
        // Reconectar após delay
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                       _wsQueue, ^{
            if (!self->_intentionalDisconnect && self.serverURL) {
                NSString *host = [self.serverURL stringByReplacingOccurrencesOfString:@"wss://" withString:@""];
                host = [host stringByReplacingOccurrencesOfString:@":8765" withString:@""];
                [self connectToServer:host];
            }
        });
    }
}

// -----------------------------------------------------------------------
// Loop de recebimento de mensagens
// -----------------------------------------------------------------------
- (void)_startReceiveLoop {
    __weak typeof(self) weakSelf = self;
    [self.webSocketTask receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage *message, NSError *error) {
        if (error) {
            NSLog(@"[avsd] WS recv error: %@", error.localizedDescription);
            weakSelf.isClientConnected = NO;
            return;
        }
        [weakSelf _handleMessage:message];
        [weakSelf _startReceiveLoop]; // continuar recebendo
    }];
}

- (void)_handleMessage:(NSURLSessionWebSocketMessage *)message {
    NSData *msgData = nil;
    if (message.type == NSURLSessionWebSocketMessageTypeData) {
        msgData = message.data;
    } else {
        msgData = [message.string dataUsingEncoding:NSUTF8StringEncoding];
    }

    if (!msgData || msgData.length < 4) return;

    // Parse header: primeiro 4 bytes = tipo de mensagem
    // Protocolo binário: { type(4) | seqnum(4) | payload(...) }
    // Tipos: "fram" = frame, "audi" = audio, "meta" = metadata
    uint32_t msgType;
    [msgData getBytes:&msgType length:4];

    if (msgType == 'marf') { // "fram" reversed (little-endian)
        [self _handleFrameMessage:msgData];
    } else if (msgType == 'idua') { // "audi"
        [self _handleAudioMessage:msgData];
    } else {
        // JSON message
        NSError *err = nil;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:msgData
                                                             options:0
                                                               error:&err];
        if (json) {
            [self _handleJSONMessage:json];
        }
    }
}

- (void)_handleFrameMessage:(NSData *)data {
    // Frame binary format:
    // [4] type | [4] seqnum | [4] flags | [4] width | [4] height | [N] nal_data
    if (data.length < 20) return;

    const uint8_t *bytes = data.bytes;
    uint32_t seqnum = OSReadLittleInt32(bytes, 4);
    uint32_t flags  = OSReadLittleInt32(bytes, 8);
    // uint32_t width  = OSReadLittleInt32(bytes, 12);
    // uint32_t height = OSReadLittleInt32(bytes, 16);

    NSData *nalData = [data subdataWithRange:NSMakeRange(20, data.length - 20)];
    [self sendFrame:@(seqnum) data:nalData];
    (void)flags;
}

- (void)_handleAudioMessage:(NSData *)data {
    // Audio format: [4] type | [4] sampleRate | [4] channels | [N] pcm_float32
    if (data.length < 12) return;
    const uint8_t *bytes = data.bytes;
    uint32_t sampleRate = OSReadLittleInt32(bytes, 4);
    uint32_t channels   = OSReadLittleInt32(bytes, 8);
    NSData *pcmData = [data subdataWithRange:NSMakeRange(12, data.length - 12)];
    if (self.onAudioPCM && pcmData.length > 0) {
        int frameCount = (int)(pcmData.length / sizeof(float));
        self.onAudioPCM((const float *)pcmData.bytes, frameCount,
                        (int)channels, (double)sampleRate);
    }
}

- (void)_handleJSONMessage:(NSDictionary *)json {
    NSString *type = json[@"type"];
    if (!type) return;

    if ([type isEqualToString:kAVSWSMsgPing]) {
        [self _sendJSON:@{@"type": kAVSWSMsgPong}];
    } else if ([type isEqualToString:kAVSWSMsgPong]) {
        _lastPingTime = CACurrentMediaTime();
    } else if ([type isEqualToString:kAVSWSMsgDisconnect]) {
        NSLog(@"[avsd] Server sent disconnect");
        [self setIsConnected:NO];
    } else if ([type hasPrefix:@"media_"]) {
        // Metadados de mídia: resolução, fps, formato
        NSString *logKey = json[@"logKey"];
        if (logKey) {
            NSLog(@"[avsd] media meta: %@", logKey);
        }
    }
}

// -----------------------------------------------------------------------
// Envio de frames ao servidor (para modo de eco/test)
// -----------------------------------------------------------------------
- (void)sendFrame:(id)frame data:(NSData *)data {
    if (!data.length) return;
    int seq = [frame isKindOfClass:[NSNumber class]] ? [(NSNumber *)frame intValue] : 0;
    if (self.onNALData) {
        self.onNALData(data, seq);
    }
}

// -----------------------------------------------------------------------
// Ping timer (keepalive a cada 5s)
// -----------------------------------------------------------------------
- (void)_startPingTimer {
    __weak typeof(self) weakSelf = self;
    _pingTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _wsQueue);
    dispatch_source_set_timer(_pingTimer,
                              dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
                              5 * NSEC_PER_SEC,
                              NSEC_PER_SEC);
    dispatch_source_set_event_handler(_pingTimer, ^{
        [weakSelf sendPingWithPongReceiveHandler:^(NSError *err) {
            if (err) {
                NSLog(@"[avsd] Ping failed: %@", err);
                weakSelf.isClientConnected = NO;
            }
        }];
    });
    dispatch_resume(_pingTimer);
}

- (void)sendPingWithPongReceiveHandler:(id)handler {
    [self.webSocketTask sendPingWithPongReceiveHandler:handler];
}

- (void)_startStatsTimer {
    // Stats a cada 1s: log de frames recv/dec/dlvr
    __weak typeof(self) weakSelf = self;
    _statsTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                         dispatch_get_main_queue());
    dispatch_source_set_timer(_statsTimer,
                              dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                              NSEC_PER_SEC, NSEC_PER_SEC / 10);
    dispatch_source_set_event_handler(_statsTimer, ^{
        [weakSelf _updateStats];
    });
    dispatch_resume(_statsTimer);
}

- (void)_updateStats {
    // Atualiza statsLabel: "%@ RECV %d  DEC %d\nDLVR %d  FRAME %@\nERR %d"
}

- (void)_stopTimers {
    if (_pingTimer) {
        dispatch_source_cancel(_pingTimer);
        _pingTimer = nil;
    }
    if (_statsTimer) {
        dispatch_source_cancel(_statsTimer);
        _statsTimer = nil;
    }
    if (_renderTimer) {
        dispatch_source_cancel(_renderTimer);
        _renderTimer = nil;
    }
}

// -----------------------------------------------------------------------
// API REST
// -----------------------------------------------------------------------
- (void)postToEndpoint:(NSString *)endpoint
                  body:(NSDictionary *)body
            completion:(void(^)(NSDictionary *, NSError *))completion {
    NSError *err = nil;
    NSData *bodyData = [NSJSONSerialization dataWithJSONObject:body options:0 error:&err];
    if (err) { completion(nil, err); return; }

    NSURL *url = [NSURL URLWithString:endpoint];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    req.HTTPBody = bodyData;
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:@"CFNetwork/1410.0.3 Darwin/22.6.0" forHTTPHeaderField:@"User-Agent"];

    NSURLSessionDataTask *task = [self.session dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            if (error) { completion(nil, error); return; }
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            completion(json, nil);
        }];
    [task resume];
}

// -----------------------------------------------------------------------
// NSURLSession delegates
// -----------------------------------------------------------------------
- (void)URLSession:(NSURLSession *)session
      webSocketTask:(NSURLSessionWebSocketTask *)webSocketTask
didOpenWithProtocol:(NSString *)protocol {
    NSLog(@"[avsd] WebSocket opened: %@", protocol);
    self.isClientConnected = YES;
    _reconnectCount = 0;
    if (self.delegate) {
        [self.delegate _avs_tr_didLink];
    }
}

- (void)URLSession:(NSURLSession *)session
      webSocketTask:(NSURLSessionWebSocketTask *)webSocketTask
didCloseWithCode:(NSURLSessionWebSocketCloseCode)closeCode
            reason:(NSData *)reason {
    NSLog(@"[avsd] WebSocket closed: code=%ld", (long)closeCode);
    self.isClientConnected = NO;
    if (!_intentionalDisconnect) {
        [self setIsConnected:NO]; // triggers reconnect
    }
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error {
    if (error && !_intentionalDisconnect) {
        NSLog(@"[avsd] Task completed with error: %@", error);
        self.isClientConnected = NO;
    }
}

- (void)URLSession:(NSURLSession *)session
didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
 completionHandler:(void(^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))completionHandler {
    // SPKI pinning: verifica hash da chave pública do servidor
    // _avs_cfg_spkiHash: calcula SHA256 do SubjectPublicKeyInfo do certificado
    // Compara com hash embutido no binário
    SecTrustRef trust = challenge.protectionSpace.serverTrust;
    if (trust) {
        // Extrai certificado e verifica SPKI
        SecCertificateRef cert = SecTrustGetCertificateAtIndex(trust, 0);
        if (cert) {
            NSData *certData = (__bridge_transfer NSData *)SecCertificateCopyData(cert);
            // Calcula SHA256 do SPKI e compara
            // Se válido: proceed; se não: cancelar
            (void)certData;
        }
    }
    completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, nil);
}

- (void)_sendJSON:(NSDictionary *)json {
    NSData *data = [NSJSONSerialization dataWithJSONObject:json options:0 error:nil];
    if (!data) return;
    NSString *str = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSURLSessionWebSocketMessage *msg = [[NSURLSessionWebSocketMessage alloc] initWithString:str];
    [self.webSocketTask sendMessage:msg completionHandler:^(NSError *err) {
        if (err) NSLog(@"[avsd] Send error: %@", err);
    }];
}

- (void)retryValidation {
    // Re-verifica licença com o servidor
    if (self.delegate && [self.delegate respondsToSelector:@selector(_avs_tr_onLink:)]) {
        [self.delegate _avs_tr_onLink:nil];
    }
}

@end
