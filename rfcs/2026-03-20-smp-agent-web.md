# SMP Agent for Browser — Web Widget Infrastructure

## 1. Problem & Goal

The SimpleX web widget needs to create duplex connections, send and receive encrypted messages, and handle the full SMP agent lifecycle — all running in the browser. This requires a TypeScript implementation of the SMP protocol stack: encoding, transport, client, and agent layers, mirroring the Haskell implementation in simplexmq.

This document covers the protocol infrastructure that lives in the simplexmq repository (`smp-web/`). The widget UI and chat-layer semantics (contact addresses, business addresses, group links) live in simplex-chat.

## 2. Architecture

Four layers, mirroring the Haskell codebase:

```
┌─────────────────────────────────────────────────────────────┐
│  Agent Layer                                                 │
│  Duplex connections, X3DH key agreement, double ratchet,     │
│  message delivery, queue rotation, connection lifecycle       │
├─────────────────────────────────────────────────────────────┤
│  Client Layer                                                │
│  Connection pool (per server), command/response correlation,  │
│  reconnection, backoff                                       │
├─────────────────────────────────────────────────────────────┤
│  Transport Layer                                             │
│  WebSocket, SMP handshake, block framing (16384 bytes),      │
│  block encryption (X25519 DH + SbChainKeys)                  │
├─────────────────────────────────────────────────────────────┤
│  Protocol Layer                                              │
│  SMP commands (NEW, KEY, SUB, SEND, ACK, etc.),              │
│  binary encoding, transmission format                        │
├─────────────────────────────────────────────────────────────┤
│  Shared (from xftp-web)                                      │
│  encoding.ts, secretbox.ts, padding.ts, keys.ts, digest.ts   │
└─────────────────────────────────────────────────────────────┘
                    │
                    ▼ WebSocket (TLS via browser)
            ┌───────────────┐
            │  SMP Server    │
            │  (SNI → Warp   │
            │   → WS upgrade)│
            └───────────────┘
```

### Core Principle: Mirror Haskell Structure

TypeScript code mirrors the Haskell module hierarchy as closely as possible. Each Haskell module has a corresponding TypeScript file, placed in the same relative path. Functions keep the same names. This enables:
- Easy cross-reference between codebases
- Sync as protocol evolves
- Code review by people who know the Haskell side
- Byte-for-byte testing of corresponding functions

### File Structure

```
smp-web/
├── src/
│   ├── protocol.ts              ← SMP commands, transmission format
│   ├── protocol/
│   │   └── types.ts             ← protocol types
│   ├── version.ts               ← version range negotiation
│   ├── transport.ts             ← handshake, block framing, THandle
│   ├── transport/
│   │   └── websockets.ts        ← WebSocket connection
│   ├── client.ts                ← connection pool, correlation, reconnect
│   ├── crypto/
│   │   ├── ratchet.ts           ← double ratchet
│   │   └── shortLink.ts         ← HKDF, link data decrypt
│   └── agent/
│       ├── protocol.ts          ← connection types, link data parsing
│       └── client.ts            ← connection lifecycle, message delivery
├── package.json
└── tsconfig.json
```

Encoding and crypto primitives are imported directly from xftp-web (npm dependency). New files are only created where SMP-specific logic is needed.

### Haskell Module → TypeScript File Mapping

| Haskell Module | TypeScript File | Source |
|---|---|---|
| `Simplex.Messaging.Encoding` | xftp-web `protocol/encoding.ts` | import directly |
| `Simplex.Messaging.Crypto` | xftp-web `crypto/*` | import directly |
| `Simplex.Messaging.Protocol` | `protocol.ts` | new |
| `Simplex.Messaging.Protocol.Types` | `protocol/types.ts` | new |
| `Simplex.Messaging.Version` | `version.ts` | new |
| `Simplex.Messaging.Transport` | `transport.ts` | new |
| `Simplex.Messaging.Transport.WebSockets` | `transport/websockets.ts` | new |
| `Simplex.Messaging.Client` | `client.ts` | new |
| `Simplex.Messaging.Crypto.Ratchet` | `crypto/ratchet.ts` | new |
| `Simplex.Messaging.Crypto.ShortLink` | `crypto/shortLink.ts` | new |
| `Simplex.Messaging.Agent.Protocol` | `agent/protocol.ts` | new |
| `Simplex.Messaging.Agent.Client` | `agent/client.ts` | new |

