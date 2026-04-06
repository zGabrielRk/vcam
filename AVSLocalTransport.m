// AVSLocalTransport.m
// LordVCAM — Reconstruído via engenharia reversa de AVServicesd.dylib
// Transporte USB: conecta ao servidor LordVCAM via túnel localhost (usbmuxd)
// iPhone:8765 ↔ PC:8765 via iTunes port forwarding

#import "AVSLocalTransport.h"
#import "AVSFrameCoordinator.h"
#import "AVSWSProtocol.h"
#import <sys/socket.h>
#include <libkern/OSByteOrder.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <CommonCrypto/CommonCrypto.h>

// WebSocket handshake GUID (RFC 6455)
static NSString *const kWSGUID = @"258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

// Comprimento mínimo do header de frame binário LordVCAM:
// type(4) | seqnum(4) | flags(4) | width(4) | height(4) = 20 bytes
static const int kFrameHeaderLen = 20;

// Tamanho do buffer reutilizável de recepção (evita malloc/free a cada frame)
static const size_t kReuseBufferSize = 512 * 1024; // 512 KB

// Porta padrão (forwarded pelo usbmuxd do iTunes)
static const int kUSBPort = kAVSWSDefaultPort;

@interface AVSLocalTransport () {
    int          _sockfd;
    dispatch_queue_t _readQueue;
    dispatch_queue_t _writeQueue;
    BOOL         _handshakeDone;
    BOOL         _stopFlag;
    NSTimeInterval _lastLogTime;

    // Buffer reutilizável para payloads pequenos/médios (evita heap churn a 30fps)
    uint8_t     *_reuseBuffer;
    size_t       _reuseBufferLen;
}
@end

@implementation AVSLocalTransport

