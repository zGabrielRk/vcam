# Engenharia Reversa — AVServicesd.dylib (LordVCAM)

## Identificação

| Campo | Valor |
|---|---|
| Arquivo | AVServicesd.dylib |
| Formato | Mach-O Fat Binary (arm64 + arm64e) |
| Magic | 0xCAFEBABE (Fat) |
| Slice arm64 | offset 0x4000, 917616 bytes |
| Slice arm64e | offset 0xE8000, 934064 bytes |
| Framework injetado via | CydiaSubstrate (Cydia Substrate / libhooker) |
| Produto | LordVCAM — câmera virtual para iOS jailbroken |
| Contato | t.me/LordVCAM / t.me/lordvcam777 |

---

## Arquitetura Geral

```
┌─────────────────────────────────────────────────────────┐
│                    AVServicesd.dylib                    │
│              (injetado via CydiaSubstrate)              │
├────────────────┬────────────────────────────────────────┤
│  PROCESSO      │  FUNCIONALIDADE                        │
│  mediaserverd  │  Hook AVFoundation pipeline            │
│                │  Injeta frames na câmera               │
│                │  Substitui áudio do microfone          │
├────────────────┼────────────────────────────────────────┤
│  SpringBoard   │  UI flutuante (painel de controle)     │
│                │  Botão shortcut (UIWindow overlay)     │
│                │  Notificações/banners                  │
├────────────────┼────────────────────────────────────────┤
│  UIKit apps    │  Injeção no WebKit (apps com câmera)   │
│                │  ex: FaceTime, Instagram, Zoom         │
└────────────────┴────────────────────────────────────────┘
```

---

## Classes Objective-C Identificadas

### Camada de Transporte
| Classe | Função |
|---|---|
| `AVSStreamTransport` | WebSocket cliente (WiFi/USB) |
| `AVSLocalTransport` | Modo USB (localhost:8765 via iTunes) |

### Fornecedores de Dados
| Classe | Função |
|---|---|
| `AVSRemoteDataProvider` | Recebe frames do PC via rede |
| `AVSLocalDataProvider` | Reproduz vídeo/foto da galeria |
| `AVSDataProvider` (protocolo) | Interface comum |

### Pipeline de Vídeo
| Classe | Função |
|---|---|
| `AVSFrameCoordinator` | Coordenador central, controle de estado |
| `AVSMediaDecoder` | Decodificador H.264/H.265 (VideoToolbox) |
| `AVSRenderPipeline` | GPU Metal + CoreImage (cor, escala) |
| `AVSFormatAnalyzer` | Detecta formato/resolução/FPS |
| `AVSDisplayLayer` | Preview no painel |

### Áudio / Sensor
| Classe | Função |
|---|---|
| `AVSAudioBridge` | Ring buffer PCM para substituição de mic |
| `AVSMotionSynthesizer` | Sintetiza CoreMotion (acelerômetro/gyro) |

### UI
| Classe | Função |
|---|---|
| `AVSPreferencePanel` | Painel flutuante principal |
| `AVSAccessibilityOverlay` | Detecta app em foco, oculta UI |
| `AVSPresentationController` | Alertas: planos, wallet, PIX, crypto |
| `AVSDisplayLayer` | Layer de preview de vídeo |

### Auth / Config
| Classe | Função |
|---|---|
| `AVSServiceConfiguration` | Licença, API, anti-tamper, armazenamento |
| `VCDefaultStrategy` | Estratégia padrão de conexão |
| `VCPipelineStrategy` | Estratégia pipeline de vídeo |
| `VCPortraitController` | Forçar orientação retrato |

---

## Protocolo de Rede (WebSocket)

```
URL: wss://<ip>:8765  (WiFi)
     wss://127.0.0.1:8765  (USB via usbmuxd)

Mensagens JSON:
  { "type": "frame",  ... }           → frame de vídeo
  { "type": "audio",  "rate": N }     → PCM de áudio
  { "type": "ping" }
  { "type": "pong" }
  { "type": "disconnect" }
  { "type": "media_..." }             → metadados de mídia

Handshake HTTP upgrade:
  sec-websocket-key → SHA1(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")
  Resposta: HTTP/1.1 101 Switching Protocols
```

---

## API REST (servidor de licença)

```
Base URL: _avs_cfg_srvAddr (configurado em prefs.plist)

Endpoints:
  POST {base}/auth/report-bug
       body: { email, device_model, ios_version, tweak_version, location, message }

  GET  {base}/member
       → retorna status da conta, planos, saldo

  GET  {base}/payments/crypto-currencies?amount=<float>
       → retorna redes de crypto disponíveis

  POST {base}/payments/...  (PIX, crypto)

Headers:
  Content-Type: application/json
  User-Agent: CFNetwork/1410.0.3 Darwin/22.6.0

TLS: SPKI pinning via _avs_cfg_spkiHash:
```

---

## Armazenamento Persistente

Todos os arquivos em `/var/tmp/com.apple.avfcache/`:

| Arquivo | Conteúdo |
|---|---|
| `prefs.plist` | Flags de feature, pan, velocidade, etc. |
| `prefs.lock` | Lock file para acesso exclusivo |
| `state.plist` | Estado de injeção (`loaded`, `_avs_inj`) |
| `cache.plist` | Cache da resposta do servidor |
| `meta.dat` | Metadados criptografados |
| `session.dat` | Token de sessão |
| `crash.txt` | Log de crashes (SIGSEGV/SIGBUS/SIGFPE) |
| `probe_<proc>.txt` | Saída de probe por processo |