Function names in TypeScript match Haskell names (camelCase preserved). When a Haskell function is `smpClientHandshake`, TypeScript has `smpClientHandshake`. When Haskell has `contactShortLinkKdf`, TypeScript has `contactShortLinkKdf`.

## 3. Relationship to xftp-web

xftp-web (`simplexmq-2/xftp-web/`) is a production TypeScript XFTP client. smp-web reuses its foundations:

**Reused directly (npm dependency)**:
- `protocol/encoding.ts` — Decoder class, Word16/Word32/Int64, ByteString, Large, Bool, Maybe, List encoding
- `crypto/secretbox.ts` — XSalsa20-Poly1305 (cbEncrypt/cbDecrypt, streaming)
- `crypto/padding.ts` — Block padding (2-byte length prefix + `#` fill)
- `crypto/keys.ts` — Ed25519, X25519 key generation, signing, DH, DER encoding
- `crypto/digest.ts` — SHA-256, SHA-512
- `crypto/identity.ts` — X.509 certificate chain parsing, signature verification

**New in smp-web**:
- SMP protocol commands and transmission format
- SMP handshake (different from XFTP handshake)
- WebSocket transport (XFTP uses HTTP/2 fetch)
- SMP client with queue-based correlation
- Agent layer (connections, ratchet, message processing)
- Short link operations (HKDF-SHA512, link data parsing)

**Same build pattern**:
- TypeScript strict, ES2022 modules
- `tsc` → `dist/`
- Haskell tests via `callNode` (same function from XFTPWebTests)
- Each TypeScript function verified byte-for-byte against Haskell

## 4. Server Changes

### Done
- `attachStaticAndWS` — unified HTTP + WebSocket handler via `wai-websockets`
- SNI-based routing: browser (SNI) → Warp → WebSocket upgrade → SMP over WS; native (no SNI) → SMP over TLS
- `acceptWSConnection` — constructs `WS 'TServer` from TLS connection + Warp PendingConnection, preserves peer cert chain
- `AttachHTTP` takes `TLS 'TServer` (not raw Context), enabling proper cert chain forwarding
- Test: `testWebSocketAndTLS` verifies native TLS and WebSocket clients on same port

### Remaining
- CORS headers for cross-origin widget embedding (pattern available in XFTP server)
- Server CLI configuration for enabling/disabling WebSocket support per port

## 5. Build Approach

Bottom-up, function-by-function. Each TypeScript function tested against its Haskell counterpart before building the next.

**Test infrastructure**: `SMPWebTests.hs` reuses `callNode`, `jsOut`, `jsUint8` from `XFTPWebTests.hs` (generalized, not copied).

**Pattern**: for each function:
1. Implement in TypeScript
2. Write Haskell test that calls it via `callNode`
3. Compare output byte-for-byte with Haskell reference
4. Also test cross-language: Haskell encodes → TypeScript decodes, and vice versa

## 6. Implementation Phases

### Phase 1: Protocol Encoding + Handshake

Foundation layer. SMP-specific binary encoding and handshake.

**Functions**:
- SMP transmission format: `[auth ByteString][corrId ByteString][entityId ByteString][command]`
- `encodeTransmission` / `parseTransmission`
- `parseSMPServerHandshake` — versionRange, sessionId, authPubKey (CertChainPubKey)
- `encodeSMPClientHandshake` — version, keyHash, authPubKey, proxyServer, clientService
- Server certificate chain verification (reuse xftp-web identity.ts)
- Version negotiation

**Key encoding details**:
- `authPubKey` uses `encodeAuthEncryptCmds`: Nothing → empty (0 bytes), Just → raw smpEncode (NOT Maybe 0/1 prefix)
- `proxyServer`: Bool 'T'/'F' (v14+)
- `clientService`: Maybe '0'/'1' (v16+)

### Phase 2: SMP Commands

All commands needed for messaging.

**Sender**: SKEY, SEND
**Receiver**: NEW, KEY, SUB, ACK, OFF, DEL
**Link**: LGET
**Common**: PING

**For each command**: encode function + decode function for its response, tested against Haskell.

### Phase 3: Transport

WebSocket connection with SMP block framing.

**Functions**:
- WebSocket connect (`wss://` URL)
- Block send/receive (16384-byte binary frames)
- SMP handshake over WebSocket
- Block encryption: X25519 DH → HKDF-SHA512 → SbChainKeys → per-block XSalsa20-Poly1305

