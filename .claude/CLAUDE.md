# GoChat - Claude Code Instructions

## Project

GoChat is a browser-native encrypted messenger built on SimpleXMQ.
- SMP Profile: SimpleX Messaging Protocol over WebSocket for everyday encrypted chat
- GRP Profile: GoRelay Protocol over WebSocket for high-security environments (future, Season 9+)
- Both profiles share the same ChatTransport interface abstraction
- Repository: github.com/saschadaemgen/GoChat
- Fork of: simplex-chat/simplexmq (branch ep/smp-web-spike)
- License: AGPL-3.0
- Author: Sascha Daemgen, IT and More Systems, Recklinghausen

## Ground Rule

**Nothing invented. What is missing gets asked.**
Claude does not fabricate information, assume technical details, or fill gaps with
speculation. If a detail is unknown, it is marked as unknown and the question is raised.
This applies to code, documentation, protocol details, and all other output.

## Rules (NON-NEGOTIABLE)

### Git
- Conventional Commits ONLY: `type(scope): description`
- Valid types: feat, fix, docs, test, refactor, ci, chore
- Valid scopes: transport, commands, connection, crypto, ui, security, config, docs
- Commits as granular as possible, as few as necessary
- NEVER change version numbers without explicit permission
- GPG signing key: E13737C02E97E54B (sascha.daemgen@t-online.de)

### Code Style
- NEVER use em dashes (the long ones) - use regular hyphens or rewrite the sentence
- All code, comments, commits, and documentation in English
- TypeScript strict mode always
- Use @noble libraries ONLY for cryptography - NEVER Web Crypto API directly, NEVER libsodium.js
- All crypto operations MUST run in a dedicated Web Worker (isolated from main thread XSS)
- Handle all errors explicitly - NEVER use `_` to discard errors
- NEVER log key material, queue IDs, message content, or any user metadata

### Architecture
- ChatTransport interface is mandatory - ALL transport code goes through this abstraction
- SMP and GRP code NEVER import each other
- xftp-web/ is upstream code - NEVER modify files in xftp-web/
- smp-web/ is our workspace - all new code goes here
- Fixed 16,384-byte blocks for ALL SMP wire communication, '#' (0x23) padding
- SharedWorker for WebSocket connection pool (Season 6)
- Web Worker for crypto isolation (Season 5)
- IndexedDB for persistent storage (messages, keys, connection state)

## Technology Stack (LOCKED)

| Component | Choice | Notes |
|---|---|---|
| Language | TypeScript (strict mode) | ES2022 target |
| Transport | Native WebSocket (browser) | WSS only, binary frames |
| Crypto (SMP) | @noble/curves, @noble/ciphers, @noble/hashes | 6 audits, used by Proton Mail |
| Crypto (GRP, future) | @noble/ciphers (ChaCha20-Poly1305), @noble/hashes (BLAKE2s) | Same family |
| Key exchange | X25519 via @noble/curves | Ed25519 for signatures |
| Symmetric encryption | XSalsa20-Poly1305 via @noble/ciphers (NaCl secretbox) | MVP E2E |
| Hash functions | SHA-256, SHA-512 via @noble/hashes | Already in xftp-web |
| Key storage | IndexedDB with AES-256-GCM encryption at rest | extractable: false |
| Shared infrastructure | @simplex-chat/xftp-web (local file dependency) | DO NOT MODIFY |
| Build | TypeScript compiler (tsc) | No bundler in smp-web yet |
| Test | To be determined in Season 2 | Vitest or Jest |

## Package Structure

