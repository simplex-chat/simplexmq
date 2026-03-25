<p align="center">
  <img src="../../.github/assets/gochat_banner.png" alt="GoChat" width="1500" height="230">
</p>

<h1 align="center">GoChat - Season 1 Protocol</h1>

<p align="center">
  <strong>Season 1: Planning and Documentation</strong><br>
  Complete record of decisions, discoveries, commits, and lessons learned.
</p>

---

**Season:** 1  
**Duration:** 2026-03-25 (full day session)  
**Status:** Complete  
**Goal:** Project analysis, fork setup, dual-profile architecture design, deep research, community contact, documentation, and Season 2 preparation.

---

## 1. What happened

Season 1 was a full-day planning session that transformed GoChat from an idea ("encrypted support chat for the SimpleGo website") into a fully documented project with a dual-profile architecture, 33 registered implementation tasks across 12 planned seasons, and a clear technical foundation built on the SimpleX smp-web spike.

The session progressed through several distinct phases:

**Phase 1 - Discovery:** Sascha found the smp-web spike branch and PR #1738. Initial analysis revealed that SimpleX founder Evgeny Poberezkin was actively building browser-native SMP support. This discovery eliminated the originally planned CLI bridge architecture.

**Phase 2 - Analysis:** Deep technical analysis of the smp-web spike (commits 4b89a7f, 3eeffff, 01fe841), the xftp-web shared infrastructure, and the SMP protocol. Every existing TypeScript module was cataloged. The complete code map was documented.

**Phase 3 - Repository setup:** Fork created (initially as simplexmq-web-experiment, later renamed to GoChat). Haskell server code removed. 80+ upstream branches cleaned. GPG signing configured. Banner created.

**Phase 4 - Documentation (first pass):** PROTOCOL.md written with 6-layer task structure (WS, CMD, CONN, E2E, UI, OPS). README replaced with project documentation. SEASON-PLAN.md created with 8-season roadmap.

**Phase 5 - Community contact:** Message posted in SimpleX community about GoChat plans. Evgeny Poberezkin responded "its WIP :)" confirming smp-web is under active development. A community member gave "10 of 10 Points" for the architecture diagram.

**Phase 6 - Deep research:** Comprehensive research conducted on browser cryptography maturity (Web Crypto API, @noble/curves), security analysis (XSS as existential threat, trust boundaries), design patterns (Intercom-level specifications), WebSocket architecture (SharedWorker, reconnection), and competitive landscape.

**Phase 7 - Architecture breakthrough:** The dual-profile architecture was designed - the single most important decision in Season 1. GoChat would support two communication profiles: SMP for everyday use (compatible with all SimpleX clients) and GRP for high-security environments (Noise transport, ML-KEM-768 post-quantum, two-hop relay routing via GoRelay). The ChatTransport interface was defined as a day-one abstraction requirement.

**Phase 8 - Documentation (second pass):** All three core documents updated with dual-profile context. PROTOCOL.md expanded with GRP tasks (GRP-1 to GRP-4), security tasks (SEC-1 to SEC-5), expanded UI tasks (UI-6 to UI-8), WS-4 (SharedWorker), browser-specific risk assessment, ecosystem context, and task registry. RESEARCH.md updated with dual-profile analysis throughout. SEASON-PLAN.md expanded with GRP seasons (9-11+).

**Phase 9 - Claude Code preparation:** CLAUDE.md created with project instructions and permissions. settings.local.json configured.

---

## 2. Commits (in order)

| Hash | Message | Description |
|:-----|:--------|:------------|
| `afd807b1` | `chore(repo): remove upstream Haskell server code and restructure for GoChat` | Removed apps/, src/, tests/, rfcs/, scripts/, design/, cbits/. Cleaned 80+ upstream branches. |
| `0194d459` | `chore(assets): add GoChat project banner` | Created .github/assets/gochat_banner.png |
| `93974c09` | `docs(readme): add GoChat project README` | Initial README with project description and protocol link |
| `3289b2d7` | `docs(protocol): add technical protocol for smp-web integration` | First version of PROTOCOL.md with spike analysis and 6-layer task structure |
| `e08615cb` | `docs(seasons): add 8-season development roadmap` | Initial SEASON-PLAN.md with Seasons 1-8 |
| (pending) | `chore(github): remove upstream CI workflows and config files` | CI cleanup |
| (pending) | `chore(config): replace Haskell gitignore with TypeScript/Web config` | .gitignore for TypeScript project |
| (pending) | `chore(docs): remove incorrectly placed legacy planning files` | File cleanup |
| (pending) | `docs(readme): add dual-profile architecture and ecosystem integration` | Complete README rewrite with SMP/GRP profiles, ecosystem diagram, security model |
| (pending) | `chore(claude): add Claude Code project instructions and permissions` | .claude/CLAUDE.md and settings.local.json |
| (pending) | `docs(protocol): add dual-profile architecture and expanded task registry` | Major PROTOCOL.md update: dual-profile, GRP/SEC/UI tasks, risk assessment, task registry |
| (pending) | `docs(research): add dual-profile context and GRP security analysis` | RESEARCH.md update: dual-profile throughout, PQ browser crypto, competitive analysis |
| (pending) | `docs(seasons): expand season plan with GRP roadmap and dual-profile updates` | Season 9-11+, expanded S1 deliverables, Intercom-level S6, key decisions |
| (pending) | `docs(seasons): add Season 1 closing protocol` | This file |

