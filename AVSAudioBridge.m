// AVSAudioBridge.m
// LordVCAM — Reconstruído via engenharia reversa de AVServicesd.dylib
// Ring buffer de áudio PCM para substituição do microfone

#import "AVSAudioBridge.h"
#import <Accelerate/Accelerate.h>

static const int kRingBufferSize = 48000 * 2 * 2; // 2s @ 48kHz stereo

@implementation AVSAudioBridge {
    float   *_ringBuffer;
    int      _writePos;
    int      _readPos;
    int      _available;
    int      _audioCredit;
    NSLock  *_lock;
}
@synthesize _sourceChannels;

- (instancetype)init {
    self = [super init];
    if (self) {
        _ringBuffer = (float *)calloc(kRingBufferSize, sizeof(float));
        _writePos = 0;
        _readPos  = 0;
        _available = 0;
        _audioCredit = 0;
        _lock = [[NSLock alloc] init];
        _audioSampleRate = 44100.0;
        _sourceChannels = 1;
        _isActive = NO;
    }
    return self;
}

- (void)dealloc {
    free(_ringBuffer);
}

// -----------------------------------------------------------------------
// Feed: escreve amostras PCM recebidas da rede no ring buffer
// Chamado quando o servidor envia um pacote de áudio
// -----------------------------------------------------------------------
- (BOOL)_avs_ab_feed:(const float *)samples
               count:(int)count
            channels:(int)ch
          sampleRate:(double)rate {
    if (!samples || count <= 0) return NO;

    [_lock lock];

    // Reamostrar se necessário (rate != _audioSampleRate)
    // (simplificado: assume mesmo sample rate por ora)

    // Interleave/deinterleave se necessário
    int totalSamples = count * ch;
    if (totalSamples > kRingBufferSize - _available) {
        // Buffer cheio: descarta amostras mais antigas
        int toDiscard = totalSamples - (kRingBufferSize - _available);
        _readPos = (_readPos + toDiscard) % kRingBufferSize;
        _available -= toDiscard;
    }

    for (int i = 0; i < totalSamples; i++) {
        _ringBuffer[_writePos] = samples[i];
        _writePos = (_writePos + 1) % kRingBufferSize;
    }
    _available += totalSamples;
    _audioCredit = MIN(_audioCredit + count, 48000);

    [_lock unlock];
    return YES;
}

// -----------------------------------------------------------------------
// Consume: lê amostras do ring buffer para entrega ao sistema de áudio
// Chamado pelo hook do microfone em mediaserverd
// -----------------------------------------------------------------------
- (BOOL)_avs_ab_consume:(float *)output
                  count:(int)count
               channels:(int)ch
             sampleRate:(double)rate {
    if (!output || count <= 0) return NO;
    if (!_isActive || _audioCredit <= 0) {
        // Sem dados: preenche com silêncio
        memset(output, 0, count * ch * sizeof(float));
        return NO;
    }

    [_lock lock];

    int needed = count * ch;
    if (_available < needed) {
        // Dados insuficientes: preenche resto com silêncio
        int avail = _available;
        for (int i = 0; i < avail; i++) {
            output[i] = _ringBuffer[_readPos];
            _readPos = (_readPos + 1) % kRingBufferSize;
        }
        memset(output + avail, 0, (needed - avail) * sizeof(float));
        _available = 0;
    } else {
        for (int i = 0; i < needed; i++) {
            output[i] = _ringBuffer[_readPos];
            _readPos = (_readPos + 1) % kRingBufferSize;
        }
        _available -= needed;
    }

    _audioCredit = MAX(0, _audioCredit - count);

    [_lock unlock];
    return YES;
}

// -----------------------------------------------------------------------
// Limpa o ring buffer
// -----------------------------------------------------------------------
- (void)clearRingBuffer {
    [_lock lock];
    memset(_ringBuffer, 0, kRingBufferSize * sizeof(float));
    _writePos = 0;
    _readPos  = 0;
    _available = 0;
    [_lock unlock];
}

- (void)clearRingLocked {
    // Versão sem lock (chamar apenas quando já com lock externo)
    memset(_ringBuffer, 0, kRingBufferSize * sizeof(float));
    _writePos = 0;
    _readPos  = 0;
    _available = 0;
}

- (void)clearLastOutput {
    _audioCredit = 0;
}

- (void)setAudioCredit:(int)credit {
    [_lock lock];
    _audioCredit = credit;
    [_lock unlock];
}

@end
