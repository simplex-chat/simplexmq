# SimpleGo Support Chat - SMP-Web Integration Protocol

**Project:** SimpleGo Website - Encrypted Support Chat via SimpleX  
**Date:** 2026-03-25  
**Branch analyzed:** `ep/smp-web-spike` on `simplex-chat/simplexmq`  
**Status:** Research & planning phase

---

## 1. Executive summary

SimpleX Chat is actively building `smp-web` - a browser-native SMP (SimpleX Messaging Protocol) client that allows websites to offer end-to-end encrypted chat without requiring users to install any app or create any account. The spike branch (`ep/smp-web-spike`) was created by Evgeny Poberezkin (SimpleX founder) on 2026-03-22, with the most recent commit on 2026-03-22.

Combined with PR #1738 (WebSocket support on the SMP server's web port, merged 2026-03-20), this creates a viable path for embedding a fully encrypted support chat directly into the SimpleGo website.

**Key advantages over traditional support chat solutions:**

- Zero user registration - visitors chat anonymously
- End-to-end encryption - not even the server operator can read messages
- No middleware bridge needed - browser talks directly to SMP relay
- Multi-user support natively built into SimpleX contact address system
- AGPL-3.0 licensed - fully open source

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

**What the server sees:** Isolated encrypted blobs in anonymous queues. No user IDs, no metadata linking Queue 1 to Queue 2, no way to correlate sender and receiver.

### 2.2 Connection establishment flow

1. **Contact address creation:** The support team creates a permanent SimpleX contact address in their app. This generates a link containing the server address and a public key.

2. **User connects:** When a website visitor clicks "Support Chat", their browser:
   - Parses the contact address link
   - Creates a new queue pair on the SMP server
   - Performs X3DH key agreement
   - Sends a connection request through the contact address queue

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

## 3. What already exists (analysis of the spike branch)

### 3.1 Server-side (Haskell - production ready)

| Component | Status | Location | Notes |
|-----------|--------|----------|-------|
| SMP server with all commands | DONE | `src/Simplex/Messaging/` | NEW, SUB, SEND, MSG, ACK, KEY, DEL, LGET, LNK |
| WebSocket on port 443 | DONE | PR #1738, merged 2026-03-20 | Browser WS and native TLS on same port via SNI routing |
| Contact address / short links | DONE | Protocol level | Permanent contact address for support team |
| XFTP file transfer | DONE | Separate protocol | Could be used for file attachments later |
| TLS + identity verification | DONE | Server handshake | Ed25519 certificate chain verification |

### 3.2 Browser-side shared infrastructure (xftp-web - production tested)

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

### 3.3 Browser-side SMP client (smp-web - spike / in progress)

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

### 3.4 Key commits on the branch

| Hash | Date | Description |
|------|------|-------------|
| `4b89a7f` | 2026-03-22 | `encoding/decoding of LGET/LNK` - Core SMP protocol in TypeScript |
| `3eeffff` | 2026-03-22 | `smp web: initial setup` - Package scaffolding |
| `01fe841` | 2026-03-20 | `smp: allow websocket connections on the same port (#1738)` - WebSocket transport on SMP server |
| `1a12ee0` | 2026-03-20 | `xftp-web: version bump to 0.3.0 (#1742)` - Updated shared dependency |
| `dc2921e` | 2026-03-18 | `xftp-server: embed file download widget (#1733)` - Web embedding pattern |
| `328d3b9` | 2026-03-11 | `xftp-web: use XFTP server domain in share link (#1732)` - Security improvement |

---

## 4. What needs to be built

### 4.1 Layer 1: WebSocket SMP transport client (CRITICAL PATH)

**Priority:** Highest - everything else depends on this.

The xftp-web client uses HTTP/2 POST requests for transport. SMP messaging requires a persistent bidirectional connection (for receiving messages in real-time). PR #1738 added WebSocket support to the SMP server. We need a browser-side WebSocket client that mirrors the existing HTTP/2 transport interface.

