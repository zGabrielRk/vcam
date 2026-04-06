// VCDefaultStrategy.m
// LordVCAM — Reconstruído via engenharia reversa de AVServicesd.dylib
// Estratégia padrão de conexão: reconnect com backoff exponencial

#import "VCDefaultStrategy.h"

static const int    kMaxReconnectDefault = 10;
static const double kBaseDelayDefault    = 2.0;   // 2s, 4s, 8s, 16s...
static const double kMaxDelay            = 60.0;  // teto de 60s
static const double kConnTimeoutDefault  = 15.0;

@implementation VCDefaultStrategy {
    NSInteger _timeouts;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _reconnectEnabled     = YES;
        _maxReconnectAttempts  = kMaxReconnectDefault;
        _reconnectBaseDelay   = kBaseDelayDefault;
        _connectionTimeout    = kConnTimeoutDefault;
        _lastStallCheckTime   = 0;
        _timeouts             = 0;
    }
    return self;
}

- (NSInteger)timeouts {
    return _timeouts;
}

- (BOOL)shouldReconnectAfterError:(NSError *)error attempt:(int)attempt {
    if (!_reconnectEnabled) return NO;
    if (attempt >= _maxReconnectAttempts) return NO;

    // Erros fatais (auth, ban) — não reconectar
    NSInteger code = error.code;
    if (code == 401 || code == 403 || code == 410) return NO;

    return YES;
}

- (NSTimeInterval)reconnectDelayForAttempt:(int)attempt {
    // Backoff exponencial com jitter: base * 2^attempt + random(0..1)
    double delay = _reconnectBaseDelay * pow(2.0, attempt);
    if (delay > kMaxDelay) delay = kMaxDelay;
    delay += ((double)arc4random() / UINT32_MAX); // jitter 0-1s
    return delay;
}

- (void)scheduleReconnectForTransport:(id)transport {
    // Chamado pelo AVSStreamTransport quando a conexão cai.
    // O transport gerencia o timer e chama connect após o delay.
    _timeouts++;
}

- (void)resetCounters {
    _timeouts = 0;
    _lastStallCheckTime = 0;
}

@end
