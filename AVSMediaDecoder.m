// AVSMediaDecoder.m
// LordVCAM — Reconstruído via engenharia reversa de AVServicesd.dylib
// Decodificador H.264/H.265 usando VideoToolbox VTDecompressionSession

#import "AVSMediaDecoder.h"
#import <VideoToolbox/VideoToolbox.h>
#import <CoreMedia/CoreMedia.h>
#import <QuartzCore/QuartzCore.h>

// Mapeamento de formato detectado nos cstrings:
// "420v" = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
// "420f" = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
// "BGRA" = kCVPixelFormatType_32BGRA
// "p420" = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange (HEVC)
// "pf20" = kCVPixelFormatType_420YpCbCr10BiPlanarFullRange  (HEVC)

@implementation AVSMediaDecoder {
    CMVideoFormatDescriptionRef _formatDesc;
    _Atomic(int)                 _pendingFrames;
    NSLock                      *_sessionLock;
    BOOL                         _needsRecreate;
    uint8_t                     *_paramBuf;
    size_t                       _paramBufLen;
    NSString                    *_formatTag;  // "420v", "420f", etc.
    CMVideoFormatDescriptionRef  _cachedWrapFmtDesc;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _session = NULL;
        _isReady = NO;
        _isRunning = NO;
        _sessionLock = [[NSLock alloc] init];
        _pendingFrames = 0;
    }
    return self;
}

- (void)dealloc {
    [self _destroySession];
    if (_formatDesc) {
        CFRelease(_formatDesc);
        _formatDesc = NULL;
    }
    if (_cachedWrapFmtDesc) {
        CFRelease(_cachedWrapFmtDesc);
        _cachedWrapFmtDesc = NULL;
    }
    free(_paramBuf);
}

// -----------------------------------------------------------------------
// Processo de um NAL unit (H.264 / H.265)
// -----------------------------------------------------------------------
- (void)_avs_dec_process:(NSData *)nalData sequenceNumber:(int)seq {
    if (!nalData || nalData.length < 5) return;

    const uint8_t *bytes = nalData.bytes;

    // Detecta SPS/PPS para H.264 (NAL type 7/8) ou VPS/SPS/PPS para H.265
    uint8_t nalType = bytes[4] & 0x1F;         // H.264: bits 0-4 do primeiro byte após start code
    uint8_t hevcNalType = (bytes[4] >> 1) & 0x3F; // H.265

    BOOL isSPS = (nalType == 7) || (hevcNalType == 33);
    BOOL isPPS = (nalType == 8) || (hevcNalType == 34);
    BOOL isVPS = (hevcNalType == 32);

    if (isSPS) {
        self.spsData = [nalData subdataWithRange:NSMakeRange(4, nalData.length - 4)];
        return;
    }
    if (isPPS) {
        self.ppsData = [nalData subdataWithRange:NSMakeRange(4, nalData.length - 4)];
        // Quando temos SPS+PPS, recria a sessão
        if (self.spsData) {
            [self _avs_dec_recreateFromSPS:self.spsData pps:self.ppsData];
        }
        return;
    }
    if (isVPS) {
        // H.265: armazena VPS
        return;
    }

    [self _avs_dec_processInt:nalData sequenceNumber:seq];
}