- (instancetype)init {
    self = [super init];
    if (self) {
        _sockfd          = -1;
        _isClientConnected = NO;
        _connectedViaUSB = NO;
        _currentPort     = kUSBPort;
        _handshakeDone   = NO;
        _stopFlag        = NO;
        _lastLogTime     = 0;
        _reuseBuffer    = malloc(kReuseBufferSize);
        _reuseBufferLen = kReuseBufferSize;
        _readQueue  = dispatch_queue_create("com.avsd.usb.read",  DISPATCH_QUEUE_SERIAL);
        _writeQueue = dispatch_queue_create("com.avsd.usb.write", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)dealloc {
    [self disconnect];
    free(_reuseBuffer);
}

// -----------------------------------------------------------------------
// Conecta via TCP (USB forwarding via usbmuxd)
// -----------------------------------------------------------------------
- (void)connectToAddress:(NSString *)address port:(int)port {
    [self disconnect];
    _stopFlag = NO;
    _handshakeDone = NO;

    self.currentIP   = address ?: @"127.0.0.1";
    self.currentPort = (port > 0) ? port : kUSBPort;
    self.connectedViaUSB = [self.currentIP isEqualToString:@"127.0.0.1"];

    dispatch_async(_readQueue, ^{
        [self _openSocket];
    });
}

- (void)_openSocket {
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port   = htons(self.currentPort);
    inet_pton(AF_INET, self.currentIP.UTF8String, &addr.sin_addr);

    _sockfd = socket(AF_INET, SOCK_STREAM, 0);
    if (_sockfd < 0) {
        NSLog(@"[avsd-usb] socket() failed: %d", errno);
        [self _onDisconnect];
        return;
    }

    // Timeout de conexão: 5s
    struct timeval tv = { .tv_sec = 5, .tv_usec = 0 };
    setsockopt(_sockfd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(_sockfd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

    if (connect(_sockfd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        NSLog(@"[avsd-usb] connect() failed: %d (is usbmuxd running?)", errno);
        close(_sockfd);
        _sockfd = -1;
        [self _onDisconnect];
        return;
    }

    NSLog(@"[avsd-usb] TCP connected to %@:%d", self.currentIP, self.currentPort);
    [self _sendWebSocketHandshake];
}

// -----------------------------------------------------------------------
// WebSocket Handshake (RFC 6455)
// -----------------------------------------------------------------------
- (void)_sendWebSocketHandshake {
    // Gera Sec-WebSocket-Key: 16 bytes aleatórios em Base64
    uint8_t keyBytes[16];
    arc4random_buf(keyBytes, sizeof(keyBytes));
    NSData *keyData = [NSData dataWithBytes:keyBytes length:sizeof(keyBytes)];
    NSString *wsKey = [keyData base64EncodedStringWithOptions:0];

    NSString *request = [NSString stringWithFormat:
        @"GET / HTTP/1.1\r\n"
        @"Host: %@:%d\r\n"
        @"Upgrade: websocket\r\n"
        @"Connection: Upgrade\r\n"
        @"Sec-WebSocket-Key: %@\r\n"
        @"Sec-WebSocket-Version: 13\r\n"
        @"\r\n",
        self.currentIP, self.currentPort, wsKey
    ];

    const char *reqStr = request.UTF8String;
    ssize_t sent = send(_sockfd, reqStr, strlen(reqStr), 0);
    if (sent <= 0) {
        NSLog(@"[avsd-usb] WebSocket handshake send failed");
        [self _onDisconnect];
        return;
    }

    // Lê resposta HTTP "101 Switching Protocols"
    char respBuf[1024] = {0};
    ssize_t recvd = recv(_sockfd, respBuf, sizeof(respBuf) - 1, 0);
    if (recvd <= 0) {
        NSLog(@"[avsd-usb] WebSocket handshake recv failed");
        [self _onDisconnect];
        return;
    }

    NSString *response = [NSString stringWithUTF8String:respBuf];
    if (![response containsString:@"101"] || ![response containsString:@"Switching Protocols"]) {
        NSLog(@"[avsd-usb] Unexpected HTTP response:\n%@", response);
        [self _onDisconnect];
        return;
    }

    // Valida Sec-WebSocket-Accept (RFC 6455 §4.1)
    NSString *acceptHeader = [self _extractHeader:@"Sec-WebSocket-Accept" from:response];
    NSString *expectedAccept = [self _computeWSAccept:wsKey];
    if (!acceptHeader || ![acceptHeader isEqualToString:expectedAccept]) {
        NSLog(@"[avsd-usb] Sec-WebSocket-Accept mismatch: got=%@ expected=%@",
              acceptHeader, expectedAccept);
        [self _onDisconnect];
        return;
    }

    _handshakeDone = YES;
    _isClientConnected = YES;
    NSLog(@"[avsd-usb] WebSocket handshake OK");

    // Inicia leitura contínua de frames
    [self _readLoop];
}

// -----------------------------------------------------------------------
// Loop de leitura de frames WebSocket
// -----------------------------------------------------------------------
- (void)_readLoop {
    while (!_stopFlag && _sockfd >= 0) {
        // Lê cabeçalho WebSocket (2+ bytes)
        uint8_t header[10];
        if (![self _recvExact:header length:2]) break;

        uint8_t opcode = header[0] & 0x0F;
        BOOL isMasked = (header[1] & 0x80) != 0;
        uint64_t payloadLen = header[1] & 0x7F;

        if (payloadLen == 126) {
            uint8_t ext[2];
            if (![self _recvExact:ext length:2]) break;
            payloadLen = ((uint64_t)ext[0] << 8) | ext[1];
        } else if (payloadLen == 127) {
            uint8_t ext[8];
            if (![self _recvExact:ext length:8]) break;
            payloadLen = 0;
            for (int i = 0; i < 8; i++)
                payloadLen = (payloadLen << 8) | ext[i];
        }

        // RFC 6455 §5.3: servidor NUNCA mascara frames para o cliente.
        // Frame mascarado é violação de protocolo — desconecta imediatamente.
        if (isMasked) {
            NSLog(@"[avsd-usb] Protocol error: server sent masked frame — disconnecting");
            break;
        }

        if (payloadLen == 0) continue;
        if (payloadLen > 4 * 1024 * 1024) {
            NSLog(@"[avsd-usb] Frame payload too large: %llu — draining", payloadLen);
            // Drena o payload para preservar o fluxo WebSocket
            uint8_t drain[4096];
            uint64_t remaining = payloadLen;
            BOOL drainOK = YES;
            while (remaining > 0 && !_stopFlag) {
                size_t chunk = (size_t)MIN(remaining, sizeof(drain));
                if (![self _recvExact:drain length:chunk]) { drainOK = NO; break; }
                remaining -= chunk;
            }
            if (!drainOK) break;
            continue;
        }

        // Reutiliza buffer; cresce com realloc apenas quando necessário
        size_t plen = (size_t)payloadLen;
        if (plen > _reuseBufferLen) {
            uint8_t *grown = realloc(_reuseBuffer, plen);
            if (!grown) break;
            _reuseBuffer    = grown;
            _reuseBufferLen = plen;
        }
        uint8_t *payload = _reuseBuffer;

        if (![self _recvExact:payload length:plen]) break;

        // Copia apenas para o NSData (não transfere ownership do buffer reutilizável)
        NSData *data = [NSData dataWithBytes:payload length:(NSUInteger)payloadLen];

        // Processa frame conforme opcode
        switch (opcode) {
            case 0x1: // Text (JSON)
                [self _handleTextFrame:data];
                break;
            case 0x2: // Binary (video/audio)
                [self _handleBinaryFrame:data];
                break;
            case 0x8: // Close
                NSLog(@"[avsd-usb] WS Close received");
                _stopFlag = YES;
                break;
            case 0x9: // Ping
                [self _sendPong:data];
                break;
            case 0xA: // Pong
                break;
            default:
                NSLog(@"[avsd-usb] Unknown opcode 0x%X", opcode);
                break;
        }

        // Fragmentação não suportada; frames LordVCAM são sempre enviados com FIN=1.
    }

    [self _onDisconnect];
}

// -----------------------------------------------------------------------
// Processamento de mensagens
// -----------------------------------------------------------------------
- (void)_handleTextFrame:(NSData *)data {
    NSError *err = nil;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
    if (!json) {
        NSLog(@"[avsd-usb] JSON parse error: %@", err);
        return;
    }

    NSString *type = json[@"type"];
    if ([type isEqualToString:kAVSWSMsgPing]) {
        [self _sendJSON:@{@"type": kAVSWSMsgPong}];
    } else if ([type isEqualToString:kAVSWSMsgPong]) {
        // latência medida externamente
    } else if ([type isEqualToString:kAVSWSMsgDisconnect]) {
        NSLog(@"[avsd-usb] Server requested disconnect");
        _stopFlag = YES;
    } else {
        // Repassa ao coordinator via notificação
        [[NSNotificationCenter defaultCenter]
            postNotificationName:@"com.avsd.transport.json"
                          object:nil
                        userInfo:json];
    }
}

- (void)_handleBinaryFrame:(NSData *)data {
    if (data.length < kFrameHeaderLen) return;

    const uint8_t *bytes = data.bytes;
    uint32_t type   = OSReadLittleInt32(bytes,  0);
    uint32_t seqnum = OSReadLittleInt32(bytes,  4);
    uint32_t flags  = OSReadLittleInt32(bytes,  8);
    uint32_t width  = OSReadLittleInt32(bytes, 12);
    uint32_t height = OSReadLittleInt32(bytes, 16);

    NSData *payload = [data subdataWithRange:NSMakeRange(kFrameHeaderLen,
                                                          data.length - kFrameHeaderLen)];

    NSDictionary *info = @{
        @"type":    @(type),
        @"seqnum":  @(seqnum),
        @"flags":   @(flags),
        @"width":   @(width),
        @"height":  @(height),
        @"payload": payload,
    };

    [[NSNotificationCenter defaultCenter]
        postNotificationName:@"com.avsd.transport.frame"
                      object:nil
                    userInfo:info];
}

// -----------------------------------------------------------------------
// Envio
// -----------------------------------------------------------------------
- (void)_sendJSON:(NSDictionary *)json {
    NSData *data = [NSJSONSerialization dataWithJSONObject:json options:0 error:nil];
    if (data) [self _sendWSFrame:data opcode:0x1];
}

- (void)_sendPong:(NSData *)payload {
    [self _sendWSFrame:payload opcode:0xA];
}

- (void)_sendWSFrame:(NSData *)payload opcode:(uint8_t)opcode {
    // Captura _sockfd antes do dispatch: disconnect() pode zerá-lo em paralelo.
    int fd = _sockfd;
    if (fd < 0 || !_handshakeDone) return;

    dispatch_async(_writeQueue, ^{
        NSUInteger len = payload.length;
        NSMutableData *frame = [NSMutableData dataWithCapacity:len + 10];

        uint8_t byte0 = 0x80 | (opcode & 0x0F); // FIN + opcode
        [frame appendBytes:&byte0 length:1];

        if (len < 126) {
            uint8_t byte1 = (uint8_t)len;
            [frame appendBytes:&byte1 length:1];
        } else if (len < 65536) {
            uint8_t byte1 = 126;
            [frame appendBytes:&byte1 length:1];
            uint16_t ext = htons((uint16_t)len);
            [frame appendBytes:&ext length:2];
        } else {
            uint8_t byte1 = 127;
            [frame appendBytes:&byte1 length:1];
            uint64_t ext = OSSwapHostToBigInt64((uint64_t)len);
            [frame appendBytes:&ext length:8];
        }

        [frame appendData:payload];

        send(fd, frame.bytes, frame.length, 0);
    });
}

// -----------------------------------------------------------------------
// Desconexão
// -----------------------------------------------------------------------
- (void)disconnect {
    _stopFlag = YES;
    if (_sockfd >= 0) {
        shutdown(_sockfd, SHUT_RDWR);
        close(_sockfd);
        _sockfd = -1;
    }
    _isClientConnected = NO;
    _handshakeDone = NO;
}

- (void)stopUSBConnection {
    NSLog(@"[avsd-usb] Stopping USB connection");
    [self disconnect];
}

- (void)_onDisconnect {
    BOOL wasConnected = _isClientConnected;
    [self disconnect];
    if (wasConnected) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter]
                postNotificationName:@"com.avsd.transport.disconnected"
                              object:nil];
        });
    }
}