```
GoChat/
  .claude/
    CLAUDE.md                       # This file
    settings.local.json             # Claude Code permissions
  .github/
    assets/
      gochat_banner.png             # Project banner
  docs/
    PROTOCOL.md                     # Main technical protocol (33 tasks, dual-profile)
    RESEARCH.md                     # Browser crypto, security, design research
    seasons/
      SEASON-PLAN.md                # 12-season roadmap
      SEASON-01-planning.md         # Season 1 closing protocol
  smp-web/                          # OUR WORKSPACE - all new code goes here
    src/
      index.ts                      # Re-exports encoding primitives from xftp-web
      protocol.ts                   # SMP transmission encode/decode, LGET/LNK (from spike)
      transport.ts                  # NEW in S2: WebSocket transport (ChatTransport)
      client.ts                     # NEW in S2: SMP client with handshake
    package.json                    # @simplex-chat/smp-web v0.1.0
    tsconfig.json                   # ES2022, strict mode
  xftp-web/                         # UPSTREAM - DO NOT MODIFY
    src/
      client.ts                     # HTTP/2 transport, handshake, retry (REFERENCE)
      agent.ts                      # File transfer agent
      download.ts                   # Chunk decryption
      protocol/
        encoding.ts                 # Binary encoding (Decoder, encodeBytes, etc.)
        transmission.ts             # Block framing, session auth
        handshake.ts                # Client/server handshake, version negotiation
        commands.ts                 # XFTP commands
        address.ts                  # Server address parsing
      crypto/
        keys.ts                     # X25519 key generation + DH
        secretbox.ts                # NaCl XSalsa20-Poly1305
        identity.ts                 # Ed25519 server identity verification
        digest.ts                   # SHA-256 / SHA-512
        padding.ts                  # Block padding
  protocol/                         # SMP protocol specification (upstream reference)
  LICENSE                           # AGPL-3.0
  README.md                         # Project README with dual-profile architecture
```

## Current State

Season 1 is COMPLETE. Season 2 is CURRENT.

Season 1 produced documentation only - no executable code. The project has:
- Complete technical protocol with 33 tasks across 12 seasons
- Deep research on browser crypto, security, design, competitive landscape
- Dual-profile architecture design (SMP + GRP)
- ChatTransport interface defined
- Repository forked, cleaned (Haskell removed), restructured
- Community contact established (Evgeny Poberezkin confirmed smp-web is active WIP)

The smp-web spike from upstream contains:
- SMP transmission encode/decode (encodeTransmission, decodeTransmission)
- LGET command encoding and LNK response decoding
- SMP response dispatch (LNK / OK / ERR)
- Re-exported encoding primitives from xftp-web

What does NOT exist yet (our work):
- WebSocket transport client (Season 2)
- SMP commands beyond LGET/LNK (Season 3)
- Connection flow via contact address (Season 4)
- E2E encryption (Season 5)
- Chat UI (Season 6)
- Everything else

## Development Roadmap

- Season 1: Planning and Documentation - COMPLETE
- Season 2: WebSocket Transport Client (ChatTransport, Handshake, Reconnect) - CURRENT
- Season 3: SMP Commands (NEW, SUB, SEND, MSG, ACK, KEY, DEL)
- Season 4: Connection Flow (contact address, queue pair, state machine)
- Season 5: E2E Encryption (NaCl MVP, Web Worker isolation, key storage)
- Season 6: Chat UI (Intercom-level, animations, encryption badge, SharedWorker)
- Season 7: SimpleGo Website Integration (SPA, mobile, player coexistence)
- Season 8: Production Hardening (CSP, SRI, deployment, security review)
- Season 9+: GRP Profile (Noise transport, ML-KEM-768, two-hop routing)

## Season 2 Implementation Plan (CURRENT)

### Goal

Browser can establish a WebSocket connection to an SMP server, complete the
SMP handshake, and send/receive raw 16KB SMP blocks. The transport class
implements the ChatTransport interface.

### Task 1: ChatTransport Interface Definition (WS-1 prerequisite)
- Create `smp-web/src/types.ts` with ChatTransport interface
- ServerAddress type (host, port, fingerprint)
- This is the contract all transport implementations must follow
- Keep it minimal - only what is needed for Season 2

```typescript
interface ChatTransport {
  connect(server: ServerAddress): Promise<void>
  send(block: Uint8Array): Promise<void>
  onMessage(handler: (block: Uint8Array) => void): void
  close(): void
}

interface ServerAddress {
  host: string
  port: number
  fingerprint?: string  // SHA-256 of CA cert for SMP servers
}
```

### Task 2: WebSocket Transport Class (WS-1)
- Create `smp-web/src/transport.ts`
- SMPWebSocketTransport implements ChatTransport
- Connect to `wss://server:443` using native browser WebSocket
- Binary message mode (not text) - set binaryType = 'arraybuffer'
- SMP block framing: every message is exactly 16,384 bytes
- Connection lifecycle: open, close, error events
- Heartbeat: send PING, expect PONG (use SMP protocol PING, not WebSocket ping)
- Support concurrent send + async receive (SUB delivers MSG at any time)
- Disable permessage-deflate (encrypted data is incompressible)
- Branch: feature/websocket-transport

