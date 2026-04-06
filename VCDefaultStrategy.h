// VCDefaultStrategy.h
// LordVCAM — Reconstruído via engenharia reversa de AVServicesd.dylib
// Estratégia padrão de conexão: reconnect, timeout, fallback

#import <Foundation/Foundation.h>

@interface VCDefaultStrategy : NSObject

// Reconnect
@property (nonatomic, assign) BOOL reconnectEnabled;
@property (nonatomic, assign) int  maxReconnectAttempts;
@property (nonatomic, assign) double reconnectBaseDelay;   // segundos, com backoff exponencial

// Timeout
@property (nonatomic, assign) double connectionTimeout;    // segundos
@property (nonatomic, readonly) NSInteger timeouts;        // contador de timeouts

// Stall recovery
@property (nonatomic, assign) double lastStallCheckTime;

// Decide se deve reconectar após desconexão
- (BOOL)shouldReconnectAfterError:(NSError *)error attempt:(int)attempt;

// Calcula delay antes da próxima tentativa (backoff exponencial)
- (NSTimeInterval)reconnectDelayForAttempt:(int)attempt;

// Agenda reconexão no transport
- (void)scheduleReconnectForTransport:(id)transport;

// Reseta contadores
- (void)resetCounters;

@end
