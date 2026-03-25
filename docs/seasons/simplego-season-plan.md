# SimpleGo SMP-Web Support Chat - Season Plan

**Project:** SimpleGo Website - Encrypted Support Chat via SimpleX  
**Workflow:** Season-based development with Claude Code  
**Planning by:** Prinzessin Mausi  
**Code by:** Claude Code  
**Direction by:** Sascha (saschadaemgen)  
**Repository:** `saschadaemgen/simplexmq-web-experiment`  
**Base branch:** `ep/smp-web-spike`

---

## How we work

Each season has a clear goal, a defined scope, and produces a protocol document at the end documenting all successes, failures, and learnings. Code is written by Claude Code, directed and reviewed by Sascha, planned by Prinzessin Mausi in the chat sessions.

Season protocol documents live in `docs/seasons/` and serve as a development diary - anyone can look at the source code and understand how and why we built things the way we did.

```
docs/
  PROTOCOL.md                    # Main technical protocol (already written)
  seasons/
    SEASON-01-planning.md        # Planning & documentation
    SEASON-02-transport.md       # WebSocket transport
    SEASON-03-commands.md        # SMP commands
    SEASON-04-connection.md      # Connection flow
    SEASON-05-encryption.md      # E2E encryption
    SEASON-06-ui.md              # Chat UI
    SEASON-07-integration.md     # SimpleGo integration
    SEASON-08-hardening.md       # Production hardening
```

---

## Season 1: Planning & documentation (CURRENT)

**Status:** In progress  
**Goal:** Complete project analysis, fork setup, roadmap, and workflow definition.

### Deliverables

- [x] Analyze `ep/smp-web-spike` branch - understand what exists
- [x] Analyze PR #1738 (WebSocket on SMP server port)
- [x] Analyze xftp-web shared infrastructure (crypto, encoding, transport)
- [x] Write main protocol document (`PROTOCOL.md`)
- [x] Fork repository (`simplexmq-web-experiment`)
- [x] Replace README with protocol document
- [x] Research SimpleX community discussion about smp-web
- [x] Post in SimpleX community about our plans
- [ ] Write this season plan document
- [ ] Create season 1 protocol (successes/failures/learnings)
- [ ] Set up branch structure: `feat/simplego-support-chat` from `ep/smp-web-spike`
- [ ] Prepare task list for Claude Code (season 2 briefing)

### Key decisions made

1. **Architecture:** Direct browser-to-SMP-server via WebSocket (no CLI bridge)
2. **Base:** Build on top of `ep/smp-web-spike`, reuse xftp-web infrastructure
3. **Encryption MVP:** Start with NaCl secretbox, upgrade to Double Ratchet later
4. **Multi-user:** Native via SimpleX contact address system
5. **UI pattern:** Nose-bar integration matching existing player panel

### Open questions for season 2

- Should we contribute WebSocket transport client upstream?
- Self-hosted SMP server or SimpleX public servers for development?
- How to handle the xftp-web dependency during development (local link vs npm)?

---

## Season 2: WebSocket transport client

**Goal:** Browser can establish a WebSocket connection to an SMP server, complete the handshake, and send/receive raw SMP blocks.

**This is the foundation - nothing else works without it.**

### Scope

- `smp-web/src/transport.ts` - WebSocket transport class
  - Connect to `wss://server:443` 
  - Binary message framing (SMP uses fixed 16KB blocks)
  - Connection lifecycle: open, close, error, reconnect
  - Heartbeat via PING/PONG
- `smp-web/src/client.ts` - SMP client with handshake
  - Adapt handshake for SMP protocol (different from XFTP)
  - Version negotiation
  - Session ID management
- Test against a real SMP server (SimpleX public or local Docker)

### Tasks for Claude Code

```
Task references: WS-1, WS-2, WS-3 from PROTOCOL.md
```

### Success criteria

- [ ] Browser opens WebSocket to SMP server on port 443
- [ ] Handshake completes successfully
- [ ] PING/PONG keepalive works
- [ ] Connection auto-reconnects after drop
- [ ] Can send a raw SMP block and receive a response

### What to watch out for

- SMP handshake is TLS-level, not HTTP-level like XFTP
- WebSocket binary frames vs SMP block framing alignment
- Browser security: WSS required, no self-signed certs in production
- The existing `xftp-web/src/client.ts` is the reference - study `connectXFTP()` carefully

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
  - MVP: NaCl secretbox with DH shared secret
  - Key derivation from X25519 agreement
  - Message padding (reuse xftp-web padding)
