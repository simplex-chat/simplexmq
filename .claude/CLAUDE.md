# GoChat - Claude Code Instructions

## Project

GoChat is the world's first browser-native encrypted support messenger using the SimpleX Messaging Protocol.
- Browser-side SMP client in TypeScript
- WebSocket transport to SMP relay servers
- E2E encrypted chat between website visitors and support team
- Repository: github.com/saschadaemgen/GoChat
- Parent project: github.com/saschadaemgen/SimpleGo
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
- NEVER use em dashes (—) - use regular hyphens (-) or rewrite the sentence
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
- Use binary WebSocket frames (not text) for encrypted SMP payloads
- Token-based WebSocket auth (not cookies) to prevent CSWSH
- Document the browser trust boundary honestly in security docs

### Architecture
- smp-web/src/ is the SMP browser client library
- xftp-web/ is upstream shared infrastructure (encoding, crypto, transport) - DO NOT MODIFY
- protocol/ is upstream SMP specification - DO NOT MODIFY
- SharedWorker for WebSocket connection pool across tabs
- Web Worker for crypto operations isolated from main thread
- IndexedDB for persistent message and key storage
- All SMP communication over WebSocket (wss://) with binary frames
- Fixed 16,384-byte SMP blocks - same as native protocol

## Build and Test

```bash
cd smp-web
npm install
npm run build      # TypeScript compilation
npm test           # Unit tests
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

Critical path: S1 -> S2 -> S3 -> S4 -> S7 -> S8
Parallel track: S5 and S6 can run alongside S4

## Season 2 Tasks (NEXT)

### WS-1: WebSocket transport class
- Create smp-web/src/transport.ts
- Connect to wss://server:443 with SNI header for WS routing
- SMP block-based framing over WebSocket binary messages
- Connection lifecycle: open, close, error, reconnect
- Heartbeat via PING/PONG
- Support concurrent send + async receive
- Branch: feat/ws-transport

### WS-2: SMP client with handshake
- Create smp-web/src/client.ts
- Adapt XFTP handshake flow for SMP protocol
- Version negotiation with compatibleVRange
- Session ID extraction for transmission encoding
- Branch: feat/smp-client

### WS-3: Connection pooling and reconnect
- Reuse XFTPClientAgent pattern from xftp-web
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
auth = authenticator (empty for unsigned)
corrId = correlation ID (matches response to request)
entityId = queue ID
Encoding: 1-byte length prefix for short strings, 2-byte for large
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

### Subscription Rules
- Only ONE connection per queue at any time
- New SUB sends END to displaced connection
- Messages delivered one at a time, wait for ACK

## Documentation

Read these files for implementation details:
1. docs/PROTOCOL.md - Full technical analysis, task IDs, code map
2. docs/RESEARCH.md - Browser crypto, security, design research
3. docs/seasons/SEASON-PLAN.md - 8-season roadmap with success criteria
4. xftp-web/src/client.ts - Reference transport implementation (study connectXFTP)
5. xftp-web/src/protocol/encoding.ts - Binary encoding primitives
6. xftp-web/src/crypto/ - Crypto primitives (keys, secretbox, identity)
7. protocol/simplex-messaging.md - Upstream SMP protocol specification
