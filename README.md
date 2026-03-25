<p align="center">
  <img src=".github/assets/smp-web-banner.png" alt="SimpleGo SMP-Web" width="1500" height="230">
</p>

<h1 align="center">SimpleGo SMP-Web Experiment</h1>

<p align="center">
  <strong>Browser-native encrypted support chat using the SimpleX Messaging Protocol.</strong><br>
  No app install. No registration. No user IDs. End-to-end encrypted from the first message.
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-AGPL--3.0-blue.svg" alt="License"></a>
  <a href="#status"><img src="https://img.shields.io/badge/version-0.1.0--experiment-orange.svg" alt="Version"></a>
  <a href="#upstream"><img src="https://img.shields.io/badge/upstream-simplexmq-lightgrey.svg" alt="Upstream"></a>
  <a href="https://github.com/saschadaemgen/SimpleGo"><img src="https://img.shields.io/badge/parent-SimpleGo-green.svg" alt="SimpleGo"></a>
  <a href="docs/PROTOCOL.md"><img src="https://img.shields.io/badge/docs-protocol-blue.svg" alt="Protocol"></a>
</p>

---

Experimental fork of [SimpleXMQ](https://github.com/simplex-chat/simplexmq) by [SimpleX Chat](https://simplex.chat/). Building a web-based encrypted support messenger for the [SimpleGo](https://github.com/saschadaemgen/SimpleGo) project website.

Based on the `ep/smp-web-spike` branch by [@epoberezkin](https://github.com/epoberezkin) (SimpleX founder), which introduces browser-native SMP protocol support via WebSocket.

This is a sub-project of [SimpleGo](https://github.com/saschadaemgen/SimpleGo) - the world's first native C implementation of the SimpleX Messaging Protocol for encrypted communication on dedicated hardware.

---

## What we're building

A support chat that lives directly on the SimpleGo website. Visitors open a chat panel in the browser and talk to our support team through the SimpleX protocol - the same protocol that powers SimpleGo's hardware encryption stack.

```
Website visitor (browser)           SMP Relay Server            Support team
        |                                 |                          |
        |--- WebSocket (wss://443) ------>|                          |
        |    E2E encrypted message        |--- SMP queue relay ----->|
        |                                 |                          |  (SimpleX App)
        |<-- WebSocket (wss://443) -------|<-- SMP queue relay ------|
        |    E2E encrypted reply          |                          |
```

The relay server sees only encrypted blobs in anonymous queues. No user IDs, no metadata, no way to link sender and receiver.

---

## Why this approach

| Traditional support chat | SimpleX web messenger |
|:-------------------------|:----------------------|
| User creates account | No account needed |
| Chat provider reads messages | End-to-end encrypted, nobody can read |
| Provider stores chat history | History only on user's device |
| Single provider dependency | Self-hosted relay, no lock-in |
| User tracked across sessions | No user identifiers of any kind |

We originally planned to use the SimpleX Chat CLI as a WebSocket server with a Node.js bridge in between. Then we discovered the `ep/smp-web-spike` branch where the SimpleX team is building browser-native SMP protocol support. This eliminates the middleware entirely - the browser talks directly to the SMP relay.

---

## Architecture

```
+---------------------------------------------------------------+
|                      BROWSER CLIENT                           |
|          Chat UI  /  Message Store  /  Key Storage            |
+---------------------------------------------------------------+
|                     SMP-WEB LIBRARY                           |
|    WebSocket Transport  /  SMP Commands  /  E2E Encryption    |
+---------------------------------------------------------------+
|                  SHARED INFRASTRUCTURE                        |
|   Binary Encoding  /  Crypto (X25519, NaCl)  /  Handshake    |
|              (from xftp-web, production tested)               |
+---------------------------------------------------------------+
|                      SMP RELAY SERVER                         |
|    Queue Management  /  WebSocket + TLS on port 443           |
+---------------------------------------------------------------+
|                      SIMPLEX APP                              |
|         Support team (Desktop / Mobile / SimpleGo HW)         |
+---------------------------------------------------------------+
```

### Multi-user support

Each website visitor connects via a permanent SimpleX contact address and receives their own isolated queue pair. The support team sees each visitor as a separate contact. 10, 50, or 100 concurrent conversations - the SMP server handles queue isolation natively.

---

## What exists vs. what we build

### Done (from upstream spike + xftp-web)

| Component | Source | Description |
|:----------|:-------|:------------|
| SMP server WebSocket support | PR #1738 | Browser WebSocket and native TLS on same port via SNI |
| Binary encoding/decoding | xftp-web | Full SMP wire format in TypeScript |
| Crypto stack | xftp-web | X25519 DH, NaCl secretbox, SHA-256, identity verification |
| HTTP/2 transport + handshake | xftp-web | Server connection with retry and reconnect |
| LGET/LNK commands | smp-web spike | Link retrieval for connection setup |
| Transmission framing | xftp-web | Block encoding/decoding with session auth |

### To do (our work)

| Component | Task IDs | Description |
|:----------|:---------|:------------|
| WebSocket transport client | WS-1, WS-2, WS-3 | Browser-side WebSocket client for SMP protocol |
| SMP commands | CMD-1 to CMD-5 | NEW, SUB, SEND, MSG, ACK, KEY, DEL |
| Connection flow | CONN-1 to CONN-4 | Contact address parsing, queue pair setup, state machine |
| E2E encryption | E2E-1 to E2E-3 | NaCl box MVP, key storage, later Double Ratchet upgrade |
| Chat UI | UI-1 to UI-5 | Nose-bar panel, message bubbles, mobile layout |
| Deployment | OPS-1 to OPS-3 | SMP server, TLS, contact address, monitoring |

Full task breakdown with technical details: [docs/PROTOCOL.md](docs/PROTOCOL.md)

---

## Season-based development

We develop in seasons - each with a clear goal, defined scope, and a protocol document recording successes, failures, and learnings.

| Season | Focus | Status |
|:-------|:------|:-------|
| **S1** | Planning and documentation | Current |
| **S2** | WebSocket transport client | Upcoming |
| **S3** | SMP commands | Planned |
| **S4** | Connection flow (browser to SimpleX app) | Planned |
| **S5** | End-to-end encryption | Planned |
| **S6** | Chat UI | Planned |
| **S7** | SimpleGo website integration | Planned |
| **S8** | Production hardening | Planned |

**Critical path:** S1 - S2 - S3 - S4 - S7 - S8  
**Parallel track:** S5 (encryption) and S6 (UI) can run alongside S4

Full season plan: [docs/seasons/SEASON-PLAN.md](docs/seasons/SEASON-PLAN.md)

---

## Repository structure

```
simplexmq-web-experiment/
+-- smp-web/                        # SMP browser client (spike + our work)
|   +-- src/
|       +-- index.ts                # Re-exports encoding primitives
|       +-- protocol.ts             # SMP transmission encode/decode, LGET/LNK
+-- xftp-web/                       # Shared infrastructure (upstream)
|   +-- src/
|       +-- client.ts               # HTTP/2 transport, handshake, retry
|       +-- protocol/               # Encoding, transmission, handshake
|       +-- crypto/                 # X25519, NaCl, SHA-256, identity
+-- docs/
|   +-- PROTOCOL.md                 # Main technical protocol document
|   +-- seasons/
|       +-- SEASON-PLAN.md          # Season overview and workflow
|       +-- SEASON-01-planning.md   # Season 1 protocol (this phase)
+-- src/Simplex/Messaging/          # Haskell SMP server (upstream reference)
```

---

## Getting started

**Clone and switch to the working branch:**

```powershell
git clone https://github.com/saschadaemgen/simplexmq-web-experiment.git
cd simplexmq-web-experiment
git checkout feat/simplego-support-chat
```

**Explore the spike:**

```powershell
cat smp-web/src/protocol.ts         # SMP protocol in TypeScript
cat smp-web/src/index.ts            # Shared encoding primitives
cat xftp-web/src/client.ts          # Transport reference implementation
```

---

## Upstream

This repository is a fork of [simplex-chat/simplexmq](https://github.com/simplex-chat/simplexmq) (AGPL-3.0).

| | |
|:--|:--|
| Upstream repository | [simplex-chat/simplexmq](https://github.com/simplex-chat/simplexmq) |
| Base branch | `ep/smp-web-spike` |
| Key upstream PR | [#1738 - WebSocket on SMP server port](https://github.com/simplex-chat/simplexmq/pull/1738) |
| Upstream license | AGPL-3.0 |
| SimpleX website | [simplex.chat](https://simplex.chat/) |

We intend to contribute our WebSocket transport client and SMP command implementations back to the upstream project.

---

## Status

Early experimental phase. Season 1 (planning and documentation) is in progress. No functional chat code yet - first working code expected in Season 2.

| Component | Status |
|:----------|:-------|
| Technical protocol document | Done |
| Repository fork and branch setup | Done |
| Season plan and workflow | Done |
| WebSocket transport client | Season 2 |
| SMP command implementation | Season 3 |
| Browser-to-app connection | Season 4 |
| End-to-end encryption | Season 5 |
| Chat UI | Season 6 |
| Website integration | Season 7 |
| Production deployment | Season 8 |

---

## Documentation

| Resource | Link |
|:---------|:-----|
| Technical protocol | [docs/PROTOCOL.md](docs/PROTOCOL.md) |
| Season plan | [docs/seasons/SEASON-PLAN.md](docs/seasons/SEASON-PLAN.md) |
| SimpleGo main project | [github.com/saschadaemgen/SimpleGo](https://github.com/saschadaemgen/SimpleGo) |
| SimpleGo documentation | [wiki.simplego.dev](https://wiki.simplego.dev) |
| SimpleX Chat | [simplex.chat](https://simplex.chat/) |
| SimpleX protocol specification | [SMP protocol](https://github.com/simplex-chat/simplexmq/blob/stable/protocol/simplex-messaging.md) |

---

## License

| Component | License |
|:----------|:--------|
| This repository (fork) | [AGPL-3.0](LICENSE) |
| Upstream SimpleXMQ | [AGPL-3.0](https://github.com/simplex-chat/simplexmq/blob/stable/LICENSE) |
| SimpleGo parent project | [AGPL-3.0](https://github.com/saschadaemgen/SimpleGo/blob/main/LICENSE) |

This project is a derivative work of SimpleXMQ by SimpleX Chat Ltd, licensed under AGPL-3.0. All modifications and additions are released under the same license. Source code for all server-side components is available in this repository as required by AGPL-3.0.

## Acknowledgments

[SimpleX Chat](https://simplex.chat/) (SimpleX Messaging Protocol and simplexmq reference implementation) - [Evgeny Poberezkin](https://github.com/epoberezkin) (smp-web spike and WebSocket server support) - [@noble/hashes](https://github.com/paulmillr/noble-hashes) (SHA-256, SHA-512 for browser crypto)

---

<p align="center">
  <i>SimpleGo SMP-Web Experiment is a sub-project of <a href="https://github.com/saschadaemgen/SimpleGo">SimpleGo</a> by IT and More Systems, Recklinghausen, Germany.</i><br>
  <i>Built on top of <a href="https://github.com/simplex-chat/simplexmq">SimpleXMQ</a> (AGPL-3.0) by <a href="https://simplex.chat/">SimpleX Chat</a>.</i><br>
  <i>Not affiliated with or endorsed by SimpleX Chat Ltd.</i>
</p>

<p align="center">
  <strong>Encrypted support chat - no app, no account, no compromises.</strong>
</p>