Chaves do prefs.plist:
```
_avs_cfg_authorized   → BOOL: licença válida
_avs_cfg_attestation  → String: attestation token
_avs_cfg_checksum     → String: SHA256 do binário (64 hex chars)
_avs_cfg_lastcheck    → String: timestamp último check
_avs_cfg_credential   → String: credencial criptografada
```

Feature flags (`fcXxx`):
```
fcPanX, fcPanY  → pan horizontal/vertical
fcBgR/G/B       → cor de fundo RGB
fcBr, fcCo, fcSa, fcGa → brightness, contrast, saturation, gamma
fcFlipH         → flip horizontal
fcSpeed         → velocidade de playback
fcPaused, fcStopped → estado de reprodução
fcLE, fcBE      → lens effects, background effect
fcER/EG/EB      → eye drop color (R/G/B)
rplE            → replacement enabled
aRplE           → audio replacement enabled
```

---

## Formatos de Pixel Buffer

| Código | Formato |
|---|---|
| `420v` | kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange |
| `420f` | kCVPixelFormatType_420YpCbCr8BiPlanarFullRange |
| `BGRA` | kCVPixelFormatType_32BGRA |
| `p420`/`pf20` | HEVC 8-bit planar |
| `x420`/`xf20` | HEVC 10-bit |
| `&8v0`/`&8f0` | ProRes 8-bit |
| `&xv0`/`&xf0` | ProRes 10-bit |

---

## Anti-Tamper / Segurança

| Código | Detecção |
|---|---|
| `BL01` | Tweak conflitante detectado |
| `BL02` | Frida ou debugger detectado |
| `IC02` | Verificação de integridade interna |
| `ep_0x03` | Probe de ambiente |
| `fn_0x07` | Hook em funções do sistema detectado |
| `0xE7I1` | Verificação de assinatura interna |
| `Trim` | Identificador de trim check |

Técnicas de detecção:
1. `ptrace(PT_DENY_ATTACH)` anti-debugger
2. Scan de portas Frida (27042)
3. Verificação de `/proc` e bibliotecas injetadas
4. SHA256 do binário vs checksum armazenado em prefs.plist
5. SPKI certificate pinning (TLS)
6. Detecção de hooks em funções de sistema (fn_0x07)
7. Verificação de versão: binário instalado vs esperado

---

## Kernels Metal

```metal
// Kernels identificados:
kernel void processFrameKernel(...)      // processamento principal de frame
kernel void processFrameNV12Kernel(...)  // processamento NV12
kernel void renderNV12Kernel(...)        // render NV12 -> textura
kernel void renderBGRAtoNV12Kernel(...)  // conversão BGRA -> NV12
```

---

## Fluxo de Injeção de Frame

```
PC Server ──WebSocket──► AVSStreamTransport
                              │
                              ▼
                        AVSMediaDecoder
                        (VTDecompressionSession H264/H265)
                              │
                              ▼
                        AVSRenderPipeline
                        (Metal GPU: escala, cor, rotação)
                              │
                              ▼
                    AVSFrameCoordinator._avs_cfg_onDec()
                              │
                    ┌─────────┴──────────┐
                    │                    │
              BWNodeOutput         AVCaptureConnection
              (mediaserverd)       (apps com câmera)
                    │                    │
                    ▼                    ▼
              App recebe          App recebe
              frame virtual       frame virtual
```

---

## Modelos de iPhone Suportados

iPhone 8/8+, X, XS/XS Max, XR,
iPhone 11/11 Pro/11 Pro Max,
iPhone 12 mini/12/12 Pro/12 Pro Max,
iPhone 13 mini/13/13 Pro/13 Pro Max,
iPhone 14/14+/14 Pro/14 Pro Max,
iPhone 15/15+/15 Pro/15 Pro Max

---

## Pagamentos Suportados

- **PIX** (BRL, mínimo R$ 10,00) — QR Code + copia-e-cola, polling de status
- **Crypto USD** (mínimo $ 10,00):
  - USDT BEP20 (BSC)
  - USDT Polygon
  - USDT Base
  - USDT Solana
  - USDC Solana
  - Litecoin

---

## Arquivos Gerados

| Arquivo | Descrição |
|---|---|
| `AVSStreamTransport.h` | Transport WebSocket |
| `AVSFrameCoordinator.h` | Coordenador central |
| `AVSDataProvider.h` | Provedores de dados |
| `AVSMediaDecoder.h` | Decodificador H264/H265 |
| `AVSRenderPipeline.h` | Pipeline Metal GPU |
| `AVSAudioBridge.h` | Bridge de áudio |
| `AVSMotionSynthesizer.h` | Sintetizador de movimento |
| `AVSFormatAnalyzer.h` | Analisador de formato |
| `AVSServiceConfiguration.h` | Config/licença/API |
| `AVSPreferencePanel.h` | UI painel flutuante |
| `AVSDisplayLayer.h` | Layer de preview |
| `AVSAccessibilityOverlay.h` | Overlay de acessibilidade |
| `AVSPresentationController.h` | Alertas/pagamentos |
| `AVSLocalTransport.h` | Transporte USB |
| `KYCHooks.h` | Ponto de injeção |
| `Tweak.xm` | Entry point Logos/Substrate |
| `control` | Metadados do pacote Debian |
| `AVServicesd.plist.decoded` | Filtro de injeção decodificado |
