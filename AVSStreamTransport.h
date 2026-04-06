// AVSStreamTransport.h
// LordVCAM - Reconstructed via reverse engineering of AVServicesd.dylib
// Mach-O arm64 universal binary, CydiaSubstrate tweak for jailbroken iOS

#import <Foundation/Foundation.h>
#import "AVSTransportDelegate.h"

@class VCDefaultStrategy;

// NSURLSession WebSocket-based transport layer
// Connects to LordVCAM Server on PC via WiFi (port 8765) or USB
@interface AVSStreamTransport : NSObject
    <NSURLSessionWebSocketDelegate,
     NSURLSessionTaskDelegate,
     NSURLSessionDelegate>

@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSURLSessionWebSocketTask *webSocketTask;
@property (nonatomic, strong) NSObject<OS_dispatch_queue> *wsQueue;
@property (nonatomic, strong) NSObject<OS_dispatch_source> *pingTimer;
@property (nonatomic, strong) NSObject<OS_dispatch_source> *statsTimer;
@property (nonatomic, strong) NSObject<OS_dispatch_source> *renderTimer;
@property (nonatomic, strong) NSString *serverURL;
@property (nonatomic, copy)   NSString *currentIP;
@property (nonatomic, assign) BOOL isClientConnected;
@property (nonatomic, assign) BOOL connectedViaUSB;
@property (nonatomic, assign) BOOL isRunning;
@property (nonatomic, assign) BOOL lockStateRegistered;
@property (nonatomic, weak)   id<AVSTransportDelegate> delegate;
@property (nonatomic, strong) VCDefaultStrategy *connectionStrategy;

// Connection management
- (void)connectToServer:(NSString *)address;
- (void)disconnect;
- (void)setIsConnected:(BOOL)connected;
- (void)retryValidation;

// Callbacks set by the coordinator on connection
@property (nonatomic, copy) void(^onNALData)(NSData *nalData, int seqnum);
@property (nonatomic, copy) void(^onAudioPCM)(const float *samples, int count, int channels, double rate);

// Frame/audio delivery
- (void)sendFrame:(id)frame data:(NSData *)data;
- (void)sendPingWithPongReceiveHandler:(id)handler;

// Pop latest received frame (used by coordinator)
- (NSData *)_avs_str_popLatest;

// WebSocket upgrade (USB/local mode)
// Handshake: HTTP/1.1 101 Switching Protocols
// Sec-WebSocket-Accept computed with SHA1(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")
- (void)postToEndpoint:(NSString *)endpoint body:(NSDictionary *)body completion:(void(^)(NSDictionary *, NSError *))completion;

// NSURLSession delegate callbacks
- (void)URLSession:(NSURLSession *)session webSocketTask:(NSURLSessionWebSocketTask *)webSocketTask didOpenWithProtocol:(NSString *)protocol;
- (void)URLSession:(NSURLSession *)session webSocketTask:(NSURLSessionWebSocketTask *)webSocketTask didCloseWithCode:(NSURLSessionWebSocketCloseCode)closeCode reason:(NSData *)reason;
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error;
- (void)URLSession:(NSURLSession *)session didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge completionHandler:(void(^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))completionHandler;

@end