**Tasks:**

- [ ] **WS-1:** Create `smp-web/src/transport.ts` - WebSocket transport class
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
  - Auto-reconnect with exponential backoff
  - Re-subscribe to queues after reconnect

### 4.2 Layer 2: SMP command implementation

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

### 4.3 Layer 3: Connection management (SMP Agent logic)

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

### 4.4 Layer 4: End-to-end encryption

**Priority:** High - messages must be encrypted.

SimpleX uses Double Ratchet (Signal protocol) for E2E encryption with X3DH key agreement. For a support chat MVP, we could start with a simpler NaCl box encryption per-message and upgrade to Double Ratchet later.

**Tasks:**

- [ ] **E2E-1:** Key agreement (X3DH - Extended Triple Diffie-Hellman)
  - Generate identity key pair (X25519)
  - Generate signed pre-key
  - Generate one-time pre-key
  - Compute shared secret from X3DH
  - **Alternative MVP:** Use single X25519 DH for shared secret (simpler, no forward secrecy)

- [ ] **E2E-2:** Message encryption
  - **MVP:** NaCl secretbox with shared DH secret (already available in xftp-web/crypto)
  - **Full:** Double Ratchet with symmetric key ratchet + DH ratchet
  - Message padding to fixed block size (already available in xftp-web/crypto)

- [ ] **E2E-3:** Key storage
  - Store key material in browser (IndexedDB with encryption)
  - Handle key rotation for long-lived sessions
  - Clear keys on session end / user request

### 4.5 Layer 5: Chat UI (SimpleGo frontend)

**Priority:** Medium - can be built in parallel with protocol work.

**Tasks:**

- [ ] **UI-1:** Nose-bar integration
  - Add chat icon to nose-bar (similar to player idle state)
  - Show unread message count badge
  - Toggle chat panel open/close (reuse player panel pattern)

- [ ] **UI-2:** Chat panel
  - Panel drops down from nose-bar (same as player panel)
  - Message bubbles: outgoing (right, accent color) / incoming (left, card bg)
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
  - Touch-friendly message input
  - Adapt to existing SimpleGo mobile breakpoints

- [ ] **UI-5:** SPA router integration
  - Chat state persists across page navigation (SPA router)
  - WebSocket connection survives route changes
  - Panel state (open/closed) persists

### 4.6 Layer 6: Deployment & operations

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
  - Embed contact address in SimpleGo website config

- [ ] **OPS-3:** Monitoring
  - SMP server health checks
  - Queue count monitoring
  - Connection error tracking in browser (optional analytics)

---

## 5. Implementation roadmap

### Phase 1: Foundation (weeks 1-2)

**Goal:** Browser can connect to SMP server and exchange raw messages.

1. Fork the `ep/smp-web-spike` branch
2. Implement WebSocket transport client (WS-1, WS-2)
3. Implement core SMP commands: NEW, SUB, SEND, ACK (CMD-1 to CMD-3)
4. Basic NaCl encryption for messages (E2E-2 MVP)
5. Test: send a message from browser, receive in SimpleX CLI

### Phase 2: Connection flow (weeks 3-4)

**Goal:** Website visitor can connect to support team via contact address.

1. Contact address parsing (CONN-1)
2. Connection initiation flow (CONN-2, CONN-3)
3. Connection state persistence in browser (CONN-4)
4. Deploy SMP server on VPS (OPS-1, OPS-2)
5. Test: full connection flow from browser to SimpleX mobile app

### Phase 3: Chat UI (weeks 4-5)

**Goal:** Functional chat interface integrated into SimpleGo website.

1. Nose-bar chat integration (UI-1)
2. Chat panel with message bubbles (UI-2)
3. Message persistence in IndexedDB (UI-3)
4. SPA router integration (UI-5)
5. Mobile responsive layout (UI-4)

### Phase 4: Hardening (weeks 5-6)

**Goal:** Production-ready encrypted support chat.