---

## 3. Key discoveries

### 3.1 The smp-web spike exists and is active

The most important discovery of Season 1. Evgeny Poberezkin created the `ep/smp-web-spike` branch on 2026-03-22 with browser-native SMP protocol support. This means:

- SimpleX is officially building what we need
- The xftp-web infrastructure (encoding, crypto, handshake) is production-tested and reusable
- PR #1738 (WebSocket on SMP server port, merged 2026-03-20) provides the transport layer
- We can build on top of the spike instead of starting from scratch
- The CLI bridge architecture we originally planned is unnecessary

### 3.2 No browser-native SMP client exists anywhere

Confirmed through research: GitHub Issue #747 (open since June 2022, no official response), npm packages only wrap Haskell or control CLI. GoChat would be the first browser-native SMP client ever built.

### 3.3 No open-source support chat offers E2E encryption

Chatwoot, Rocket.Chat, Crisp, Intercom, tawk.to, Papercups - none of them encrypt the customer-facing widget. GoChat would be the first.

### 3.4 Browser crypto is mature enough

X25519 and Ed25519 natively available in all major browsers since 2025. @noble/curves has 6 security audits and is used by Proton Mail and MetaMask. The crypto foundation is solid.

### 3.5 XSS is the existential threat

The Matrix "Nebuchadnezzar" vulnerabilities (2022) proved that XSS defeats all encryption in the browser. The September 2025 npm supply chain attack (chalk, debug, ansi-styles - 1B+ weekly downloads) reinforces the need for minimal dependencies. This shaped the @noble-only crypto policy and SEC-1 to SEC-5 task definitions.

### 3.6 SMP self-signed certs don't work in browsers

SMP servers use self-signed certificate chains with fingerprints in the server address. Browsers reject WSS connections to untrusted certificates. Solution: Let's Encrypt for TLS, SMP fingerprint verification at the application layer. This became SEC-5.

---

## 4. Key decisions

| # | Decision | Rationale |
|:--|:---------|:----------|
| 1 | Direct browser-to-SMP via WebSocket, no CLI bridge | smp-web spike + PR #1738 make the bridge unnecessary |
| 2 | Build on ep/smp-web-spike, reuse xftp-web infrastructure | Production-tested encoding, crypto, handshake code already exists |
| 3 | Dual-profile architecture (SMP + GRP) | SMP for everyday use, GRP for high-security. Most important Season 1 decision. |
| 4 | ChatTransport interface from day one | Abstract transport ensures GRP can be added without touching application code |
| 5 | NaCl secretbox MVP via @noble/ciphers | Start simple, upgrade to Double Ratchet later |
| 6 | @noble-only crypto policy | 6 audits, minimal dependencies, covers both SMP and GRP needs |
| 7 | Multi-user via SimpleX contact address | Each visitor gets isolated queue pair, natively supported |
| 8 | Intercom-level UI, not "functional minimum" | Encryption badge as brand. Design specifications match Intercom quality. |
| 9 | No mobile app | SimpleX covers mobile/desktop. GoChat fills the browser gap only. |
| 10 | GoChat extends SimpleX, does not replace it | GRP is an additional security layer, not a competing protocol |
| 11 | SharedWorker for tab persistence | Maintains WebSocket connections across tab switches and SPA navigation |

---

## 5. Architecture established

### 5.1 Dual-profile system

```
SMP Profile (everyday):  Browser --WSS+SMP--> Any SMP Server --> SimpleX App / SimpleGo Terminal
GRP Profile (security):  Browser --WSS+GRP--> GoRelay Server --> SimpleGo Hardware (ESP32-S3)
```

### 5.2 ChatTransport abstraction

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