### Task 3: SMP Handshake Client (WS-2)
- Create `smp-web/src/client.ts`
- Adapt the XFTP handshake flow for SMP protocol
- CRITICAL: SMP handshake is DIFFERENT from XFTP handshake
  - Study xftp-web/src/client.ts connectXFTP() carefully
  - Study xftp-web/src/protocol/handshake.ts for the handshake structure
- SMP ServerHello contains:
  - smpVersionRange (4 bytes: min=6 Word16 BE, max=7 Word16 BE)
  - sessionIdentifier (shortString, tls-unique channel binding)
  - serverCert (originalLength + online certificate DER)
  - signedServerKey (originalLength + X25519 SPKI DER + Ed25519 signature)
- SMP ClientHello contains:
  - smpVersion (2 bytes Word16 BE, chosen version)
  - keyHash (shortString, 32 bytes raw SHA256 of CA cert.Raw)
- Version negotiation: agree on highest mutual version (6 or 7)
- Session ID extraction for transmission encoding
- Branch: feature/smp-handshake

### Task 4: Connection Pooling and Reconnect (WS-3)
- Extend transport.ts with reconnection logic
- Auto-reconnect with exponential backoff:
  - 500ms base delay
  - 2x multiplier per attempt
  - 30-second maximum cap
  - 50-100% multiplicative jitter (prevents thundering herd)
  - After 12 attempts (~2 minutes): emit 'connection_lost' event
- Use navigator.onLine for network awareness
- Use document.visibilitychange to pause/resume reconnection
- Re-handshake after reconnect (SMP sessions are not resumable)
- Branch: feature/reconnect

### Task 5: TLS Certificate Strategy (SEC-5)
- Document and implement the certificate approach:
  - SMP servers use self-signed CA chains with fingerprint in server address
  - Browsers reject WSS to untrusted certs
  - Solution: server must have Let's Encrypt cert for TLS layer
  - SMP fingerprint verification happens at application layer after handshake
  - The keyHash in ClientHello verifies server identity independent of TLS CA
- Token-based WebSocket auth (not cookies) to prevent CSWSH
- Branch: can be part of feature/smp-handshake

## Critical Protocol Details

### Block Framing
```
Block = contentLength (2 bytes, uint16 BE) + content + padding ('#' to 16384)
ALWAYS exactly 16,384 bytes. No exceptions.
Padding byte is '#' (0x23), NOT zero bytes.
```

### Transmission Structure (inside block content)
```
[transmissionCount: 1 byte]
[transmissionLength: 2 bytes, uint16 BE]
[transmission:]
  [authorization: shortString (1 byte len + data, or 0x00 for unsigned)]
  [corrId: 0x18 + 24 random bytes for commands, 0x00 for server notifications]
  [entityId: shortString (1 byte len + queue ID, or 0x00 for empty)]
  [command: text-based tag + body]
```

### Encoding Rules
| Type | Format |
|---|---|
| shortString | 1 byte length prefix + data bytes |
| originalLength | 2 byte Word16 BE length prefix + data bytes |
| Ed25519 signature | shortString with length 0x40 (64 bytes) |
| corrId | 0x18 (24) + 24 random bytes, echoed in response |
| entityId | shortString, empty (0x00) for NEW/IDS/PING/PONG |

### SMP Version Negotiation
```
Current SMP versions: 6 and 7 (older versions discontinued)
Server sends: min=6, max=7
Client responds with its version range
Agree on highest mutual version
```

### SMP Handshake Sequence
```
1. Browser opens WSS connection to server:443
2. Server sends ServerHello (16KB block):
   [smpVersionRange][sessionId][serverCert][signedServerKey][padding]
3. Browser verifies:
   - signedServerKey signature against serverCert
   - serverCert is valid
   - SHA256(CA cert) matches fingerprint from server address
4. Browser sends ClientHello (16KB block):
   [smpVersion][keyHash][padding]
5. Handshake complete, session established
```

### SMP Commands (reference for future seasons)
| Command | Direction | entityId | Auth |
|---|---|---|---|
| NEW | Client -> Server | empty | Ed25519 signature (self-certifying) |
| IDS | Server -> Client | empty | None |
| SUB | Client -> Server | recipientId | Ed25519 signature |
| SEND | Client -> Server | senderId | Ed25519 signature |
| MSG | Server -> Client | recipientId | None (server push) |
| ACK | Client -> Server | recipientId | Ed25519 signature |
| KEY | Client -> Server | recipientId | Ed25519 signature |
| DEL | Client -> Server | recipientId | Ed25519 signature |
| PING | Client -> Server | empty | None |
| PONG | Server -> Client | empty | None |