1. Upgrade to X3DH key agreement (E2E-1)
2. Implement Double Ratchet for forward secrecy (E2E-2 full)
3. Reconnection handling and offline message queue
4. Error handling and user-facing error states
5. Performance optimization and bundle size

### Phase 5: Polish (week 6+)

**Goal:** Feature-complete support experience.

1. Unread message notifications
2. Typing indicators
3. File/image sharing via XFTP
4. Chat session resume after browser restart
5. Optional: bot auto-responses for common questions

---

## 6. Technical reference

### 6.1 SMP wire format

Each SMP transmission is a fixed-size block (16384 bytes) with padding:

```
[auth: ByteString] [corrId: ByteString] [entityId: ByteString] [command: raw bytes]
```

- `auth`: Authenticator (empty for unsigned transmissions)
- `corrId`: Correlation ID (matches response to request)
- `entityId`: Queue ID (identifies which queue the command targets)
- `command`: SMP command tag + parameters

Encoding uses length-prefixed byte strings (1-byte length for short, 2-byte for large).

### 6.2 Existing code map

```
simplexmq/
  smp-web/                          # NEW - SMP browser client
    src/
      index.ts                      # Re-exports encoding primitives from xftp-web
      protocol.ts                   # SMP transmission encode/decode, LGET/LNK
    package.json                    # @simplex-chat/smp-web v0.1.0

  xftp-web/                         # EXISTING - shared infrastructure
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

  src/Simplex/Messaging/            # Haskell SMP server (reference implementation)
    Protocol.hs                     # SMP command definitions + encoding
    Server.hs                       # Server logic, AttachHTTP, WSHandler
    Server/Web.hs                   # Static files + WebSocket routing
    Transport/WebSockets.hs         # WebSocket connection handling
```

### 6.3 Dependencies

| Package | Version | Purpose |
|---------|---------|---------|
| `@noble/hashes` | ^1.5.0 | SHA-256, SHA-512 (used by xftp-web crypto) |
| `@simplex-chat/xftp-web` | file:../xftp-web | Encoding, crypto, transport primitives |
| `typescript` | ^5.4.0 | Build tooling |
| `ws` | ^8.0.0 | WebSocket (dev/test only, browser uses native WebSocket) |

### 6.4 SMP command reference (to implement)

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

---

## 7. Risk assessment

| Risk | Impact | Likelihood | Mitigation |
|------|--------|------------|------------|
| SimpleX changes smp-web API before release | High | Medium | Pin to specific commit, contribute upstream |
| Double Ratchet implementation complexity | Medium | High | Start with NaCl box MVP, upgrade later |
| WebSocket blocked by corporate firewalls | Medium | Low | Falls back to HTTP/2 long-polling (future) |
| Browser crypto performance on mobile | Low | Low | Web Crypto API is hardware-accelerated |
| SimpleX app UX for support team | Low | Medium | Desktop app handles multiple chats well |

---

## 8. Open questions

1. **Upstream contribution:** Should we contribute our WebSocket transport client back to the `smp-web` package? This aligns with AGPL-3.0 obligations and could get review from the SimpleX team.

2. **Server choice:** Self-hosted SMP server vs using SimpleX's public servers? Self-hosted gives full control but requires maintenance. Public servers are free but we trust SimpleX infrastructure.

3. **Message persistence:** How long should chat history persist in the browser? Options: session-only (cleared on tab close), 24 hours, persistent until manually cleared.

4. **Bot integration:** Should we add automated responses for common questions? Could be implemented as a separate bot process connecting via the same SimpleX CLI WebSocket API.

5. **Notification:** When the support team is offline, should the chat show an away message? SimpleX delivers messages asynchronously, so they arrive when the team comes back online.

---

## 9. Changelog

| Date | Change |
|------|--------|
| 2026-03-25 | Initial protocol document created. Analyzed `ep/smp-web-spike` branch, documented existing infrastructure, defined implementation roadmap. |