### 5.3 Browser architecture

```
Chat UI / Message Store / Encrypted Key Storage
    |
Web Worker (crypto operations, isolated from XSS)
    |
SharedWorker (WebSocket pool, reconnection, message queue)
    |
SMP Profile: WSS on port 443  |  GRP Profile: WSS on port 7443
```

### 5.4 GRP security stack (documented, not coded)

- Transport: Noise_IK_25519_ChaChaPoly_BLAKE2s
- Post-quantum: X25519 + ML-KEM-768 hybrid (FIPS 203)
- Routing: mandatory two-hop relay
- Cover traffic: Poisson-distributed dummy messages
- Future Triple Shield: ZKP (Schnorr DLOG), Shamir 2-of-3, Pluggable Transports

---

## 6. Task registry created

33 tasks registered across 8 categories:

| Category | Tasks | Season(s) |
|:---------|:------|:----------|
| WS (Transport) | WS-1, WS-2, WS-3, WS-4 | S2, S6 |
| CMD (Commands) | CMD-1 to CMD-5 | S3 |
| CONN (Connection) | CONN-1 to CONN-4 | S4 |
| E2E (Encryption) | E2E-1 to E2E-3 | S5 |
| UI (Interface) | UI-1 to UI-8 | S6, S7 |
| SEC (Security) | SEC-1 to SEC-5 | S2, S5, S8 |
| OPS (Deployment) | OPS-1 to OPS-3 | S8 |
| GRP (GoRelay Protocol) | GRP-1 to GRP-4 | S9, S10, S11+ |

---

## 7. Documents produced

| Document | Location | Lines | Description |
|:---------|:---------|:------|:------------|
| README.md | Root | ~450 | Complete project README with dual-profile architecture, ecosystem, security model |
| PROTOCOL.md | docs/ | ~850 | Technical protocol with spike analysis, task registry, risk assessment |
| RESEARCH.md | docs/ | ~370 | Browser crypto, security, design, competitive analysis |
| SEASON-PLAN.md | docs/seasons/ | ~560 | 12-season roadmap (8 SMP + 4 GRP) |
| CLAUDE.md | .claude/ | ~180 | Claude Code project instructions |
| settings.local.json | .claude/ | ~10 | Claude Code permissions |
| SEASON-01-planning.md | docs/seasons/ | This file | Season 1 closing protocol |

---

## 8. Community interaction

### 8.1 Post in SimpleX community

A message was posted in the SimpleX community chat describing GoChat's plans: browser-native SMP client for encrypted support chat, building on the smp-web spike, with a clear list of what needs to be added (WebSocket transport, missing SMP commands, connection flow, E2E encryption, chat UI).

### 8.2 Evgeny Poberezkin response

SimpleX founder responded with "its WIP :)" - confirming that smp-web development is ongoing. This validates the architectural decision to build on the spike rather than creating an independent implementation.

### 8.3 Community feedback

A community member gave "10 of 10 Points" for the GoChat architecture diagram. Positive reception indicates the project fills a recognized gap in the SimpleX ecosystem.

### 8.4 Follow-up message drafted

A follow-up message about deep research findings, browser crypto maturity, and the dual-profile approach was drafted but not yet sent. To be reviewed and sent at the start of next session.

---

## 9. What went well

1. **The smp-web discovery changed everything.** Finding the spike branch on the same day we started planning eliminated the need for a CLI bridge and gave us a production-tested foundation to build on.

2. **Dual-profile architecture emerged naturally.** The combination of GoRelay's GRP protocol with the SMP spike created a unique opportunity that no one else in the browser messenger space has.

3. **Documentation-first approach paid off.** Writing the protocol, research, and season plan before any code forced clarity on architecture decisions. Anyone reading the repo understands exactly what we're building and why.

4. **Community contact was valuable.** Evgeny's "WIP" confirmation means we're not building on abandoned code. The community's positive reaction validates the concept.

5. **The @noble crypto decision simplifies everything.** One library family covers both SMP and GRP cryptographic needs, with 6 audits and production deployment by major companies.

---

## 10. What went wrong

1. **Initial fork name was wrong.** Started as "simplexmq-web-experiment" and had to be renamed to "GoChat". The renaming required updating all references across multiple documents. Lesson: decide the project name before creating the fork.

2. **Local Git email config caused unverified commits.** The initial commits used the noreply GitHub email instead of the GPG-signing email (sascha.daemgen@t-online.de). Had to fix the local config. Lesson: verify GPG signing works before the first commit.