### ChatTransport Interface (day-one requirement)
```typescript
interface ChatTransport {
  connect(server: ServerAddress): Promise<void>
  send(block: Uint8Array): Promise<void>
  onMessage(handler: (block: Uint8Array) => void): void
  close(): void
}
// Season 2: SMPWebSocketTransport implements ChatTransport
// Season 9: GRPWebSocketTransport implements ChatTransport
```

## Files to Study Before Writing Code

Read these files carefully before implementing Season 2 tasks:

1. `xftp-web/src/client.ts` - The reference transport implementation. Study
   connectXFTP(), the handshake flow, retry logic, and connection lifecycle.
   Our WebSocket transport mirrors this pattern but over WebSocket instead of HTTP/2.

2. `xftp-web/src/protocol/handshake.ts` - Handshake encode/decode. The SMP
   handshake follows a similar structure but with different fields. Study
   serverHandshakeDecode and clientHandshakeEncode.

3. `xftp-web/src/protocol/encoding.ts` - The binary encoding primitives.
   Decoder class, encodeBytes, decodeBytes, Word16/32/64. We import these
   through smp-web/src/index.ts.

4. `xftp-web/src/protocol/transmission.ts` - Block framing. How blocks are
   built, padded to 16384 bytes, and parsed. Session-based auth and corrId.

5. `smp-web/src/protocol.ts` - Existing SMP protocol code from the spike.
   encodeTransmission, decodeTransmission, LGET/LNK. Our new commands
   extend this file.

6. `smp-web/src/index.ts` - Re-exported primitives. Check what is already
   available before importing from xftp-web directly.

7. `docs/PROTOCOL.md` - Full technical protocol with all task definitions,
   risk assessment, and architecture details.

## What NOT to Do

- NEVER modify any file in xftp-web/ - this is upstream code
- NEVER modify protocol/ directory - this is upstream SMP spec reference
- NEVER use Web Crypto API directly - always @noble libraries
- NEVER use libsodium.js - always @noble libraries
- NEVER change version numbers in package.json without permission
- NEVER use em dashes in any output
- NEVER log sensitive data (keys, queue IDs, messages)
- NEVER create transport code that bypasses ChatTransport interface
- NEVER import GRP-related code from SMP-related code or vice versa
- NEVER assume protocol details - check the source or ask

## Dual-Profile Architecture (Context Only - Do Not Implement GRP Yet)

GoChat has two communication profiles. Season 2-8 implement the SMP profile.
Season 9+ implements the GRP profile. The ChatTransport interface exists
specifically to make this separation clean.

**SMP Profile (Season 2-8):**
- SimpleX Messaging Protocol over WebSocket
- Compatible with all SimpleX clients and servers
- @noble/curves for X25519/Ed25519, @noble/ciphers for NaCl secretbox
- Standard TLS transport

**GRP Profile (Season 9+, DO NOT IMPLEMENT):**
- GoRelay Protocol over WebSocket, GoRelay servers only
- Noise_IK_25519_ChaChaPoly_BLAKE2s transport
- X25519 + ML-KEM-768 hybrid post-quantum key exchange
- Mandatory two-hop relay routing
- Poisson cover traffic

The GRP details are documented here so Claude Code understands WHY the
ChatTransport interface exists and WHY it must not be bypassed.

## Part of the SimpleGo Ecosystem

| Component | Language | What it does |
|---|---|---|
| SimpleGo | C | ESP32-S3 hardware client, 4-layer encryption, sntrup761 |
| GoRelay | Go | Dual-protocol relay server (SMP + GRP), BadgerDB, zero-knowledge |
| GoChat | TypeScript | Browser-native encrypted messenger (this project) |

## Documentation

Read these files for context and decisions:
1. docs/PROTOCOL.md - Full technical protocol, all 33 tasks, risk assessment
2. docs/RESEARCH.md - Browser crypto maturity, security analysis, design specs
3. docs/seasons/SEASON-PLAN.md - 12-season roadmap with dependencies
4. docs/seasons/SEASON-01-planning.md - Season 1 decisions and lessons learned
5. README.md - Project overview, dual-profile architecture, ecosystem