// Envia um frame NAL para decodificação na VTDecompressionSession
- (void)_avs_dec_processInt:(NSData *)nalData sequenceNumber:(int)seq {
    if (!_session || !_formatDesc) {
        return;
    }

    [_sessionLock lock];

    // Converte Annex-B para AVCC: aloca CMBlockBuffer com cópia própria dos dados,
    // depois patch dos 4 bytes de start code in-place para AVCC length header.
    // O CMBlockBuffer gerencia sua própria memória — seguro para VT async decode.
    size_t nalLen = nalData.length;
    CMBlockBufferRef blockBuf = NULL;
    OSStatus st = CMBlockBufferCreateWithMemoryBlock(
        kCFAllocatorDefault,
        NULL,              // NULL = aloca buffer interno
        nalLen,
        kCFAllocatorDefault,
        NULL, 0, nalLen,
        kCMBlockBufferAssureMemoryNowFlag, &blockBuf
    );
    if (st == noErr) {
        st = CMBlockBufferReplaceDataBytes(nalData.bytes, blockBuf, 0, nalLen);
    }
    if (st == noErr) {
        // Patch start code (00 00 00 01) → AVCC length header (big-endian)
        uint32_t payloadLen = (uint32_t)(nalLen - 4);
        uint8_t hdr[4] = {
            (payloadLen >> 24) & 0xFF,
            (payloadLen >> 16) & 0xFF,
            (payloadLen >>  8) & 0xFF,
            (payloadLen      ) & 0xFF
        };
        st = CMBlockBufferReplaceDataBytes(hdr, blockBuf, 0, 4);
    }

    if (st != noErr) {
        [_sessionLock unlock];
        return;
    }

    // Cria CMSampleBuffer
    CMSampleBufferRef sampleBuf = NULL;
    const size_t sampleSizes[] = { nalLen };
    CMSampleTimingInfo timing = {
        .duration = CMTimeMake(1, 30),
        .presentationTimeStamp = CMTimeMake(seq, 30),
        .decodeTimeStamp = kCMTimeInvalid
    };

    st = CMSampleBufferCreateReady(
        kCFAllocatorDefault,
        blockBuf,
        _formatDesc,
        1, 1, &timing,
        1, sampleSizes,
        &sampleBuf
    );
    CFRelease(blockBuf);

    if (st != noErr) {
        [_sessionLock unlock];
        return;
    }

    // Decodifica
    VTDecodeFrameFlags flags = kVTDecodeFrame_EnableAsynchronousDecompression;
    VTDecodeInfoFlags infoFlags = 0;
    _pendingFrames++;

    st = VTDecompressionSessionDecodeFrame(
        _session,
        sampleBuf,
        flags,
        (void *)(intptr_t)seq,  // raw int — evita NSNumber autoreleased em decode async
        &infoFlags
    );

    CFRelease(sampleBuf);
    [_sessionLock unlock];

    if (st != noErr) {
        NSLog(@"[avsd] VTDecode error: %d seq=%d", st, seq);
    }
}