// -----------------------------------------------------------------------
// Auxiliares
// -----------------------------------------------------------------------
- (BOOL)_recvExact:(uint8_t *)buf length:(size_t)len {
    size_t received = 0;
    while (received < len && !_stopFlag) {
        ssize_t n = recv(_sockfd, buf + received, len - received, 0);
        if (n <= 0) return NO;
        received += n;
    }
    return received == len;
}

- (NSString *)_extractHeader:(NSString *)name from:(NSString *)response {
    NSString *prefix = [name stringByAppendingString:@": "];
    NSRange range = [response rangeOfString:prefix options:NSCaseInsensitiveSearch];
    if (range.location == NSNotFound) return nil;

    NSUInteger start = range.location + range.length;
    NSRange end = [response rangeOfString:@"\r\n" options:0
                                    range:NSMakeRange(start, response.length - start)];
    if (end.location == NSNotFound) return nil;

    return [response substringWithRange:NSMakeRange(start, end.location - start)];
}

// Calcula Sec-WebSocket-Accept = Base64(SHA1(key + GUID))
- (NSString *)_computeWSAccept:(NSString *)key {
    NSString *combined = [key stringByAppendingString:kWSGUID];
    const char *cStr = combined.UTF8String;
    uint8_t digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(cStr, (CC_LONG)strlen(cStr), digest);
    NSData *sha1Data = [NSData dataWithBytes:digest length:CC_SHA1_DIGEST_LENGTH];
    return [sha1Data base64EncodedStringWithOptions:0];
}

- (void)setLastLogTime:(NSTimeInterval)time {
    _lastLogTime = time;
}

@end