**Block encryption flow**:
1. Client generates ephemeral X25519 keypair, sends public key in handshake
2. Server sends its signed DH key in handshake
3. Both sides compute DH shared secret
4. `sbcInit(sessionId, dhSecret)` → two 32-byte chain keys (HKDF-SHA512)
5. Each block: `sbcHkdf(chainKey)` → ephemeral key + nonce, advance chain
6. Encrypt/decrypt with XSalsa20-Poly1305, blockSize-16 padding target

### Phase 4: Client

Connection management layer.

**Functions**:
- Connection pool: one WebSocket per SMP server
- Command/response correlation via corrId
- Send queue + receive queue (ABQueue pattern from simplexmq-js)
- Automatic reconnection with exponential backoff
- Timeout handling

### Phase 5: Agent — Connection Establishment

Duplex SMP connections with X3DH key agreement.

**Functions**:
- Create receive queue (NEW)
- Join connection via invitation URI
- X3DH key agreement
- Send confirmation (SKEY + SEND)
- Complete handshake (HELLO exchange)
- Connection state machine

### Phase 6: Agent — Double Ratchet

Message encryption/decryption.

**Functions**:
- Signal double ratchet implementation
- Header encryption
- Ratchet state management
- Key derivation (HKDF)
- Message sequence + hash chain verification

### Phase 7: Agent — Message Delivery

Send and receive messages through established connections.

**Functions**:
- Send path: encrypt → encode agent envelope → SEND → handle OK/delivery receipt
- Receive path: SUB → receive MSG → decrypt → verify → ACK
- Delivery receipts
- Message acknowledgment

### Phase 8: Short Links

Entry point for the widget — parse short link, fetch profile.

**Functions**:
- Parse short link URI (contact, group, business address types)
- HKDF key derivation (SHA-512): `contactShortLinkKdf`
- LGET command → LNK response
- Decrypt link data (XSalsa20-Poly1305)
- Parse FixedLinkData, ConnLinkData, UserLinkData
- Extract profile JSON

## 7. Persistence

Agent state (keys, ratchet, connections, messages) must persist across page reloads.

**Open question**: storage backend.

Options:
- **IndexedDB directly** — universal browser support, async API, no additional dependencies. Downside: key-value semantics, no SQL queries, manual indexing.
- **SQLite in browser** — sql.js (WASM-compiled SQLite) or wa-sqlite (with OPFS backend for persistence). Upside: matches Haskell agent's SQLite storage, schema can mirror `Simplex.Messaging.Agent.Store.SQLite`. Downside: additional dependency, WASM bundle size.
- **OPFS + SQLite** — Origin Private File System for durable storage, SQLite for structured access. Best durability, but limited browser support (no Safari private browsing).

**Decision criteria**: how closely we want to mirror the Haskell agent's storage schema, bundle size budget, browser compatibility requirements.

## 8. Testing Strategy

### Unit Tests (per function)

Haskell tests in `SMPWebTests.hs` using `callNode` pattern:
- TypeScript function called via Node.js subprocess
- Output compared byte-for-byte with Haskell reference
- Cross-language tests: encode in one language, decode in the other

### Integration Tests

Against live SMP server (spawned by test setup, same pattern as xftp-web globalSetup.ts):
- WebSocket connect + handshake
- Command round-trips (NEW, KEY, SUB, SEND, ACK)
- Message delivery through server
- Reconnection after disconnect

### Browser Tests

Vitest + Playwright (same as xftp-web):
- Full connection lifecycle in browser environment
- WebSocket transport in real browser
- Persistence round-trips

## 9. Security Model

Same principles as xftp-web:
- **TLS via browser** — browser handles certificate validation for WSS connections
- **SNI routing** — browser connections use SNI, routed to Warp + WebSocket handler
- **Server identity** — verified via certificate chain in SMP handshake (keyHash from short link or known servers)
- **Block encryption** — X25519 DH + SbChainKeys provides forward secrecy per block, on top of TLS
- **End-to-end encryption** — double ratchet between agent peers, server sees only encrypted blobs
- **No server-side secrets** — all keys derived and stored client-side
- **CORS** — required for cross-origin widget embedding, safe because SMP requires auth on every command
- **CSP** — strict content security policy for widget page

**Threat model**: same as xftp-web. Primary risk is page substitution (malicious JS). Mitigated by HTTPS, CSP, SRI, and optionally IPFS hosting with published fingerprints.
