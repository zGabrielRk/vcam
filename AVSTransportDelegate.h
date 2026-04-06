// AVSTransportDelegate.h
// LordVCAM — Reconstruído via engenharia reversa de AVServicesd.dylib
// Protocolo delegate para AVSStreamTransport e AVSLocalTransport

#import <Foundation/Foundation.h>

@protocol AVSTransportDelegate <NSObject>

// Conexão estabelecida com o servidor/USB
- (void)_avs_tr_didLink;

// Conexão iniciada (recebe referência ao transport)
- (void)_avs_tr_onLink:(id)transport;

// Conexão perdida (recebe motivo/erro)
- (void)_avs_tr_didUnlink:(id)reason;

// Frame de vídeo recebido (NAL units H.264/H.265)
- (void)_avs_tr_didRecvData:(NSData *)data
              sequenceNumber:(int)seq
             serverTimestamp:(double)srvTs
            captureTimestamp:(double)capTs
               encodeTimeMs:(double)encMs;

// Áudio PCM recebido
- (void)_avs_tr_didRecvAudio:(NSData *)pcmData
                   sampleRate:(int)rate
                     channels:(int)channels;

@end
