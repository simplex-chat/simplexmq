# GoChat - Claude Code Instructions

## Project

GoChat is a browser-native encrypted messenger for the SimpleX ecosystem with two communication profiles.
- **SMP Profile:** SimpleX Messaging Protocol over WebSocket for everyday use (shops, communities, support, families)
- **GRP Profile:** GoRelay Protocol with Noise transport, post-quantum ML-KEM-768, two-hop routing for high-security (future)
- Both profiles share the same chat UI - difference is transport and encryption layer
- GoChat extends the SimpleX network, does not replace it. No mobile apps planned - SimpleX covers that.
- Repository: github.com/saschadaemgen/GoChat
- Parent project: github.com/saschadaemgen/SimpleGo
- Ecosystem: SimpleGo (hardware) + GoRelay (server) + GoChat (browser)
- License: AGPL-3.0 (derivative of SimpleXMQ)
- Author: Sascha Daemgen, IT and More Systems, Recklinghausen

## Rules (NON-NEGOTIABLE)

### Git
- Conventional Commits ONLY: `type(scope): description`
- Valid types: feat, fix, docs, test, refactor, ci, chore
- Valid scopes: transport, commands, connection, crypto, ui, config, docs, seasons
- NEVER commit directly to main - always feature branches
- NEVER change version numbers without explicit permission
- Commits as granular as possible, as few as necessary
- Each commit gets its own descriptive title and professional message
- Multiple files in one commit ONLY when logically inseparable
- Each season protocol lists ALL commits with hashes and descriptions

### Code Style
- NEVER use em dashes - use regular hyphens (-) or rewrite the sentence
- All code, comments, commits, and documentation in English
- TypeScript strict mode always enabled
- ES2022 target, ES modules
- No `any` types unless absolutely unavoidable (document why)
- Handle all errors explicitly - NEVER silently swallow
- Zero all key material after use where possible in JS
- Use `crypto.subtle` or @noble libraries - NEVER roll custom crypto

### Security
- All crypto operations in a dedicated Web Worker (isolated from main thread XSS)
- Strict CSP: script-src 'self' - no eval, no inline scripts
- Subresource Integrity (SRI) on all external scripts
- Minimal dependencies - every dependency is an attack surface
- Store CryptoKey objects with extractable: false in IndexedDB
- Use binary WebSocket frames (not text) for encrypted payloads
- Token-based WebSocket auth (not cookies) to prevent CSWSH
- Document the browser trust boundary honestly in security docs

### Architecture
- smp-web/src/ is the SMP browser client library
- xftp-web/ is upstream shared infrastructure - DO NOT MODIFY
- protocol/ is upstream SMP specification - DO NOT MODIFY
- SharedWorker for WebSocket connection pool across tabs
- Web Worker for crypto operations isolated from main thread
- IndexedDB for persistent message and key storage
- Fixed 16,384-byte SMP blocks - same as native protocol
- Design transport layer with interface abstraction to support both SMP and GRP profiles later

## Build and Test

```bash
cd smp-web
npm install
npm run build
npm test
```

## Technology Stack

| Component | Choice | Notes |
|-----------|--------|-------|
| Language | TypeScript 5.4+ | Strict mode, ES2022 target |
| Crypto (curves) | @noble/curves | Ed25519, X25519 - 6 security audits |
| Crypto (ciphers) | @noble/ciphers | XSalsa20-Poly1305, AES-256-GCM |
| Crypto (hashes) | @noble/hashes | SHA-256, SHA-512, HKDF |
| Transport | Native WebSocket API | Binary frames, SharedWorker pool |
| Key Storage | IndexedDB + Web Crypto | extractable: false, PBKDF2 wrapping |
| Message Storage | IndexedDB | Encrypted at rest |
| Build | TypeScript compiler (tsc) | No bundler needed for library |
| Testing | vitest | Matching xftp-web test setup |

## Package Structure

```
smp-web/src/
  index.ts              # Re-exports encoding primitives from xftp-web
  protocol.ts           # SMP transmission encode/decode, LGET/LNK (exists)
  transport.ts          # WebSocket transport client (Season 2)
  client.ts             # SMP client with handshake (Season 2)
  commands.ts           # SMP command encoders/decoders (Season 3)
  connection.ts         # Connection manager (Season 4)
  agent.ts              # Minimal SMP agent, state machine (Season 4)
  crypto/
    e2e.ts              # E2E encryption module (Season 5)
    keys-store.ts       # Browser key storage (Season 5)
```

## Dual-Profile Architecture (Important Context)

GoChat will eventually support two profiles:

**SMP Profile (Seasons 2-8):** Standard SimpleX protocol. This is the primary development focus. Everything built here must use a clean transport interface so GRP can be added later without refactoring.