- `smp-web/src/crypto/keys-store.ts` - Browser key storage
  - IndexedDB for key material
  - Encryption at rest
  - Key cleanup on session end

### Tasks for Claude Code

```
Task references: E2E-1 (MVP), E2E-2, E2E-3 from PROTOCOL.md
```

### Success criteria

- [ ] Messages encrypted before sending, decrypted on receive
- [ ] Keys stored securely in browser IndexedDB
- [ ] Support team's SimpleX app can decrypt our messages
- [ ] We can decrypt messages from the support team
- [ ] Key material cleared on explicit session end

### Future upgrade (not this season)

- X3DH key agreement for proper forward secrecy
- Double Ratchet for ongoing forward secrecy
- This is a separate season if we decide to pursue it

---

## Season 6: Chat UI

**Goal:** Beautiful chat interface integrated into SimpleGo website.

### Scope

- `chat.css` - Chat panel styles matching SimpleGo design system
- `chat.js` - Chat UI logic
  - Nose-bar chat icon with unread badge
  - Dropdown panel (same pattern as player panel)
  - Message bubbles (outgoing right / incoming left)
  - Text input with send button
  - Connection status indicator
  - Auto-scroll behavior
- Message store in IndexedDB for chat history

### Tasks for Claude Code

```
Task references: UI-1, UI-2, UI-3 from PROTOCOL.md
```

### Success criteria

- [ ] Chat icon in nose-bar with unread count
- [ ] Panel opens/closes smoothly (matches player panel UX)
- [ ] Messages display correctly with timestamps
- [ ] Text input sends messages on Enter
- [ ] Chat history persists across page navigation
- [ ] Works alongside the music player without conflicts

---

## Season 7: SimpleGo website integration

**Goal:** Chat is fully integrated into the SimpleGo website, accessible from all pages.

### Scope

- Add chat button to homepage (replace/augment "Explore Product")
- Chat HTML structure in base template
- SPA router integration (chat survives page navigation)
- Mobile responsive layout
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

**Goal:** Battle-tested, deployable support chat system.

### Scope

- SMP server deployment on VPS (Docker)
- TLS certificate setup
- Contact address creation and configuration
- Error handling for all edge cases
- Offline/away state handling
- Reconnection after network interruption
- Performance optimization (bundle size, memory)
- Security review

### Tasks for Claude Code

```
Task references: OPS-1, OPS-2, OPS-3 from PROTOCOL.md
```

### Success criteria

- [ ] SMP server running on production VPS
- [ ] Chat works reliably for 8+ hours without issues
- [ ] Handles network interruptions gracefully
- [ ] Error states shown clearly to user
- [ ] Bundle size reasonable (< 100KB gzipped for chat module)
- [ ] No memory leaks in long-running sessions

---

## Season 9+ (Future ideas)

These are not planned yet but could become their own seasons:

- **Double Ratchet encryption** - Full Signal-protocol-level forward secrecy
- **File sharing** - Send images/files via XFTP protocol (already in xftp-web!)
- **Typing indicators** - Show when support team is typing
- **Bot integration** - Automated responses for common questions
- **Push notifications** - Browser notifications for new messages
- **Chat transcript export** - User can download their chat history
- **Multiple support agents** - Route to available team member
- **Upstream contribution** - Contribute WebSocket client back to SimpleX project

---

## Quick reference: Season overview

| Season | Focus | Key output | Depends on |
|--------|-------|------------|------------|
| S1 | Planning & docs | Protocol doc, fork, season plan | - |
| S2 | WebSocket transport | `transport.ts`, `client.ts` | S1 |
| S3 | SMP commands | `commands.ts`, unit tests | S2 |
| S4 | Connection flow | `connection.ts`, `agent.ts` | S3 |
| S5 | E2E encryption | `crypto/e2e.ts`, key storage | S4 |
| S6 | Chat UI | `chat.css`, `chat.js`, panel | S4 (S5 in parallel) |
| S7 | Website integration | Full SimpleGo integration | S5 + S6 |
| S8 | Hardening | Production deployment, testing | S7 |

**Critical path:** S1 -> S2 -> S3 -> S4 -> S7 -> S8  
**Parallel track:** S5 and S6 can run alongside S4 (crypto and UI don't block each other)

---

## Changelog

| Date | Change |
|------|--------|
| 2026-03-25 | Season plan created by Prinzessin Mausi. Defined 8 seasons covering planning through production. |
