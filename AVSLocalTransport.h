// AVSLocalTransport.h
// LordVCAM - Reconstructed via reverse engineering of AVServicesd.dylib
// USB transport: connects to LordVCAM PC server via localhost TCP tunnel
// Uses iTunes usbmuxd (port forwarded: iPhone:8765 -> PC:8765)

#import <Foundation/Foundation.h>

// Default USB connect: wss://127.0.0.1:8765
// Default WiFi connect: wss://<ip>:8765
// WebSocket frame protocol (from __cstring):
//   { "type": "frame", ... }     - video frame
//   { "type": "audio", "rate": N } - audio data
//   { "type": "ping" }
//   { "type": "pong" }
//   { "type": "disconnect" }
//   { "type": "media_..." }      - media info

@interface AVSLocalTransport : NSObject

@property (nonatomic, assign) BOOL connectedViaUSB;
@property (nonatomic, assign) BOOL isClientConnected;
@property (nonatomic, copy)   NSString *currentIP;
@property (nonatomic, assign) int  currentPort;  // default 8765

// Connection
- (void)connectToAddress:(NSString *)address port:(int)port;
- (void)disconnect;
- (void)stopUSBConnection;

// USB mode - opens WebSocket to 127.0.0.1:8765
// WiFi mode - opens WebSocket to <ip>:8765
// Sends sec-websocket-key, expects HTTP/1.1 101 Switching Protocols

// Metrics
- (void)setLastLogTime:(NSTimeInterval)time;

@end
