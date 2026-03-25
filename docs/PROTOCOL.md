<p align="center">
  <img src="../.github/assets/gochat_banner.png" alt="GoChat" width="1500" height="230">
</p>

<h1 align="center">GoChat - Technical Protocol</h1>

<p align="center">
  <strong>Technical protocol document for the GoChat encrypted web messenger.</strong><br>
  Dual-profile architecture, SMP-web spike analysis, implementation roadmap, and task registry.
</p>

---

**Project:** GoChat - Browser-Native Encrypted Messenger  
**Parent project:** [SimpleGo](https://github.com/saschadaemgen/SimpleGo)  
**Ecosystem:** SimpleGo (hardware) / GoRelay (relay server) / GoChat (browser client)  
**Date:** 2026-03-25  
**Branch analyzed:** `ep/smp-web-spike` on `simplex-chat/simplexmq`  
**Status:** Season 1 nearing completion, documentation updates in progress

---

## Ground rules

These rules apply to this document, all season protocols, and all GoChat development. They are non-negotiable.

1. **Nothing invented. What is missing gets asked. The Prinzessin shows everything needed.** Claude does not fabricate information, assume technical details, or fill gaps with speculation. If a detail is unknown, it is marked as unknown and the question is raised.

2. **Conventional Commits only.** Every commit follows the format `type(scope): description`. Valid types: feat, fix, docs, test, refactor, ci, chore. Commits are as granular as possible, as few as necessary.

3. **No em dashes.** Only regular hyphens (-) or rewritten sentences. Em dashes are an AI giveaway.

4. **No version number changes** without explicit permission from the project owner.

5. **English for all code, commits, comments, and documentation.** Conversations happen in German, artifacts are in English.

6. **TypeScript strict mode, @noble-only crypto, Web Worker isolation** for all browser-side cryptographic operations.

---

## 1. Executive summary

GoChat is a browser-native encrypted messenger built on [SimpleXMQ](https://github.com/simplex-chat/simplexmq). It brings the SimpleX Messaging Protocol directly into the browser, allowing website visitors to communicate through end-to-end encrypted channels without installing any application or creating any account.

GoChat supports two communication profiles selectable per connection:

- **SMP Profile** - everyday encrypted communication via the SimpleX Messaging Protocol over WebSocket, compatible with all SimpleX clients and servers
- **GRP Profile** - high-security communication via the GoRelay Protocol over WebSocket, exclusively through [GoRelay](https://github.com/saschadaemgen/GoRelay) infrastructure, with Noise transport, mandatory post-quantum cryptography, two-hop relay routing, and cover traffic

No browser-native SMP client exists anywhere - not from SimpleX Chat, not from the community, not from any third party. No open-source support chat tool offers E2E encryption on the customer-facing widget side. GoChat would be first on both counts.

GoChat is not a replacement for SimpleX - it is a complementary extension. No mobile app is planned or needed. SimpleX covers mobile and desktop. GoChat fills the browser gap and extends with GRP for high-security environments.

Based on the `ep/smp-web-spike` branch by [@epoberezkin](https://github.com/epoberezkin) (SimpleX founder), which introduces browser-native SMP protocol support. Evgeny confirmed in the SimpleX community chat that smp-web is actively being worked on ("its WIP :)").

---

## 2. How SimpleX messaging works

### 2.1 Core concept: simplex queues

SimpleX uses unidirectional message queues on relay servers. A single chat connection requires two queues (one in each direction). The relay server never sees both queues as belonging to the same conversation.

```
User A                    SMP Relay                    User B
  |                          |                           |
  |--- Queue 1 (A sends) --->|--- Queue 1 (B receives) ->|
  |                          |                           |
  |<-- Queue 2 (B sends) ---|<-- Queue 2 (A receives) --|
  |                          |                           |
```

What the server sees: isolated encrypted blobs in anonymous queues. No user IDs, no metadata linking Queue 1 to Queue 2, no way to correlate sender and receiver.

### 2.2 Connection establishment flow

1. **Contact address creation:** The support team creates a permanent SimpleX contact address in their app. This generates a link containing the server address and a public key.

2. **User connects:** When a website visitor clicks "Support Chat", their browser parses the contact address link, creates a new queue pair on the SMP server, performs X3DH key agreement, and sends a connection request through the contact address queue.

3. **Support accepts:** The SimpleX app on the support team's device automatically accepts the connection (configurable) and establishes the bidirectional channel.

4. **Messaging:** Both parties can now exchange E2E encrypted messages through their dedicated queue pair.

### 2.3 Multi-user architecture

Each new visitor who connects via the contact address gets their own independent queue pair. The support team sees each visitor as a separate contact in their SimpleX app. There is no theoretical limit on concurrent connections - the SMP server handles queue isolation natively.

```
Visitor A ---[Q1/Q2]---> SMP Server ---[Q1/Q2]---> Support Team (Contact: "Anon User 1")
Visitor B ---[Q3/Q4]---> SMP Server ---[Q3/Q4]---> Support Team (Contact: "Anon User 2")
Visitor C ---[Q5/Q6]---> SMP Server ---[Q5/Q6]---> Support Team (Contact: "Anon User 3")
```

The support team can handle multiple conversations simultaneously in the SimpleX desktop or mobile app.

---

## 3. Dual-profile architecture

GoChat supports two communication profiles. Both profiles use the same chat interface - the difference is in the transport layer, encryption strength, and relay infrastructure. The transport layer is abstracted behind a `ChatTransport` interface from day one, ensuring both profiles can be developed independently and swapped at runtime.

### 3.1 SMP Profile - everyday encrypted communication

The standard profile for daily use. Speaks the SimpleX Messaging Protocol over WebSocket, fully compatible with all SimpleX clients and any SMP relay server - including SimpleX's own public infrastructure, self-hosted servers, or GoRelay.

Use cases: product support, online shops (with SimpleGo terminal), communities, families, small businesses, freelancers, education, personal websites.

On the receiving end: SimpleX Chat app (phone/desktop) or a SimpleGo hardware terminal. No special software required.

```
Website visitor (browser)          Any SMP Server           Receiving end
        |                               |                        |
        |--- WSS + SMP --------------->|                        |
        |    E2E encrypted             |--- SMP relay --------->|
        |                               |                        |  SimpleX App (phone/desktop)
        |<-- WSS + SMP ----------------|<-- SMP relay ----------|  or SimpleGo terminal
        |    E2E encrypted             |                        |
```

### 3.2 GRP Profile - high-security environments

An additional security layer for environments where standard encryption is not sufficient. Uses the GoRelay Protocol (GRP) over WebSocket, exclusively through GoRelay infrastructure.

Use cases: journalism and source protection, whistleblower channels, government and public authorities, healthcare, critical infrastructure, legal and financial services, defense, NGOs and human rights.

On the receiving end: SimpleGo hardware (ESP32-S3) with no smartphone OS, no baseband processor, and hardware-backed key storage.

```
Website visitor (browser)          GoRelay Server           Receiving end
        |                               |                        |
        |--- WSS + GRP --------------->|                        |
        |    Noise + Post-quantum      |--- GRP relay --------->|
        |    Two-hop routing           |    Cover traffic       |  SimpleGo hardware
        |    Cover traffic             |                        |  (ESP32-S3)
        |<-- WSS + GRP ----------------|<-- GRP relay ----------|
        |                               |                        |
```

### 3.3 What makes GRP different from SMP

| Property | SMP (TLS 1.3) | GRP (Noise IK) |
|:---------|:--------------|:---------------|
| Handshake size | 1-4 KB | 96-144 bytes |
| Cipher negotiation | Yes (dozens of options) | No (fixed suite, cannot downgrade) |
| Certificate authority | Required (X.509 chain) | Not needed (key IS identity) |
| Identity hiding | Server visible via SNI | Both parties encrypted |
| Deniability | No (signatures in handshake) | Yes (DH only, no signatures) |
| Post-quantum | Not mandatory | Mandatory (X25519 + ML-KEM-768) |
| Routing | Direct (single hop) | Mandatory two-hop relay |
| Cover traffic | No | Yes (Poisson-distributed) |

The elimination of cipher negotiation is the most significant security improvement. TLS has spent two decades fighting downgrade attacks (POODLE, FREAK, Logjam, ROBOT) caused by its negotiation mechanism. Noise cannot have downgrade attacks because there is nothing to downgrade. One fixed cipher suite per protocol version: `Noise_IK_25519_ChaChaPoly_BLAKE2s`.

### 3.4 ChatTransport interface

Both profiles implement the same abstract transport interface. This is a day-one architectural requirement - all code that sends or receives messages must go through this interface, never directly through a WebSocket.

```typescript
interface ChatTransport {
  connect(server: ServerAddress): Promise<void>
  send(block: Uint8Array): Promise<void>
  onMessage(handler: (block: Uint8Array) => void): void
  close(): void
}

// Season 2-8: SMPWebSocketTransport implements ChatTransport
// Season 9+:  GRPWebSocketTransport implements ChatTransport
```

The ChatTransport abstraction ensures:
- SMP and GRP code never leak into each other
- Profile switching at runtime requires only swapping the transport instance
- Testing can use a mock transport without network dependencies
- Future transport types (HTTP/2 long-polling fallback, WASM-based) slot in without changing application code

### 3.5 GoRelay as bridge

GoRelay's dual-protocol architecture allows cross-protocol message delivery. SMP on port 5223, GRP on port 7443, shared QueueStore. A message arriving via SMP can be delivered to a GRP subscriber and vice versa. This means a visitor using the SMP profile can reach a SimpleGo hardware device behind GRP - GoRelay handles the translation transparently.

### 3.6 Profile comparison

| Feature | SMP Profile | GRP Profile |
|:--------|:-----------|:------------|
| Protocol | SimpleX Messaging Protocol | GoRelay Protocol |
| Transport | WebSocket + TLS | WebSocket + Noise |
| Key exchange | X25519 + Double Ratchet | X25519 + ML-KEM-768 (post-quantum) |
| Relay servers | Any SMP server | GoRelay only |
| Routing | Direct | Mandatory two-hop |
| Cover traffic | No | Yes (Poisson-distributed) |
| Cipher negotiation | TLS cipher suites | None (fixed, no downgrade possible) |
| Identity hiding | Server visible via SNI | Both parties encrypted |
| Server seizure resistance | Standard encryption | Shamir split across servers (future) |
| Traffic disguise | None | Steganographic transport (future) |
| Queue auth | Ed25519 signature | Zero-knowledge proof (future) |
| Compatible with | All SimpleX clients | SimpleGo hardware |
| Use case | Everyday communication | High-security environments |

### 3.7 Future: Triple Shield architecture (GRP Phase 6)

GoRelay's roadmap includes a Triple Shield layer adding three defense mechanisms on top of the existing encryption stack:

- **6a: Zero-Knowledge Queue Authentication** - Schnorr DLOG via Fiat-Shamir. Clients prove queue ownership without revealing their public key. The server learns exactly one bit: "this client has the right key" or not.
- **6b: Shamir's Secret Sharing (2-of-3)** - Each encrypted message is split into shares across multiple servers. Any single share contains mathematically zero information. Information-theoretic security that holds even against unlimited computing power.
- **6c: Steganographic Transport** - GRP traffic wrapped in protocols mimicking legitimate web traffic. Pluggable Transports framework (HTTPS, WebSocket, meek, obfs4).

When all active, defeating a GoChat-to-SimpleGo communication requires simultaneously breaking eight independent defense layers. Failure at any single point leaves the attacker with nothing.

---

## 4. What already exists (analysis of the spike branch)

### 4.1 Server-side (Haskell - production ready)

| Component | Status | Location | Notes |
|-----------|--------|----------|-------|
| SMP server with all commands | DONE | `src/Simplex/Messaging/` | NEW, SUB, SEND, MSG, ACK, KEY, DEL, LGET, LNK |
| WebSocket on port 443 | DONE | PR #1738, merged 2026-03-20 | Browser WS and native TLS on same port via SNI routing |
| Contact address / short links | DONE | Protocol level | Permanent contact address for support team |
| XFTP file transfer | DONE | Separate protocol | Could be used for file attachments later |
| TLS + identity verification | DONE | Server handshake | Ed25519 certificate chain verification |

### 4.2 Browser-side shared infrastructure (xftp-web - production tested)

These modules are already battle-tested in the live file transfer tool at `simplex.chat/file/`.

| Component | Status | File | Notes |
|-----------|--------|------|-------|
| Binary encoding/decoding | DONE | `xftp-web/src/protocol/encoding.ts` | Full SMP wire format: Decoder class, encodeBytes, decodeLarge, Word16/32/64, Bool, Maybe, List, NonEmpty |
| HTTP/2 transport | DONE | `xftp-web/src/client.ts` | Browser fetch() transport with timeout, retry, reconnect logic |
| Server handshake | DONE | `xftp-web/src/protocol/handshake.ts` | Client hello, server handshake decode, version negotiation |
| Server identity verification | DONE | `xftp-web/src/crypto/identity.ts` | Ed25519 certificate chain + web challenge verification |
| X25519 key exchange | DONE | `xftp-web/src/crypto/keys.ts` | generateX25519KeyPair, DH key agreement, public key encoding |
| NaCl secretbox encryption | DONE | `xftp-web/src/crypto/secretbox.ts` | XSalsa20-Poly1305 authenticated encryption |
| SHA-256 / SHA-512 digests | DONE | `xftp-web/src/crypto/digest.ts` | Using @noble/hashes |
| Content padding | DONE | `xftp-web/src/crypto/padding.ts` | Block padding/unpadding for fixed-size transmissions |
| Server address parsing | DONE | `xftp-web/src/protocol/address.ts` | Parse server URLs with key hash verification |
| Connection agent (pool) | DONE | `xftp-web/src/client.ts` | Connection pooling, sequential command queue, auto-reconnect |
| Transmission framing | DONE | `xftp-web/src/protocol/transmission.ts` | Block encoding/decoding, session-based auth, correlation IDs |

### 4.3 Browser-side SMP client (smp-web - spike / in progress)

| Component | Status | File | Notes |
|-----------|--------|------|-------|
| Package setup | DONE | `smp-web/package.json` | `@simplex-chat/smp-web` v0.1.0, depends on xftp-web |
| TypeScript config | DONE | `smp-web/tsconfig.json` | ES2022 target, strict mode |
| Re-exported encoding primitives | DONE | `smp-web/src/index.ts` | Decoder, encodeBytes, decodeBytes, etc. |
| SMP transmission encode/decode | DONE | `smp-web/src/protocol.ts` | `encodeTransmission()`, `decodeTransmission()` with auth field |
| LGET command encoding | DONE | `smp-web/src/protocol.ts` | Link GET - retrieve connection data from short link |
| LNK response decoding | DONE | `smp-web/src/protocol.ts` | Parse senderId, encFixedData, encUserData from link response |
| SMP response dispatch | DONE | `smp-web/src/protocol.ts` | Switch on LNK / OK / ERR tags |
| ASCII helper | DONE | `smp-web/src/protocol.ts` | String to Uint8Array conversion for command tags |

### 4.4 Key commits on the branch

| Hash | Date | Description |
|------|------|-------------|
| `4b89a7f` | 2026-03-22 | `encoding/decoding of LGET/LNK` - Core SMP protocol in TypeScript |
| `3eeffff` | 2026-03-22 | `smp web: initial setup` - Package scaffolding |
| `01fe841` | 2026-03-20 | `smp: allow websocket connections on the same port (#1738)` - WebSocket transport on SMP server |
| `1a12ee0` | 2026-03-20 | `xftp-web: version bump to 0.3.0 (#1742)` - Updated shared dependency |
| `dc2921e` | 2026-03-18 | `xftp-server: embed file download widget (#1733)` - Web embedding pattern |
| `328d3b9` | 2026-03-11 | `xftp-web: use XFTP server domain in share link (#1732)` - Security improvement |

---

## 5. What needs to be built

### 5.1 Layer 1: WebSocket SMP transport client (CRITICAL PATH)

**Priority:** Highest - everything else depends on this.

The xftp-web client uses HTTP/2 POST requests for transport. SMP messaging requires a persistent bidirectional connection (for receiving messages in real-time). PR #1738 added WebSocket support to the SMP server. We need a browser-side WebSocket client that mirrors the existing HTTP/2 transport interface.

All transport code must implement the `ChatTransport` interface defined in section 3.4.

**Tasks:**

- [ ] **WS-1:** Create `smp-web/src/transport.ts` - WebSocket transport class
  - Implement `ChatTransport` interface
  - Connect to `wss://server:443` with SNI header for WS routing
  - Implement the SMP block-based framing over WebSocket binary messages
  - Handle connection lifecycle: open, close, error, reconnect
  - Implement heartbeat/keepalive (SMP PING/PONG)
  - Support concurrent send + async receive (SUB delivers MSG at any time)

- [ ] **WS-2:** Create `smp-web/src/client.ts` - SMP client with handshake
  - Adapt the XFTP handshake flow for SMP protocol
  - SMP uses TLS-level handshake (different from XFTP HTTP-level handshake)
  - Version negotiation with `compatibleVRange`
  - Session ID extraction for transmission encoding

- [ ] **WS-3:** Connection pooling and reconnect
  - Reuse the `XFTPClientAgent` pattern from xftp-web
  - Auto-reconnect with exponential backoff (500ms base, 2x multiplier, 30s cap, 50-100% jitter)
  - Re-subscribe to queues after reconnect
  - Use `navigator.onLine` and `visibilitychange` for network-aware behavior
  - After 12 attempts (~2 minutes): show "Connection lost" with manual reconnect

- [ ] **WS-4:** SharedWorker for tab persistence
  - Create `smp-web/src/shared-worker.ts` - SharedWorker managing WebSocket connection pool
  - Maintain chat state across tab switches and SPA navigation
  - Architecture: Browser Tab(s) <-> SharedWorker (WS Pool + Reconnection + Queue) <-> SMP Servers
  - IndexedDB integration for persistent message queue and encrypted key store
  - Disable `permessage-deflate` compression (encrypted payloads are incompressible)
  - Use binary WebSocket frames (not text) to avoid 33% Base64 overhead
  - Multiplex multiple SMP queues over a single WebSocket per server

### 5.2 Layer 2: SMP command implementation

**Priority:** High - needed for any message exchange.

The SMP protocol has well-defined commands. We need TypeScript encoders/decoders matching the Haskell implementation in `Simplex.Messaging.Protocol`.

**Reference:** `src/Simplex/Messaging/Protocol.hs` in simplexmq (lines ~1629-2203 for encoding/decoding).

**Tasks:**

- [ ] **CMD-1:** Queue creation commands
  - `NEW` - Create a new message queue (recipient side)
  - Response: `IDS` containing recipientId, senderId, server DH public key

- [ ] **CMD-2:** Sender commands
  - `SEND` - Send a message to a queue
  - `SKEY` - Provide sender's public key for authenticated sending
  - Response: `OK` or `ERR`

- [ ] **CMD-3:** Recipient commands
  - `SUB` - Subscribe to a queue (start receiving messages)
  - `ACK` - Acknowledge message receipt
  - `KEY` - Rotate recipient key
  - `DEL` - Delete a queue
  - Event: `MSG` - Incoming message delivery (async, pushed by server)

- [ ] **CMD-4:** Connection link commands (partially done)
  - `LGET` - Get link data (DONE in spike)
  - `LNK` - Link response parsing (DONE in spike)
  - [ ] `LSND` - Send data via link (for connection request)

- [ ] **CMD-5:** Utility commands
  - `PING` / `PONG` - Keepalive
  - Response error types: `AUTH`, `QUOTA`, `NO_MSG`, `CMD`, `INTERNAL`

### 5.3 Layer 3: Connection management (SMP Agent logic)

**Priority:** High - orchestrates the queue pair setup.

This implements the "duplex connection over simplex queues" pattern. In Haskell this is the SMP Agent (`Simplex.Messaging.Agent`). We need a minimal browser-side version.

**Tasks:**

- [ ] **CONN-1:** Contact address parsing
  - Parse SimpleX contact address URI: `simplex:/contact#/?v=...&smp=...`
  - Extract server address, public key, and connection parameters
  - Decode base64url-encoded key material

- [ ] **CONN-2:** Connection initiation (browser side)
  - Generate ephemeral X25519 key pair for the connection
  - Create recipient queue on SMP server (NEW command)
  - Build connection request containing our queue info + public key
  - Send connection request through the contact address mechanism

- [ ] **CONN-3:** Connection acceptance handling
  - Receive confirmation from support team (MSG on our recipient queue)
  - Extract support team's queue info + public key from confirmation
  - Subscribe to our recipient queue for incoming messages (SUB)

- [ ] **CONN-4:** Connection state machine
  - States: `NEW` -> `PENDING` -> `CONNECTED` -> `CLOSED`
  - Persist connection state in browser (IndexedDB/localStorage)
  - Handle reconnection: re-SUB to existing queues on page reload

### 5.4 Layer 4: End-to-end encryption

**Priority:** High - messages must be encrypted.

SimpleX uses Double Ratchet (Signal protocol) for E2E encryption with X3DH key agreement. For a support chat MVP, we start with NaCl box encryption per-message and upgrade to Double Ratchet later.

All crypto operations run in a dedicated Web Worker, isolated from the main thread (see SEC-3).

**Tasks:**

- [ ] **E2E-1:** Key agreement (X3DH - Extended Triple Diffie-Hellman)
  - Generate identity key pair (X25519) via @noble/curves
  - Generate signed pre-key
  - Generate one-time pre-key
  - Compute shared secret from X3DH
  - **Alternative MVP:** Use single X25519 DH for shared secret (simpler, no forward secrecy)

- [ ] **E2E-2:** Message encryption
  - **MVP:** NaCl secretbox with shared DH secret (via @noble/ciphers, XSalsa20-Poly1305)
  - **Full:** Double Ratchet with symmetric key ratchet + DH ratchet
  - Message padding to fixed block size (reuse xftp-web/crypto/padding.ts)

- [ ] **E2E-3:** Key storage
  - Store CryptoKey objects in IndexedDB with `extractable: false`
  - Encrypt all sensitive data with AES-256-GCM before writing to IndexedDB
  - Derive wrapping key from user password/PIN via PBKDF2 (>=2^19 iterations)
  - Clear key material from memory as aggressively as JS GC allows
  - Handle key rotation for long-lived sessions

### 5.5 Layer 5: Chat UI (GoChat frontend)

**Priority:** Medium - can be built in parallel with protocol work.

GoChat must achieve Intercom-level polish, not Chatwoot-level "it works". The encryption indicator is the brand differentiator - always visible, always prominent.

**Tasks:**

- [ ] **UI-1:** Nose-bar integration
  - Add chat icon to nose-bar (similar to player idle state)
  - Show unread message count badge
  - Toggle chat panel open/close (reuse player panel pattern)

- [ ] **UI-2:** Chat panel
  - Panel width: 380px (350-400px range), height: 520-550px (100vh on mobile)
  - Message bubbles: outgoing (right, accent color) / incoming (left, card bg)
  - Bubble border-radius: 18px (4px on tail corner), max-width: 70-75% of container
  - Text input with send button
  - Auto-scroll to latest message
  - Typing indicator (optional)
  - Connection status indicator (connecting / connected / offline)

- [ ] **UI-3:** Chat state management
  - Store message history in IndexedDB
  - Restore chat on page reload (reconnect to existing queues)
  - "New conversation" button to start fresh
  - Clear chat history option

- [ ] **UI-4:** Mobile responsive
  - Full-screen chat panel on mobile (< 768px)
  - Touch-friendly message input (minimum 44x44px touch targets)
  - Adapt to existing SimpleGo mobile breakpoints

- [ ] **UI-5:** SPA router integration
  - Chat state persists across page navigation (SPA router)
  - WebSocket connection survives route changes (via SharedWorker)
  - Panel state (open/closed) persists

- [ ] **UI-6:** Intercom-level animation system
  - Message appear: fade + translateY(10px->0) at 200ms ease-out
  - Panel open: scale(0.9->1) + opacity(0->1) + translateY(20->0) with transform-origin: bottom right
  - Typing indicator: three 8px dots with staggered animation-delay, scale(0.6)->scale(1) at 1.4s
  - Launcher morph: chat bubble to X/close icon with 300ms rotation
  - Launcher button: 56px circular FAB, bottom-right, 20px margin
  - Transitions: 200-300ms ease-out, only transform + opacity for 60fps
  - All animations must respect `prefers-reduced-motion`

- [ ] **UI-7:** Encryption badge design
  - Persistent lock icon with "End-to-end encrypted" badge, always visible in the chat panel header
  - This is GoChat's unique visual differentiator - the brand, not just a feature
  - Profile indicator showing whether current connection uses SMP or GRP
  - No competitor can match this claim

- [ ] **UI-8:** Accessibility (WCAG 2.1 AA compliance)
  - Chat container: `role="log"` with `aria-live="polite"`
  - All interactive elements: visible focus indicators + keyboard operability
  - Touch targets: minimum 44x44px
  - Color never the sole status indicator - always combine with icons or text
  - Dark mode: background #121212 (never pure black - causes halation), text #E0E0E0 (never pure white)
  - Message font: 14px, system font stack, 1.5 line-height
  - Message spacing: 16px between senders, 2-4px within same sender

### 5.6 Layer 6: Browser security hardening

**Priority:** High - browser E2E encryption is only as strong as its weakest security surface.

XSS is the existential threat to browser-based encryption. A single XSS vulnerability defeats ALL encryption by intercepting plaintext before encryption or after decryption. The 2022 Matrix "Nebuchadnezzar" vulnerabilities demonstrated this in practice. The September 2025 npm supply chain attack (chalk, debug, ansi-styles - 1 billion+ weekly downloads) is a stark reminder that dependency minimization is security-critical.

**Tasks:**

- [ ] **SEC-1:** Content Security Policy implementation
  - Strict CSP: `script-src 'self'` - no eval, no inline scripts
  - No dynamic code execution of any kind
  - CSP headers enforced server-side, not just meta tags
  - Report-URI for CSP violation monitoring

- [ ] **SEC-2:** Subresource Integrity for all external scripts
  - SRI hashes on every `<script>` and `<link>` tag loading external resources
  - Fail closed: if SRI check fails, the resource does not load
  - Automated SRI hash generation as part of the build pipeline

- [ ] **SEC-3:** Web Worker isolation for crypto operations
  - Dedicated Web Worker for all cryptographic operations
  - Main thread never touches plaintext key material
  - Worker communicates with main thread via structured clone (postMessage)
  - Isolates crypto from XSS on the main thread - even if the main thread is compromised, the Worker's memory is separate

- [ ] **SEC-4:** Security documentation - transparent trust boundary communication
  - Document the server-delivered code trust boundary honestly
  - Unlike native apps distributed through signed app stores, web applications reload from the server on every visit
  - A compromised or malicious server can serve different code to different users
  - Mitigations: reproducible builds, SRI hashes, potentially browser extension-based code verification
  - This limitation must be visible in the UI and documentation, not hidden

- [ ] **SEC-5:** TLS certificate strategy
  - SMP servers use self-signed certificate chains where the offline CA certificate hash is embedded in the server address (`smp://fingerprint@host`)
  - Browsers reject WSS connections to servers with untrusted certificates
  - Solution: GoChat's SMP servers must use standard CA-signed certificates (Let's Encrypt) for the TLS layer
  - SMP's own DH key exchange provides a second encryption envelope independent of the TLS CA chain
  - The SMP server fingerprint verification happens at the application layer, not the TLS layer
  - Token-based WebSocket authentication (not cookies) to eliminate CSWSH attacks entirely

### 5.7 Layer 7: Deployment and operations

**Tasks:**

- [ ] **OPS-1:** SMP server deployment
  - Deploy `smp-server` on VPS (Docker or systemd)
  - Configure WebSocket support (enabled by default after PR #1738)
  - Set up TLS certificate (Let's Encrypt)
  - Configure `static_path` for web files

- [ ] **OPS-2:** Contact address setup
  - Create support team profile in SimpleX app
  - Generate permanent contact address
  - Configure auto-accept for incoming connections
  - Embed contact address in GoChat website config

- [ ] **OPS-3:** Monitoring
  - SMP server health checks
  - Queue count monitoring
  - Connection error tracking in browser (optional analytics)

### 5.8 Layer 8: GRP transport (future - Season 9+)

**Priority:** After SMP profile is production-ready.

These tasks define the GRP profile implementation. They are documented here for architectural completeness but will not be worked on until the SMP profile ships.

**Tasks:**

- [ ] **GRP-1:** Noise Protocol transport
  - Implement `GRPWebSocketTransport` conforming to `ChatTransport` interface
  - Primary pattern: `Noise_IK_25519_ChaChaPoly_BLAKE2s` (server key pre-known via URI)
  - Fallback pattern: `Noise_XX` for first-contact scenarios
  - Protocol identifier: "GRP/1" as the Prologue
  - No cipher negotiation - fixed suite per protocol version
  - Rekeying every 2-5 minutes or every 1000 messages
  - Browser implementation via noble/ciphers (ChaCha20-Poly1305) and noble/curves (X25519)

- [ ] **GRP-2:** Mandatory post-quantum key exchange
  - Hybrid X25519 + ML-KEM-768 (FIPS 203) key exchange
  - ML-KEM-768 targets NIST Security Level 3 (AES-192 equivalent)
  - Not optional, cannot be disabled - if ML-KEM component fails, handshake aborts
  - Combination via HKDF: ML-KEM secret first (FIPS ordering), then X25519 secret
  - Browser implementation: evaluate @noble/post-quantum or WASM-compiled ML-KEM
  - Total handshake overhead: ~2,336 bytes (vs 64 bytes for X25519 alone) - negligible for messaging

- [ ] **GRP-3:** Two-hop relay routing
  - Every GRP message passes through two relay servers
  - Relay A sees sender IP but not destination queue
  - Relay B sees destination queue but not sender IP
  - Neither server alone can link sender to recipient
  - SMP commands: PFWD (client to Relay A), RFWD (A to B), RRES (B to A), PRES (A to client)
  - Per-message ephemeral key for s2d encryption prevents cross-queue correlation
  - Requires minimum two GoRelay servers in different jurisdictions

- [ ] **GRP-4:** Triple Shield integration (Phase 6 of GoRelay)
  - 6a: Zero-Knowledge Queue Authentication (Schnorr DLOG via Fiat-Shamir, ~100 bytes proof)
  - 6b: Shamir's Secret Sharing 2-of-3 across servers (information-theoretic security)
  - 6c: Steganographic Transport (Pluggable Transports: HTTPS, WebSocket, meek, obfs4)
  - Each component independently deployable and independently useful
  - Full Triple Shield: all eight defense layers must be broken simultaneously

---

## 6. Implementation roadmap

### Phase 1: Foundation (Season 2-3)

**Goal:** Browser can connect to SMP server and exchange raw messages.

1. Implement WebSocket transport client with ChatTransport interface (WS-1, WS-2)
2. Connection pooling and reconnect (WS-3)
3. Implement core SMP commands: NEW, SUB, SEND, ACK (CMD-1 to CMD-3)
4. Basic NaCl encryption for messages (E2E-2 MVP)
5. Test: send a message from browser, receive in SimpleX CLI

### Phase 2: Connection flow (Season 4)

**Goal:** Website visitor can connect to support team via contact address.

1. Contact address parsing (CONN-1)
2. Connection initiation flow (CONN-2, CONN-3)
3. Connection state persistence in browser (CONN-4)
4. Deploy SMP server on VPS (OPS-1, OPS-2)
5. Test: full connection flow from browser to SimpleX mobile app

### Phase 3: Chat UI (Season 5-6)

**Goal:** Intercom-level chat interface integrated into SimpleGo website.

1. SharedWorker for tab persistence (WS-4)
2. Intercom-level panel and animations (UI-1, UI-2, UI-6)
3. Encryption badge and profile indicator (UI-7)
4. Message persistence in IndexedDB (UI-3)
5. SPA router integration (UI-5)
6. Mobile responsive layout (UI-4)
7. Accessibility audit (UI-8)

### Phase 4: Hardening (Season 7-8)

**Goal:** Production-ready encrypted support chat.

1. Browser security hardening: CSP, SRI, Web Worker isolation (SEC-1 to SEC-5)
2. Upgrade to X3DH key agreement (E2E-1)
3. Implement Double Ratchet for forward secrecy (E2E-2 full)
4. Reconnection handling and offline message queue
5. Error handling and user-facing error states
6. Performance optimization and bundle size
7. Security review and documentation (SEC-4)

### Phase 5: GRP profile (Season 9+)

**Goal:** High-security communication via GoRelay.

1. Noise Protocol transport (GRP-1)
2. Post-quantum key exchange (GRP-2)
3. Two-hop relay routing (GRP-3)
4. Cover traffic integration
5. Triple Shield components (GRP-4)

---

## 7. Technical reference

### 7.1 SMP wire format

Each SMP transmission is a fixed-size block (16,384 bytes) with '#' padding (0x23):

```
[auth: ByteString] [corrId: ByteString] [entityId: ByteString] [command: raw bytes]
```

- `auth`: Authenticator (empty for unsigned transmissions)
- `corrId`: Correlation ID (matches response to request)
- `entityId`: Queue ID (identifies which queue the command targets)
- `command`: SMP command tag + parameters

Encoding uses length-prefixed byte strings (1-byte length for short, 2-byte for large).

### 7.2 Existing code map

```
GoChat/
  smp-web/                          # SMP browser client (spike + our work)
    src/
      index.ts                      # Re-exports encoding primitives from xftp-web
      protocol.ts                   # SMP transmission encode/decode, LGET/LNK

  xftp-web/                         # Shared infrastructure (upstream)
    src/
      client.ts                     # HTTP/2 transport, handshake, retry logic
      agent.ts                      # File transfer agent (download orchestration)
      download.ts                   # Chunk decryption
      protocol/
        encoding.ts                 # Binary encoding (Decoder, encode/decodeBytes, etc.)
        transmission.ts             # Block framing, session auth
        handshake.ts                # Client/server handshake, version negotiation
        commands.ts                 # XFTP commands (FNEW, FPUT, FGET, etc.)
        address.ts                  # Server address parsing
        description.ts              # File description parsing
        chunks.ts                   # Chunk management
        client.ts                   # Protocol-level client types
      crypto/
        keys.ts                     # X25519 key generation + DH
        secretbox.ts                # NaCl XSalsa20-Poly1305
        identity.ts                 # Ed25519 server identity verification
        digest.ts                   # SHA-256 / SHA-512
        padding.ts                  # Block padding
        file.ts                     # File encryption (AES-256-GCM)

  docs/
    PROTOCOL.md                     # This file
    RESEARCH.md                     # Browser crypto, security, design research
    seasons/
      SEASON-PLAN.md                # Season overview and workflow
      SEASON-01-planning.md         # Season 1 closing protocol
```

### 7.3 Dependencies

| Package | Version | Purpose |
|---------|---------|---------|
| `@noble/hashes` | ^1.5.0 | SHA-256, SHA-512 (used by xftp-web crypto) |
| `@noble/curves` | latest | Ed25519, X25519 (6 audits, used by Proton Mail, MetaMask) |
| `@noble/ciphers` | latest | XSalsa20-Poly1305, AES-256-GCM |
| `@simplex-chat/xftp-web` | file:../xftp-web | Encoding, crypto, transport primitives |
| `typescript` | ^5.4.0 | Build tooling |
| `ws` | ^8.0.0 | WebSocket (dev/test only, browser uses native WebSocket) |

### 7.4 SMP command reference (to implement)

| Command | Direction | Format | Purpose |
|---------|-----------|--------|---------|
| `NEW` | Client -> Server | `NEW <rcvPubKey> <dhPubKey>` | Create new queue |
| `IDS` | Server -> Client | `IDS <rcvId> <sndId> <srvDhPubKey>` | Queue IDs response |
| `SUB` | Client -> Server | `SUB` (entityId = queueId) | Subscribe to queue |
| `KEY` | Client -> Server | `KEY <sndKey>` | Set sender key on queue |
| `SEND` | Client -> Server | `SEND <msgFlags> <msgBody>` | Send message |
| `MSG` | Server -> Client | `MSG <msgId> <ts> <msgFlags> <msgBody>` | Receive message (async push) |
| `ACK` | Client -> Server | `ACK <msgId>` | Acknowledge receipt |
| `DEL` | Client -> Server | `DEL` | Delete queue |
| `LGET` | Client -> Server | `LGET` (entityId = linkId) | Get link data |
| `LNK` | Server -> Client | `LNK <sndId> <encFixedData> <encUserData>` | Link data response |
| `PING` | Client -> Server | `PING` | Keepalive |
| `PONG` | Server -> Client | `PONG` | Keepalive response |
| `OK` | Server -> Client | `OK` | Success |
| `ERR` | Server -> Client | `ERR <errorType>` | Error |

### 7.5 GRP cipher suite reference (for documentation, not code yet)

```
GRP/1 cipher suite (non-negotiable):
  Noise Pattern:    IK (primary), XX (fallback)
  Key Exchange:     X25519 + ML-KEM-768 hybrid (FIPS 203)
  KDF:              HKDF-SHA-256
  AEAD:             ChaCha20-Poly1305
  Hash:             BLAKE2s
  Signatures:       Ed25519 (upgrade path to ML-DSA-65 in GRP/2)
  Block Size:       16,384 bytes with '#' padding (matches SMP)
  Rekeying:         Every 2-5 minutes or 1000 messages
```

---

## 8. Risk assessment

### 8.1 Protocol and implementation risks

| Risk | Impact | Likelihood | Mitigation |
|------|--------|------------|------------|
| SimpleX changes smp-web API before release | High | Medium | Pin to specific commit, contribute upstream |
| Double Ratchet implementation complexity | Medium | High | Start with NaCl box MVP, upgrade later |
| WebSocket blocked by corporate firewalls | Medium | Low | HTTP/2 long-polling fallback (future), GRP stego transport |
| Browser crypto performance on mobile | Low | Low | Web Crypto API is hardware-accelerated |
| SimpleX app UX for support team | Low | Medium | Desktop app handles multiple chats well |

### 8.2 Browser-specific security risks

| Risk | Impact | Likelihood | Mitigation |
|------|--------|------------|------------|
| XSS defeating all encryption | Critical | Medium | Strict CSP, SRI, Web Worker isolation, minimal dependencies (SEC-1 to SEC-3) |
| Server-delivered code manipulation | Critical | Low | Reproducible builds, SRI hashes, transparent documentation (SEC-4) |
| npm supply chain attack | High | Medium | @noble-only crypto (minimal deps), lockfile pinning, SRI verification (SEC-2) |
| Cross-Site WebSocket Hijacking | High | Low | Token-based auth (not cookies), no ambient credentials (SEC-5) |
| SMP self-signed certs rejected by browser | High | Certain | Let's Encrypt for TLS layer, SMP fingerprint at app layer (SEC-5) |
| IndexedDB key material extraction | Medium | Low | Non-extractable CryptoKey objects, AES-256-GCM encryption at rest (E2E-3) |
| Tab/session state loss | Medium | Medium | SharedWorker persistence, IndexedDB message queue (WS-4) |

---

## 9. Open questions

1. **Upstream contribution:** Should we contribute our WebSocket transport client back to the `smp-web` package? This aligns with AGPL-3.0 obligations and could get review from the SimpleX team.

2. **Server choice:** Self-hosted SMP server vs using SimpleX's public servers? Self-hosted gives full control but requires maintenance. Public servers are free but we trust SimpleX infrastructure.

3. **Message persistence:** How long should chat history persist in the browser? Options: session-only (cleared on tab close), 24 hours, persistent until manually cleared.

4. **Bot integration:** Should we add automated responses for common questions? Could be implemented as a separate bot process connecting via the same SimpleX CLI WebSocket API.

5. **Notification:** When the support team is offline, should the chat show an away message? SimpleX delivers messages asynchronously, so they arrive when the team comes back online.

6. **ML-KEM in browser:** For GRP-2, should we use a pure JavaScript ML-KEM implementation or a WASM-compiled Rust/C library? Pure JS is simpler to audit, WASM is faster and has better side-channel resistance.

7. **SharedWorker fallback:** SharedWorker is not supported in all contexts (e.g., some mobile browsers). What is the fallback strategy? Dedicated Worker per tab with reduced tab-persistence capability?

---

## 10. Ecosystem context

GoChat is one component of the SimpleGo ecosystem for encrypted communication across platforms.

| Project | What it does | Language | Status |
|:--------|:-------------|:---------|:-------|
| **[SimpleGo](https://github.com/saschadaemgen/SimpleGo)** | First native C implementation of SimpleX protocol on ESP32-S3. Autonomous encrypted messaging device with 4-layer encryption, Double Ratchet, and post-quantum key exchange (sntrup761). | C (21,863 lines) | Alpha, 7 contacts verified |
| **GoRelay** | Dual-protocol relay server. SMP on port 5223, GRP on port 7443 with Noise transport, mandatory PQC (ML-KEM-768), two-hop routing, cover traffic, zero-knowledge storage with cryptographic deletion. | Go (~5,000 lines) | Alpha, SimpleX test passing |
| **GoChat** | Browser-native encrypted messenger. SMP profile for everyday use, GRP profile for high-security. No app install needed. (This project) | TypeScript | Season 1 |

### How the ecosystem connects

```
+-----------+     +----------+     +-----------+     +----------+     +----------+
|  GoChat   |     |  SMP     |     |  GoRelay  |     |  SMP     |     | SimpleX  |
|  Browser  |---->|  Server  |---->|  (bridge) |---->|  Server  |---->|  App     |
|  SMP mode |     |  (any)   |     |           |     |  (any)   |     | Phone/PC |
+-----------+     +----------+     +-----------+     +----------+     +----------+

+-----------+                      +-----------+                      +----------+
|  GoChat   |                      |  GoRelay  |                      | SimpleGo |
|  Browser  |--------------------->|  GRP      |--------------------->| Hardware |
|  GRP mode |  Noise + PQ + 2-hop |  Server   |  Noise + PQ + 2-hop | ESP32-S3 |
+-----------+                      +-----------+                      +----------+
```

**SMP path (top):** Standard SimpleX-compatible communication. Any SMP server works as relay. Receiving end: SimpleX Chat app or SimpleGo terminal.

**GRP path (bottom):** High-security with post-quantum protection, Noise transport, two-hop routing. GoRelay exclusive. Receiving end: SimpleGo hardware.

**GoRelay as bridge:** Dual-protocol, cross-protocol delivery. SMP in, GRP out, and vice versa.

---

## 11. Task registry (quick reference)

| ID | Layer | Description | Season |
|:---|:------|:------------|:-------|
| WS-1 | Transport | WebSocket transport class (ChatTransport) | S2 |
| WS-2 | Transport | SMP client with handshake | S2 |
| WS-3 | Transport | Connection pooling and reconnect | S2 |
| WS-4 | Transport | SharedWorker for tab persistence | S6 |
| CMD-1 | Commands | Queue creation (NEW/IDS) | S3 |
| CMD-2 | Commands | Sender commands (SEND/SKEY) | S3 |
| CMD-3 | Commands | Recipient commands (SUB/ACK/KEY/DEL/MSG) | S3 |
| CMD-4 | Commands | Connection link commands (LGET/LNK/LSND) | S3 |
| CMD-5 | Commands | Utility commands (PING/PONG/ERR) | S3 |
| CONN-1 | Connection | Contact address parsing | S4 |
| CONN-2 | Connection | Connection initiation | S4 |
| CONN-3 | Connection | Connection acceptance handling | S4 |
| CONN-4 | Connection | Connection state machine | S4 |
| E2E-1 | Encryption | Key agreement (X3DH) | S5 |
| E2E-2 | Encryption | Message encryption (NaCl MVP, DR full) | S5 |
| E2E-3 | Encryption | Key storage (IndexedDB + AES-256-GCM) | S5 |
| UI-1 | Chat UI | Nose-bar integration | S6 |
| UI-2 | Chat UI | Chat panel | S6 |
| UI-3 | Chat UI | Chat state management | S6 |
| UI-4 | Chat UI | Mobile responsive | S6 |
| UI-5 | Chat UI | SPA router integration | S7 |
| UI-6 | Chat UI | Intercom-level animations | S6 |
| UI-7 | Chat UI | Encryption badge | S6 |
| UI-8 | Chat UI | Accessibility (WCAG 2.1 AA) | S6 |
| SEC-1 | Security | Content Security Policy | S8 |
| SEC-2 | Security | Subresource Integrity | S8 |
| SEC-3 | Security | Web Worker crypto isolation | S5 |
| SEC-4 | Security | Trust boundary documentation | S8 |
| SEC-5 | Security | TLS certificate strategy | S2 |
| OPS-1 | Deployment | SMP server deployment | S8 |
| OPS-2 | Deployment | Contact address setup | S8 |
| OPS-3 | Deployment | Monitoring | S8 |
| GRP-1 | GRP Transport | Noise Protocol transport | S9 |
| GRP-2 | GRP Transport | ML-KEM-768 post-quantum | S9 |
| GRP-3 | GRP Transport | Two-hop relay routing | S10 |
| GRP-4 | GRP Transport | Triple Shield (ZKP, Shamir, Stego) | S11+ |

---

## 12. Changelog

| Date | Change |
|------|--------|
| 2026-03-25 | Initial protocol document created. Analyzed `ep/smp-web-spike` branch, documented existing infrastructure, defined implementation roadmap. |
| 2026-03-25 | Major update: added dual-profile architecture (SMP + GRP), ChatTransport interface requirement, new task categories (GRP-1 to GRP-4, SEC-1 to SEC-5, UI-6 to UI-8, WS-4), browser-specific risk assessment, ecosystem context, ground rules, task registry. |
