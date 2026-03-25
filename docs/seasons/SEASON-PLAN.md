<p align="center">
  <img src="../../.github/assets/gochat_banner.png" alt="GoChat" width="1500" height="230">
</p>

<h1 align="center">GoChat - Season Plan</h1>

<p align="center">
  <strong>Season-based development roadmap for the GoChat encrypted web messenger.</strong><br>
  Each season has a clear goal, defined scope, and produces a protocol document with learnings.
</p>

---

**Project:** GoChat - Browser-Native Encrypted Messenger  
**Parent project:** [SimpleGo](https://github.com/saschadaemgen/SimpleGo)  
**Workflow:** Season-based development with Claude Code  
**Planning by:** Prinzessin Mausi  
**Code by:** Claude Code  
**Direction by:** Sascha (saschadaemgen)  
**Repository:** [saschadaemgen/GoChat](https://github.com/saschadaemgen/GoChat)  
**Base branch:** `ep/smp-web-spike`

---

## How we work

Each season has a clear goal, a defined scope, and produces a protocol document at the end documenting all successes, failures, and learnings. Code is written by Claude Code, directed and reviewed by Sascha, planned by Prinzessin Mausi in the chat sessions.

**Ground rule (all seasons):** Nothing invented. What is missing gets asked. The Prinzessin shows everything needed.

All commits follow Conventional Commits format: `type(scope): description`

Season protocol documents live in `docs/seasons/` and serve as a development diary - anyone can look at the source code and understand how and why we built things the way we did.

```
docs/
  PROTOCOL.md                    # Main technical protocol
  RESEARCH.md                    # Browser crypto, security, design research
  seasons/
    SEASON-PLAN.md               # This file
    SEASON-01-planning.md        # Planning & documentation
    SEASON-02-transport.md       # WebSocket transport
    SEASON-03-commands.md        # SMP commands
    SEASON-04-connection.md      # Connection flow
    SEASON-05-encryption.md      # E2E encryption
    SEASON-06-ui.md              # Chat UI (Intercom-level)
    SEASON-07-integration.md     # SimpleGo integration
    SEASON-08-hardening.md       # Production hardening
    SEASON-09-noise.md           # GRP: Noise transport
    SEASON-10-postquantum.md     # GRP: ML-KEM-768 post-quantum
    SEASON-11-routing.md         # GRP: Two-hop relay routing
```

---

## Season 1: Planning and documentation (CURRENT)

**Status:** Nearing completion  
**Goal:** Complete project analysis, fork setup, dual-profile architecture design, deep research, community contact, roadmap, and workflow definition.

### Deliverables

- [x] Analyze `ep/smp-web-spike` branch - understand what exists
- [x] Analyze PR #1738 (WebSocket on SMP server port)
- [x] Analyze xftp-web shared infrastructure (crypto, encoding, transport)
- [x] Write main protocol document (`PROTOCOL.md`)
- [x] Fork repository (GoChat)
- [x] Clean repo: remove all Haskell code, 80+ upstream branches
- [x] Replace README with project documentation
- [x] Research SimpleX community discussion about smp-web
- [x] Post in SimpleX community about our plans
- [x] Evgeny Poberezkin (SimpleX founder) confirms smp-web is active WIP
- [x] Community feedback: "10 of 10 Points" for architecture diagram
- [x] Write season plan document
- [x] Deep research: browser crypto maturity, security analysis, design patterns
- [x] Write research document (`RESEARCH.md`)
- [x] Design dual-profile architecture (SMP + GRP)
- [x] Define ChatTransport interface as day-one abstraction requirement
- [x] Update PROTOCOL.md with dual-profile, GRP tasks, SEC tasks, expanded UI tasks
- [x] Update RESEARCH.md with dual-profile context throughout
- [x] Update SEASON-PLAN.md with GRP seasons and expanded scope
- [x] Set up GPG signing (key E13737C02E97E54B)
- [x] Create `.claude/CLAUDE.md` for Claude Code instructions
- [x] Create `.github/assets/gochat_banner.png`
- [ ] Create season 1 closing protocol (`SEASON-01-planning.md`)
- [ ] Prepare task list for Claude Code (Season 2 briefing)

### Key decisions made

1. **Architecture:** Direct browser-to-SMP-server via WebSocket (no CLI bridge)
2. **Base:** Build on top of `ep/smp-web-spike`, reuse xftp-web infrastructure
3. **Dual-profile architecture:** SMP profile for everyday use, GRP profile for high-security environments. Both profiles share the same chat UI and ChatTransport interface abstraction. This is the single most important architectural decision in Season 1.
4. **ChatTransport interface from day one:** All transport code goes through an abstract interface, ensuring GRP can be added later without touching application-level code
5. **Encryption MVP:** Start with NaCl secretbox via @noble/ciphers, upgrade to Double Ratchet later
6. **Crypto library:** @noble/curves + @noble/ciphers + @noble/hashes for both profiles (6 audits, used by Proton Mail, MetaMask)
7. **Multi-user:** Native via SimpleX contact address system
8. **UI ambition:** Intercom-level polish, not "functional minimum". Encryption badge is the brand.
9. **Project name:** GoChat (ecosystem: SimpleGo, GoRelay, GoChat)
10. **No mobile app:** SimpleX covers mobile/desktop. GoChat fills the browser gap.
11. **GoChat extends SimpleX, does not replace it.** GRP is an additional security layer via GoRelay, not a competing protocol.

### Open questions for Season 2

- Should we contribute WebSocket transport client upstream?
- Self-hosted SMP server or SimpleX public servers for development?
- How to handle the xftp-web dependency during development (local link vs npm)?

---

## Season 2: WebSocket transport client

**Goal:** Browser can establish a WebSocket connection to an SMP server, complete the handshake, and send/receive raw SMP blocks. The transport class must implement the ChatTransport interface.

**This is the foundation - nothing else works without it.**

### Scope

- `smp-web/src/transport.ts` - WebSocket transport class implementing `ChatTransport`
  - Connect to `wss://server:443`
  - Binary message framing (SMP uses fixed 16KB blocks)
  - Connection lifecycle: open, close, error, reconnect
  - Heartbeat via PING/PONG
- `smp-web/src/client.ts` - SMP client with handshake
  - Adapt handshake for SMP protocol (different from XFTP)
  - Version negotiation
  - Session ID management
- TLS certificate strategy: Let's Encrypt for browser WSS, SMP fingerprint at app layer (SEC-5)
- Test against a real SMP server (SimpleX public or local Docker)

### Tasks for Claude Code

```
Task references: WS-1, WS-2, WS-3, SEC-5 from PROTOCOL.md
```

### Success criteria

- [ ] Browser opens WebSocket to SMP server on port 443
- [ ] Handshake completes successfully
- [ ] PING/PONG keepalive works
- [ ] Connection auto-reconnects after drop
- [ ] Can send a raw SMP block and receive a response
- [ ] Transport class implements ChatTransport interface

### What to watch out for

- SMP handshake is TLS-level, not HTTP-level like XFTP
- WebSocket binary frames vs SMP block framing alignment
- Browser security: WSS required, no self-signed certs in production
- The existing `xftp-web/src/client.ts` is the reference - study `connectXFTP()` carefully
- All transport code must go through ChatTransport abstraction from the first line

---

## Season 3: SMP commands

**Goal:** Implement all SMP commands needed for basic messaging.

### Scope

- `smp-web/src/commands.ts` - SMP command encoders/decoders
  - `NEW` / `IDS` - Create queue
  - `SUB` - Subscribe to queue
  - `SEND` / `MSG` - Send and receive messages
  - `ACK` - Acknowledge receipt
  - `KEY` - Set sender key
  - `DEL` - Delete queue
- `smp-web/src/protocol.ts` - Extend existing file with new response types
- Unit tests for encode/decode roundtrips

### Tasks for Claude Code

```
Task references: CMD-1, CMD-2, CMD-3, CMD-4, CMD-5 from PROTOCOL.md
```

### Success criteria

- [ ] Can create a queue on SMP server (NEW -> IDS)
- [ ] Can subscribe to a queue (SUB)
- [ ] Can send a message to a queue (SEND -> OK)
- [ ] Can receive a message from a queue (MSG event)
- [ ] Can acknowledge message receipt (ACK)
- [ ] All commands have encode/decode unit tests

---

## Season 4: Connection flow

**Goal:** Full connection establishment from browser to SimpleX app via contact address.

### Scope

- `smp-web/src/connection.ts` - Connection manager
  - Parse SimpleX contact address URI
  - Create queue pair (two NEW commands)
  - X25519 key exchange
  - Send connection request
  - Handle connection confirmation
- `smp-web/src/agent.ts` - Minimal SMP agent
  - Connection state machine: NEW -> PENDING -> CONNECTED -> CLOSED
  - Queue pair management
  - Message routing (incoming MSG -> correct connection)

### Tasks for Claude Code

```
Task references: CONN-1, CONN-2, CONN-3, CONN-4 from PROTOCOL.md
```

### Success criteria

- [ ] Can parse a SimpleX contact address link
- [ ] Browser creates queue pair on SMP server
- [ ] Connection request reaches SimpleX mobile/desktop app
- [ ] Support team can accept connection
- [ ] Bidirectional message exchange works
- [ ] Connection state persists across page reloads

### This is the big milestone

After this season, we have a working chat between browser and SimpleX app. Everything after this is encryption hardening and UI polish.

---

## Season 5: End-to-end encryption

**Goal:** Messages are properly encrypted, not just transported.

### Scope

- `smp-web/src/crypto/e2e.ts` - E2E encryption module
  - MVP: NaCl secretbox with DH shared secret via @noble/ciphers
  - Key derivation from X25519 agreement via @noble/curves
  - Message padding (reuse xftp-web padding)
- `smp-web/src/crypto/keys-store.ts` - Browser key storage
  - IndexedDB for key material with `extractable: false`
  - AES-256-GCM encryption at rest
  - Key cleanup on session end
- Web Worker isolation for all crypto operations (SEC-3)

### Tasks for Claude Code

```
Task references: E2E-1 (MVP), E2E-2, E2E-3, SEC-3 from PROTOCOL.md
```

### Success criteria

- [ ] Messages encrypted before sending, decrypted on receive
- [ ] Keys stored securely in browser IndexedDB
- [ ] Support team's SimpleX app can decrypt our messages
- [ ] We can decrypt messages from the support team
- [ ] Key material cleared on explicit session end
- [ ] All crypto runs in dedicated Web Worker

### Future upgrade (not this season)

- X3DH key agreement for proper forward secrecy
- Double Ratchet for ongoing forward secrecy
- This is a separate season if we decide to pursue it

---

## Season 6: Chat UI (Intercom-level design)

**Goal:** Beautiful, polished chat interface with Intercom-level quality. The encryption badge is the brand differentiator.

GoChat must achieve Intercom-level polish, not Chatwoot-level "it works". Every animation, every transition, every pixel matters. The chat panel is the first thing visitors see - it must signal quality, trust, and security.

### Scope

- `chat.css` - Chat panel styles matching SimpleGo design system
  - Panel: 380px wide, 520-550px tall, 100vh on mobile
  - Bubble border-radius 18px (4px on tail), max-width 70-75%
  - Dark mode: #121212 bg, #E0E0E0 text (no pure black/white)
  - Primary color: Blue (#3B82F6 range) - signals trust
- `chat.js` - Chat UI logic
  - Nose-bar chat icon with unread badge
  - Dropdown panel (same pattern as player panel)
  - Message bubbles (outgoing right / incoming left)
  - Text input with send button
  - Connection status indicator
  - Auto-scroll behavior
- Intercom-level animation system
  - Message appear: fade + translateY(10px->0) at 200ms ease-out
  - Panel open: scale(0.9->1) + opacity(0->1) + translateY(20->0)
  - Typing indicator: three 8px dots with staggered delay
  - Launcher morph: chat bubble to X/close with 300ms rotation
  - Launcher: 56px circular FAB, bottom-right, 20px margin
  - All transitions: 200-300ms ease-out, only transform + opacity for 60fps
  - All animations must respect `prefers-reduced-motion`
- Encryption badge: persistent lock icon + "End-to-end encrypted"
  - Profile indicator: SMP vs GRP when dual-profile is available
- Accessibility (WCAG 2.1 AA)
  - Chat container: `role="log"` with `aria-live="polite"`
  - All interactive elements: visible focus indicators + keyboard operability
  - Touch targets: minimum 44x44px
  - Color never the sole status indicator
- SharedWorker for tab persistence (WS-4)
- Message store in IndexedDB for chat history

### Tasks for Claude Code

```
Task references: UI-1, UI-2, UI-3, UI-6, UI-7, UI-8, WS-4 from PROTOCOL.md
```

### Success criteria

- [ ] Chat icon in nose-bar with unread count
- [ ] Panel opens/closes with Intercom-quality animations
- [ ] Messages display correctly with timestamps and smooth appear animation
- [ ] Text input sends messages on Enter
- [ ] Chat history persists across page navigation (SharedWorker + IndexedDB)
- [ ] Works alongside the music player without conflicts
- [ ] Encryption badge always visible, communicates security status
- [ ] Typing indicator works with proper animation
- [ ] WCAG 2.1 AA compliance verified
- [ ] All animations respect prefers-reduced-motion
- [ ] Dark mode looks professional (no pure black/white)

---

## Season 7: SimpleGo website integration

**Goal:** Chat is fully integrated into the SimpleGo website, accessible from all pages.

### Scope

- Add chat button to homepage (replace/augment "Explore Product")
- Chat HTML structure in base template
- SPA router integration (chat survives page navigation)
- Mobile responsive layout (full-screen chat panel on mobile)
- Chat + Player coexistence (both in nose-bar)

### Tasks for Claude Code

```
Task references: UI-4, UI-5 from PROTOCOL.md
```

### Success criteria

- [ ] Chat available on every page of the website
- [ ] Works on mobile (full-screen chat panel)
- [ ] SPA navigation doesn't break chat connection
- [ ] Player and chat can both be active simultaneously
- [ ] "Support Chat" button on homepage works

---

## Season 8: Production hardening

**Goal:** Battle-tested, deployable support chat system with complete security hardening.

### Scope

- SMP server deployment on VPS (Docker)
- TLS certificate setup (Let's Encrypt)
- Contact address creation and configuration
- Error handling for all edge cases
- Offline/away state handling
- Reconnection after network interruption
- Performance optimization (bundle size, memory)
- Security hardening
  - Content Security Policy (SEC-1)
  - Subresource Integrity (SEC-2)
  - Trust boundary documentation (SEC-4)
- Security review

### Tasks for Claude Code

```
Task references: OPS-1, OPS-2, OPS-3, SEC-1, SEC-2, SEC-4 from PROTOCOL.md
```

### Success criteria

- [ ] SMP server running on production VPS
- [ ] Chat works reliably for 8+ hours without issues
- [ ] Handles network interruptions gracefully
- [ ] Error states shown clearly to user
- [ ] Bundle size reasonable (< 100KB gzipped for chat module)
- [ ] No memory leaks in long-running sessions
- [ ] Strict CSP enforced (no eval, no inline scripts)
- [ ] SRI hashes on all external scripts
- [ ] Security trust boundary documented transparently

### SMP profile complete after this season

After Season 8, GoChat's SMP profile is production-ready. The GRP profile development begins in Season 9.

---

## Season 9: GRP - Noise transport

**Goal:** Implement the Noise Protocol transport layer for the GRP profile.

This is the beginning of GoChat's high-security communication profile. The GRP profile speaks the GoRelay Protocol exclusively through GoRelay infrastructure, starting with the Noise transport foundation.

### Scope

- `smp-web/src/grp/transport.ts` - GRP transport class implementing `ChatTransport`
  - Noise_IK_25519_ChaChaPoly_BLAKE2s (primary pattern, server key pre-known)
  - Noise_XX fallback for first-contact scenarios
  - Protocol identifier: "GRP/1" as the Prologue
  - No cipher negotiation - fixed suite per protocol version
  - Rekeying every 2-5 minutes or every 1000 messages
- Browser Noise implementation via @noble/ciphers (ChaCha20-Poly1305) and @noble/hashes (BLAKE2s)
- Connect to GoRelay server on port 7443 via WSS
- Noise handshake inside WebSocket (WSS for browser cert acceptance, Noise for actual security)

### Tasks for Claude Code

```
Task references: GRP-1 from PROTOCOL.md
```

### Success criteria

- [ ] GRP transport implements ChatTransport interface
- [ ] Noise IK handshake completes against GoRelay server
- [ ] Can send/receive 16KB blocks through Noise-encrypted channel
- [ ] Rekeying works on timer and message count thresholds
- [ ] Profile switching works at runtime (swap SMP transport for GRP transport)

### Prerequisites

- GoRelay must have GRP listener implemented (GoRelay Phase 4)
- @noble/ciphers and @noble/hashes confirmed working for Noise cipher suite

---

## Season 10: GRP - Post-quantum key exchange

**Goal:** Add mandatory ML-KEM-768 hybrid key exchange to the GRP transport.

### Scope

- Hybrid X25519 + ML-KEM-768 key exchange in the Noise handshake
  - ML-KEM-768 targets NIST Security Level 3 (AES-192 equivalent)
  - Not optional, cannot be disabled - handshake aborts if ML-KEM fails
  - Combination via HKDF: ML-KEM secret first (FIPS ordering), then X25519 secret
- Evaluate and implement ML-KEM-768 for the browser
  - Option A: Pure JS implementation (@noble-style, auditable)
  - Option B: WASM-compiled Rust/C (better side-channel resistance)
  - Option C: Hybrid approach (WASM for ML-KEM, JS for classical)
- Total handshake overhead: ~2,336 bytes (vs 64 bytes for X25519 alone)

### Tasks for Claude Code

```
Task references: GRP-2 from PROTOCOL.md
```

### Success criteria

- [ ] Hybrid key exchange completes against GoRelay server
- [ ] ML-KEM-768 encapsulation/decapsulation works in browser
- [ ] Handshake aborts cleanly if ML-KEM component fails
- [ ] Key material properly zeroed after use
- [ ] Performance acceptable (< 500ms for full hybrid handshake)

### Prerequisites

- GoRelay must have ML-KEM-768 hybrid exchange implemented (GoRelay Phase 4)
- Browser ML-KEM library evaluated and selected

---

## Season 11: GRP - Two-hop relay routing

**Goal:** Implement mandatory two-hop message routing for the GRP profile.

### Scope

- Two-hop relay architecture
  - Every GRP message passes through two GoRelay servers
  - Relay A sees sender IP but not destination queue
  - Relay B sees destination queue but not sender IP
  - Neither server alone can link sender to recipient
- SMP routing commands: PFWD, RFWD, RRES, PRES
- Per-message ephemeral key for s2d encryption (prevents cross-queue correlation)
- Five encryption layers per message: e2e, s2d, f2d, Noise transport, storage AES-256-GCM
- Cover traffic integration (Poisson-distributed dummy messages from GoRelay)

### Tasks for Claude Code

```
Task references: GRP-3 from PROTOCOL.md
```

### Success criteria

- [ ] Messages route through two GoRelay servers
- [ ] Neither server has complete metadata (sender + destination)
- [ ] Per-message ephemeral keys prevent cross-queue correlation
- [ ] Cover traffic indistinguishable from real messages
- [ ] Latency acceptable (< 50ms added for same-region servers)

### Prerequisites

- GoRelay must have two-hop relay implemented (GoRelay Phase 5)
- Minimum two GoRelay servers deployed in different jurisdictions

---

## Season 12+: GRP - Triple Shield and beyond

**Goal:** Implement the Triple Shield defense layer and additional GRP features.

These are long-term goals that depend on GoRelay Phase 6 completion.

### Potential future seasons

- **Triple Shield 6a:** Zero-Knowledge Queue Authentication (Schnorr DLOG via Fiat-Shamir)
- **Triple Shield 6b:** Shamir's Secret Sharing 2-of-3 across servers
- **Triple Shield 6c:** Steganographic Transport (Pluggable Transports: HTTPS, WebSocket, meek, obfs4)
- **Double Ratchet encryption** - Full Signal-protocol-level forward secrecy
- **File sharing** - Send images/files via XFTP protocol (already in xftp-web)
- **Typing indicators** - Show when support team is typing
- **Bot integration** - Automated responses for common questions
- **Push notifications** - Browser notifications for new messages
- **Chat transcript export** - User can download their chat history
- **Multiple support agents** - Route to available team member
- **Upstream contribution** - Contribute WebSocket client back to SimpleX project

---

## Quick reference: Season overview

| Season | Focus | Key output | Depends on |
|:-------|:------|:-----------|:-----------|
| S1 | Planning and docs | Protocol, research, season plan, dual-profile design | - |
| S2 | WebSocket transport | `transport.ts` (ChatTransport), `client.ts` | S1 |
| S3 | SMP commands | `commands.ts`, unit tests | S2 |
| S4 | Connection flow | `connection.ts`, `agent.ts` | S3 |
| S5 | E2E encryption | `crypto/e2e.ts`, Web Worker, key storage | S4 |
| S6 | Chat UI (Intercom-level) | Animations, encryption badge, accessibility, SharedWorker | S4 (S5 in parallel) |
| S7 | Website integration | Full SimpleGo integration, mobile, SPA | S5 + S6 |
| S8 | Hardening | Production deployment, CSP, SRI, security review | S7 |
| S9 | GRP: Noise transport | `grp/transport.ts` (ChatTransport), Noise IK/XX | S8 + GoRelay Phase 4 |
| S10 | GRP: Post-quantum | ML-KEM-768 hybrid key exchange in browser | S9 + GoRelay Phase 4 |
| S11 | GRP: Two-hop routing | PFWD/RFWD/RRES/PRES, cover traffic, 5 encryption layers | S10 + GoRelay Phase 5 |
| S12+ | GRP: Triple Shield | ZKP, Shamir, steganographic transport | S11 + GoRelay Phase 6 |

**SMP critical path:** S1 -> S2 -> S3 -> S4 -> S7 -> S8  
**SMP parallel track:** S5 (encryption) and S6 (UI) can run alongside S4  
**GRP track:** S9 -> S10 -> S11 -> S12+ (begins after SMP profile is production-ready)  
**GRP dependency:** GoRelay must complete its corresponding phases first

---

## Changelog

| Date | Change |
|------|--------|
| 2026-03-25 | Season plan created by Prinzessin Mausi. Defined 8 seasons covering planning through production. |
| 2026-03-25 | Dual-profile update. Expanded Season 1 deliverables with dual-profile design, deep research, community contact, GPG signing. Added key decisions 3-11 (dual-profile, ChatTransport, @noble crypto, Intercom-level UI, no mobile app). Expanded Season 6 scope from minimal to Intercom-level with animations, encryption badge, accessibility, SharedWorker. Added Seasons 9-11 for GRP profile (Noise transport, ML-KEM-768 post-quantum, two-hop relay routing). Added Season 12+ for Triple Shield and future features. Updated quick reference with GRP dependency chain. Added ground rule. |