**GRP Profile (Season 9+):** GoRelay Protocol with Noise + ML-KEM-768. This comes AFTER the SMP profile is production-ready. When implementing transport and connection layers, design them with an abstract interface that can accept a second protocol implementation later.

```typescript
// Example: design transport as interface from day one
interface ChatTransport {
  connect(server: ServerAddress): Promise<void>
  send(block: Uint8Array): Promise<void>
  onMessage(handler: (block: Uint8Array) => void): void
  close(): void
}

// Season 2: SMPWebSocketTransport implements ChatTransport
// Season 9+: GRPWebSocketTransport implements ChatTransport
```

## Current State

Season 1 (Planning and Documentation) is nearing completion.

### What exists (from upstream spike):
- smp-web/src/index.ts - Re-exports encoding primitives
- smp-web/src/protocol.ts - SMP transmission encode/decode, LGET/LNK commands
- smp-web/package.json - Package config, depends on xftp-web
- smp-web/tsconfig.json - TypeScript config

### What exists (from xftp-web, DO NOT MODIFY):
- Binary encoding/decoding (Decoder, encodeBytes, decodeLarge, etc.)
- HTTP/2 transport with retry and reconnect logic
- Server handshake and version negotiation
- X25519 key generation and DH agreement
- NaCl secretbox (XSalsa20-Poly1305) encryption
- Ed25519 server identity verification
- SHA-256/SHA-512 digests
- Content padding for fixed-size blocks
- Server address parsing

## Development Roadmap

- Season 1: Planning, documentation, research - CURRENT
- Season 2: WebSocket transport client (WS-1 to WS-4)
- Season 3: SMP commands (CMD-1 to CMD-5)
- Season 4: Connection flow (CONN-1 to CONN-4)
- Season 5: E2E encryption (E2E-1 to E2E-3)
- Season 6: Chat UI (UI-1 to UI-8)
- Season 7: SimpleGo website integration
- Season 8: Production hardening + security review
- Season 9+: GRP profile (Noise, ML-KEM-768, two-hop)

## Season 2 Tasks (NEXT)

### WS-1: WebSocket transport class
- Create smp-web/src/transport.ts
- Define ChatTransport interface (abstract, profile-agnostic)
- Implement SMPWebSocketTransport implementing ChatTransport
- Connect to wss://server:443, binary frames, 16KB block framing
- Connection lifecycle: open, close, error, reconnect
- Branch: feat/ws-transport

### WS-2: SMP client with handshake
- Create smp-web/src/client.ts
- Adapt XFTP handshake flow for SMP protocol
- Version negotiation with compatibleVRange
- Session ID extraction for transmission encoding
- Branch: feat/smp-client

### WS-3: Connection pooling and reconnect
- Auto-reconnect with exponential backoff (500ms base, 2x, 30s cap, jitter)
- Re-subscribe to queues after reconnect
- Branch: feat/connection-pool

### WS-4: SharedWorker for tab persistence
- WebSocket pool lives in SharedWorker
- All tabs share connections
- Survives tab close/open and SPA navigation
- Branch: feat/shared-worker

## Critical Protocol Details

### SMP Block Framing
```
Block = payloadLength (2 bytes, uint16 BE) + payload + padding ('#' to 16384)
ALWAYS exactly 16,384 bytes. No exceptions.
Padding character is '#' (0x23), NEVER zero bytes.
```

### SMP Transmission Format
```
[auth: ByteString] [corrId: ByteString] [entityId: ByteString] [command: raw bytes]
```

### SMP Commands (to implement in Season 3)
```
NEW <rcvPubKey> <dhPubKey>           -> IDS <rcvId> <sndId> <srvDhPubKey>
SUB                                   -> OK (+ async MSG delivery)
KEY <sndKey>                          -> OK
SEND <msgFlags> <msgBody>             -> OK
MSG <msgId> <ts> <msgFlags> <msgBody> (async push from server)
ACK <msgId>                           -> OK
DEL                                   -> OK
LGET (entityId=linkId)                -> LNK <sndId> <encFixedData> <encUserData>
PING                                  -> PONG
```

## Documentation

Read these files for implementation details:
1. docs/PROTOCOL.md - Full technical analysis, task IDs, code map
2. docs/RESEARCH.md - Browser crypto, security, design research
3. docs/seasons/SEASON-PLAN.md - 8-season roadmap with success criteria
4. xftp-web/src/client.ts - Reference transport implementation (study connectXFTP)
5. xftp-web/src/protocol/encoding.ts - Binary encoding primitives
6. xftp-web/src/crypto/ - Crypto primitives (keys, secretbox, identity)
7. protocol/simplex-messaging.md - Upstream SMP protocol specification