3. **Documentation update cycle was underestimated.** The dual-profile architecture decision late in the session required updating PROTOCOL.md, RESEARCH.md, and SEASON-PLAN.md - all documents that had already been committed. This created a second pass through all documentation. Lesson: major architectural decisions should be made before writing detailed documentation.

4. **Chat session hit context limits.** The planning session was so extensive that the conversation had to be continued in a second chat. The handover protocol was necessary to preserve context. Lesson: for full-day sessions, plan for mid-session handovers.

---

## 11. Lessons learned

1. **Documentation is the product in a planning season.** Season 1 produced zero lines of executable code, but the documents it created define the entire project trajectory. A planning season's deliverables are decisions and documentation, not code.

2. **The ground rule matters.** "Nothing invented. What is missing gets asked." This rule prevents AI assistants from filling knowledge gaps with plausible-sounding fiction. It forces explicit acknowledgment of unknowns, which produces more honest and useful documentation.

3. **Conventional Commits work for documentation too.** Using `docs(protocol):` and `docs(research):` prefixes makes the commit history readable even for a season with no code changes.

4. **The dual-profile concept needs visual communication.** The SMP vs GRP distinction is abstract. The architecture diagrams in the README and PROTOCOL.md are essential for anyone to quickly understand what GoChat does differently.

5. **Browser-based E2E encryption has an honest ceiling.** XSS defeats everything. The security documentation (SEC-4) must be transparent about this. The GRP profile with hardware endpoints on the receiving side is the escape hatch from the browser trust boundary.

---

## 12. Open items carried to Season 2

1. **Community follow-up message** about deep research findings - ready, needs review and send
2. **Upstream contribution question** - should we contribute WebSocket transport back to SimpleX?
3. **Server choice for development** - self-hosted SMP server vs SimpleX public servers
4. **xftp-web dependency handling** - local link vs npm during development
5. **ML-KEM-768 browser strategy** - pure JS vs WASM vs hybrid (GRP, deferred to Season 9+)
6. **SharedWorker fallback** - behavior when SharedWorker is unavailable (some mobile browsers)

---

## 13. Season 2 briefing

### Goal

Browser can establish a WebSocket connection to an SMP server, complete the handshake, and send/receive raw SMP blocks. The transport class must implement the ChatTransport interface.

### Tasks

| ID | Description | Priority |
|:---|:------------|:---------|
| WS-1 | WebSocket transport class implementing ChatTransport | Highest |
| WS-2 | SMP client with handshake (adapt from xftp-web) | Highest |
| WS-3 | Connection pooling and auto-reconnect | High |
| SEC-5 | TLS certificate strategy (Let's Encrypt + SMP fingerprint at app layer) | High |

### Key files to study

- `xftp-web/src/client.ts` - reference transport implementation, study `connectXFTP()` carefully
- `xftp-web/src/protocol/handshake.ts` - handshake flow to adapt for SMP
- `xftp-web/src/protocol/transmission.ts` - block framing to reuse
- `smp-web/src/protocol.ts` - existing SMP protocol code from the spike

### Success criteria

- Browser opens WebSocket to SMP server on port 443
- Handshake completes successfully
- PING/PONG keepalive works
- Connection auto-reconnects after drop
- Can send a raw SMP block and receive a response
- Transport class implements ChatTransport interface

### Watch out for

- SMP handshake is TLS-level, not HTTP-level like XFTP
- WebSocket binary frames vs SMP block framing alignment
- Browser security: WSS required, no self-signed certs in production
- All transport code must go through ChatTransport abstraction from the first line

---

## 14. Technical reference (for Season 2)

### SMP block format

- 16,384 bytes fixed, '#' padding (0x23)
- Transmission: [auth][corrId][entityId][command]
- 1-byte length prefix for short strings, 2-byte for large

### xftp-web crypto stack (DO NOT MODIFY)

- @noble/hashes for SHA-256/SHA-512
- X25519 key generation and DH agreement
- NaCl secretbox (XSalsa20-Poly1305)
- Ed25519 server identity verification

### SMP version negotiation

- Current SMP versions: 6 and 7 (older discontinued)
- Server sends: min=6, max=7
- Client responds with its version range
- Agree on highest mutual version

### ChatTransport interface

```typescript
interface ChatTransport {
  connect(server: ServerAddress): Promise<void>
  send(block: Uint8Array): Promise<void>
  onMessage(handler: (block: Uint8Array) => void): void
  close(): void
}
```

---

*Season 1 protocol prepared by Prinzessin Mausi, 2026-03-25.*  
*Ground rule: Nothing invented. What is missing gets asked. The Prinzessin shows everything needed.*