// -----------------------------------------------------------------------
// Recria VTDecompressionSession com novos parâmetros
// -----------------------------------------------------------------------
- (void)_avs_dec_recreate:(CMVideoFormatDescriptionRef)fmtDesc {
    [self _destroySession];

    // Invalida cache de format description do wrapper (formato mudou)
    if (_cachedWrapFmtDesc) {
        CFRelease(_cachedWrapFmtDesc);
        _cachedWrapFmtDesc = NULL;
    }

    _formatDesc = fmtDesc;
    CFRetain(_formatDesc);

    // Configurações de pixel buffer de saída
    NSDictionary *pbAttrs = @{
        (__bridge NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        (__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (__bridge NSString *)kCVPixelBufferOpenGLESCompatibilityKey: @YES,
        (__bridge NSString *)kCVPixelBufferMetalCompatibilityKey: @YES,
    };

    // Callback de saída de frame decodificado
    VTDecompressionOutputCallbackRecord callback = {
        .decompressionOutputCallback = _avs_dec_output_callback,
        .decompressionOutputRefCon   = (__bridge void *)self,
    };

    NSDictionary *sessAttrs = @{
        @"RequireHardwareAcceleratedVideoDecoder": @YES,
    };

    OSStatus st = VTDecompressionSessionCreate(
        kCFAllocatorDefault,
        _formatDesc,
        (__bridge CFDictionaryRef)sessAttrs,
        (__bridge CFDictionaryRef)pbAttrs,
        &callback,
        &_session
    );

    if (st == noErr) {
        _isReady = YES;
        NSLog(@"[avsd] VTDecompressionSession created OK");
    } else {
        NSLog(@"[avsd] VTDecompressionSession create failed: %d", st);
        _isReady = NO;
    }
}

- (void)_avs_dec_recreateFromSPS:(NSData *)sps pps:(NSData *)pps {
    // Monta CMFormatDescription a partir de SPS + PPS (H.264)
    const uint8_t *paramSets[2] = { sps.bytes, pps.bytes };
    size_t paramSizes[2] = { sps.length, pps.length };

    CMVideoFormatDescriptionRef fmt = NULL;
    OSStatus st = CMVideoFormatDescriptionCreateFromH264ParameterSets(
        kCFAllocatorDefault,
        2, paramSets, paramSizes,
        4, // NAL unit header length
        &fmt
    );

    if (st == noErr && fmt) {
        [self _avs_dec_recreate:fmt];
        CFRelease(fmt);
    } else {
        NSLog(@"[avsd] CMVideoFormatDescriptionCreateFromH264ParameterSets failed: %d", st);
    }
}

// Callback estático do VTDecompressionSession
static void _avs_dec_output_callback(
    void *refCon,
    void *frameRefCon,
    OSStatus status,
    VTDecodeInfoFlags infoFlags,
    CVImageBufferRef imageBuffer,
    CMTime presentationTimeStamp,
    CMTime presentationDuration
) {
    AVSMediaDecoder *decoder = (__bridge AVSMediaDecoder *)refCon;
    int seqNum = (int)(intptr_t)frameRefCon;

    decoder->_pendingFrames--;

    if (status != noErr || !imageBuffer) {
        NSLog(@"[avsd] Decode callback error: %d seq=%d", status, seqNum);
        return;
    }

    // Wrapa CVImageBuffer em CMSampleBuffer e chama o callback
    CMSampleBufferRef sampleBuf = [decoder _avs_dec_wrapBuf:(CVPixelBufferRef)imageBuffer];
    if (sampleBuf) {
        if (decoder._avs_cfg_onDec) {
            decoder._avs_cfg_onDec(sampleBuf);  // assinatura: void(^)(CMSampleBufferRef)
        }
        CFRelease(sampleBuf);
    }
}

// -----------------------------------------------------------------------
// Wrapa CVPixelBuffer em CMSampleBuffer para entrega
// -----------------------------------------------------------------------
- (CMSampleBufferRef)_avs_dec_wrapBuf:(CVPixelBufferRef)pixelBuffer {
    // Cache format description — only recreate when format changes
    // (decoder output format is constant for the lifetime of a VTDecompressionSession)
    if (!_cachedWrapFmtDesc) {
        CMVideoFormatDescriptionCreateForImageBuffer(
            kCFAllocatorDefault, pixelBuffer, &_cachedWrapFmtDesc);
    }
    if (!_cachedWrapFmtDesc) return NULL;

    CMSampleTimingInfo timing = {
        .duration = kCMTimeInvalid,
        .presentationTimeStamp = CMTimeMakeWithSeconds(CACurrentMediaTime(), 90000),
        .decodeTimeStamp = kCMTimeInvalid,
    };

    CMSampleBufferRef sampleBuf = NULL;
    OSStatus st = CMSampleBufferCreateForImageBuffer(
        kCFAllocatorDefault,
        pixelBuffer,
        YES,          // dataReady
        NULL, NULL,   // makeDataReadyCallback
        _cachedWrapFmtDesc,
        &timing,
        &sampleBuf
    );
    return (st == noErr) ? sampleBuf : NULL;
}

- (void)_destroySession {
    [_sessionLock lock];
    if (_session) {
        VTDecompressionSessionInvalidate(_session);
        CFRelease(_session);
        _session = NULL;
    }
    _isReady = NO;
    [_sessionLock unlock];
}

// -----------------------------------------------------------------------
// Identificação de formato
// -----------------------------------------------------------------------
- (NSString *)decoder {
    return _formatTag ?: @"Unknown";
}

- (NSString *)decoder_de {
    if (!_formatDesc) return @"decoder_de";
    CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(_formatDesc);
    CMVideoCodecType codec = CMFormatDescriptionGetMediaSubType(_formatDesc);
    NSString *codecStr = @"Unknown";
    if (codec == kCMVideoCodecType_H264)       codecStr = @"H264";
    else if (codec == kCMVideoCodecType_HEVC)  codecStr = @"H265";
    return [NSString stringWithFormat:@"decoder_de %@(%dx%d)", codecStr, dims.width, dims.height];
}

@end
