<p align="center">
  <img src=".github/assets/gochat_banner.png" alt="GoChat" width="1500" height="230">
</p>

<h1 align="center">GoChat</h1>

<p align="center">
  <strong>Browser-native encrypted messenger for the SimpleX ecosystem.</strong><br>
  No app install. No registration. No user IDs. End-to-end encrypted from the first message.
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-AGPL--3.0-blue.svg" alt="License"></a>
  <a href="#status"><img src="https://img.shields.io/badge/version-0.0.1--alpha-orange.svg" alt="Version"></a>
  <a href="#upstream"><img src="https://img.shields.io/badge/upstream-simplexmq-lightgrey.svg" alt="Upstream"></a>
  <a href="https://github.com/saschadaemgen/SimpleGo"><img src="https://img.shields.io/badge/parent-SimpleGo-green.svg" alt="SimpleGo"></a>
  <a href="docs/PROTOCOL.md"><img src="https://img.shields.io/badge/docs-protocol-blue.svg" alt="Protocol"></a>
</p>

---

GoChat is a browser-native encrypted messenger built on top of [SimpleXMQ](https://github.com/simplex-chat/simplexmq) by [SimpleX Chat](https://simplex.chat/). It brings the SimpleX Messaging Protocol directly into the browser, allowing website visitors to communicate through end-to-end encrypted channels without installing any application.

GoChat is part of the [SimpleGo ecosystem](#simplego-ecosystem) and extends the SimpleX network with an additional high-security communication layer for environments that demand post-quantum cryptography, zero-knowledge relay infrastructure, and dedicated hardware endpoints. This is not a replacement of the SimpleX protocol - it is a complementary extension that builds on top of it and remains fully compatible with all SimpleX clients and infrastructure.

No dedicated mobile application is planned or needed. The SimpleX Chat apps for Android, iOS, and desktop already provide excellent clients for the SMP protocol. GoChat focuses exclusively on bringing encrypted messaging into the browser - the one platform SimpleX does not yet cover natively.

Based on the `ep/smp-web-spike` branch by [@epoberezkin](https://github.com/epoberezkin) (SimpleX founder), which introduces browser-native SMP protocol support via WebSocket.

---

## Two communication profiles

GoChat supports two communication profiles, selectable per connection. Both profiles use the same chat interface - the difference is in the transport layer, encryption strength, and relay infrastructure.

### SMP Profile - everyday encrypted communication

The standard profile for daily use. Speaks the SimpleX Messaging Protocol over WebSocket, fully compatible with all SimpleX clients and any SMP relay server - including SimpleX's own public infrastructure, self-hosted servers, or [GoRelay](https://github.com/saschadaemgen/GoRelay).

This is the profile for the broad range of everyday communication needs:

- **Product support** - customers chat with support teams directly from the website
- **Online shops** - shop operators manage customer inquiries, order questions, and returns through encrypted channels. Combined with a [SimpleGo hardware terminal](#simplego-ecosystem), shop staff can handle messages from a dedicated countertop device
- **Communities and projects** - open-source projects, local groups, or hobby communities offer a private contact channel on their website
- **Families and personal use** - a private chat widget on a family website or personal blog, reachable without accounts or phone numbers
- **Small businesses** - freelancers, agencies, and consultancies provide clients with a secure way to discuss projects and share sensitive documents
- **Education** - schools, tutors, and training providers offer private communication channels for students and parents

On the receiving end, the support team or operator has three options:

- **SimpleX Chat app** on phone or desktop - no special software beyond the standard SimpleX client
- **GoChat Admin Panel** in the browser - a multi-conversation dashboard where support agents manage all customer chats from any browser, with the same E2E encryption as the customer side. No app install needed on either end.
- **SimpleGo hardware terminal** - a dedicated countertop device for shops and offices

```
Website visitor (browser)          Any SMP Server           Receiving end
        |                               |                        |
        |--- WSS + SMP --------------->|                        |  SimpleX App (phone/desktop)
        |    E2E encrypted             |--- SMP relay --------->|  GoChat Admin Panel (browser)
        |                               |                        |  or SimpleGo terminal
        |<-- WSS + SMP ----------------|<-- SMP relay ----------|
        |    E2E encrypted             |                        |
```

The Admin Panel option means the entire communication chain - customer to support - runs in the browser with E2E encryption. No app installs on either side. This is unique among support chat tools: Chatwoot, Crisp, and Intercom all have unencrypted admin interfaces.

### GRP Profile - high-security environments

An additional security layer for environments where standard encryption is not sufficient. Uses the GoRelay Protocol (GRP) over WebSocket, exclusively through [GoRelay](https://github.com/saschadaemgen/GoRelay) infrastructure. The GRP profile represents a significant security upgrade over standard SMP, adding multiple defense layers while maintaining interoperability with the SimpleX network through GoRelay's dual-protocol bridge.

This profile is designed for sensitive and high-security communication needs:

- **Journalism and source protection** - reporters and sources communicate without metadata traces, even if relay servers are seized
- **Whistleblower channels** - organizations provide anonymous, quantum-resistant reporting channels on their website
- **Government and public authorities** - secure citizen communication channels that meet elevated data protection requirements
- **Healthcare and medical data** - patient communication and sensor data transmission compliant with strict medical data regulations
- **Critical infrastructure** - energy, water treatment, and industrial control systems communicate through channels resistant to state-level adversaries
- **Legal and financial services** - attorney-client and financial advisor communication with the strongest available encryption guarantees
- **Defense and security organizations** - secure field communication where post-quantum protection and zero-knowledge infrastructure are operational requirements
- **NGOs and human rights** - organizations operating in hostile environments where communication security is a matter of personal safety

On the receiving end, a [SimpleGo hardware device](#simplego-ecosystem) provides a dedicated endpoint with no smartphone OS, no baseband processor, and hardware-backed key storage.

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

---

## What makes GRP different from SMP

The GRP profile is not simply "SMP but stronger." It is a fundamentally different transport architecture designed from the ground up for environments where the adversary has significant resources - intelligence agencies, state-sponsored attackers, or well-funded criminal organizations.

### Noise Protocol instead of TLS

Where SMP uses TLS 1.3 for transport encryption, GRP uses the [Noise Protocol Framework](https://noiseprotocol.org/) - the same cryptographic framework that powers WireGuard, WhatsApp's client-server encryption, and Slack's Nebula overlay network.

| Property | SMP (TLS 1.3) | GRP (Noise IK) |
|:---------|:--------------|:---------------|
| Handshake size | 1-4 KB | 96-144 bytes |
| Cipher negotiation | Yes (dozens of options) | No (fixed suite, cannot downgrade) |
| Certificate authority | Required (X.509 chain) | Not needed (key IS identity) |
| Identity hiding | Server visible via SNI | Both parties encrypted |
| Deniability | No (signatures in handshake) | Yes (DH only, no signatures) |
| Specification | 160+ pages (TLS RFC + dependencies) | 35 pages (complete spec) |

The elimination of cipher negotiation is the most significant security improvement. TLS has spent two decades fighting downgrade attacks (POODLE, FREAK, Logjam, ROBOT) caused by its negotiation mechanism. Noise cannot have downgrade attacks because there is nothing to downgrade. One fixed cipher suite per protocol version: `Noise_IK_25519_ChaChaPoly_BLAKE2s`.

### Mandatory post-quantum cryptography

GRP mandates hybrid key exchange combining X25519 (classical) with ML-KEM-768 (post-quantum, FIPS 203). This is not optional and cannot be disabled. If a quantum computer capable of breaking Curve25519 is ever built, GRP messages remain secure because the ML-KEM-768 component protects independently.

SMP currently does not include post-quantum key exchange at the transport level (SimpleGo's client-side sntrup761 is a separate layer). GRP adds this as a mandatory transport requirement.

### Two-hop relay routing

Every GRP message passes through two relay servers. The first server sees the sender's IP address but not the destination. The second server sees the destination but not the sender. No single server in the chain knows both ends of the communication.

```
Sender --> Relay A (knows sender IP, not destination) --> Relay B (knows destination, not sender) --> Recipient
```

This provides equivalent protection to three-hop onion routing (Tor) with lower latency, while being significantly harder to defeat through traffic analysis than a single-relay model.

### Server-generated cover traffic

GoRelay generates Poisson-distributed dummy messages that are cryptographically indistinguishable from real messages. An observer monitoring server traffic cannot determine which 16 KB blocks contain real messages and which are cover traffic. This defeats traffic analysis attacks that correlate message timing between sender and recipient.

### Zero-knowledge relay

GoRelay stores and forwards encrypted blobs without the ability to read, modify, or correlate message content. This is not a policy choice - it is a structural property of the code. There is no administrator backdoor, no debug mode that reveals plaintext, no logging facility that captures content, because the code to do these things does not exist. Per-message AES-256-GCM encryption with cryptographic deletion on acknowledgment ensures that even forensic recovery of deleted data produces only ciphertext with a destroyed key.

### Future: Triple Shield architecture

GoRelay's roadmap includes a Triple Shield layer that adds three additional defense mechanisms on top of the existing encryption stack:

**Zero-Knowledge Queue Authentication** - clients prove queue ownership without revealing their public key to the server. The server learns exactly one bit: "this client has the right key" or not. Unlike standard signature verification, ZKP authentication prevents a compromised server from correlating queue access patterns by public key.

**Shamir's Secret Sharing** - each encrypted message is split into N shares distributed across multiple independent servers (default: 2-of-3). Any single share contains mathematically zero information about the original message. A server seizure by law enforcement, a hack, or a coerced operator gains nothing without simultaneously compromising a second server. This is not computational security - it is information-theoretic security that holds even against unlimited computing power.

**Steganographic Transport** - GRP traffic is wrapped in protocols that mimic legitimate web traffic (HTTPS browsing, WebSocket applications, CDN content). Deep packet inspection systems cannot distinguish GoRelay traffic from normal website activity. This uses the Pluggable Transport framework originally developed for Tor, with support for multiple disguise methods including domain fronting, WebSocket tunneling, and obfs4.

When all three components are active, defeating a GoChat-to-SimpleGo communication requires simultaneously:

1. Breaking end-to-end Double Ratchet encryption
2. Breaking per-queue NaCl cryptobox encryption
3. Breaking server-to-recipient NaCl encryption
4. Breaking Noise + ML-KEM-768 transport on multiple hops
5. Breaking per-message storage AES-256-GCM encryption
6. Identifying the traffic despite steganographic wrapping
7. Compromising at least 2 of 3 servers for Shamir reconstruction
8. Linking queue access to a user despite zero-knowledge authentication

All eight must succeed simultaneously. Failure at any single point leaves the attacker with nothing.

---

## Profile comparison

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

Both profiles can coexist on the same website. A visitor chooses the appropriate profile when starting a conversation, or the website operator configures which profile is available.

---

## Security model

GoChat is transparent about both its strengths and the inherent limitations of browser-based encryption.

**Strengths:**
- E2E encryption using audited libraries (@noble/curves - 6 security audits, used by Proton Mail and MetaMask)
- X25519/Ed25519 natively supported in all major browsers since 2025
- Crypto operations isolated in a dedicated Web Worker
- Strict Content Security Policy (no eval, no inline scripts)
- Subresource Integrity on all external scripts
- Minimal dependencies to reduce supply chain attack surface

**Honest limitations:**
- The server delivers the code - unlike native apps, a compromised web server could serve modified code. We mitigate with reproducible builds and SRI hashes.
- XSS is the existential threat to browser E2E encryption. The Matrix "Nebuchadnezzar" vulnerabilities (2022) demonstrated this attack class in practice.
- SMP's self-signed certificate model doesn't work in browsers. We use standard CA certificates for TLS while SMP's own DH encryption layer provides security independent of the CA chain.

For the highest security requirements, the GRP profile combined with a SimpleGo hardware endpoint eliminates the browser trust boundary entirely on the receiving side - the hardware device runs auditable firmware with no server-delivered code, no smartphone OS, and hardware-backed key storage with optional eFuse protection.

Full security analysis: [docs/RESEARCH.md](docs/RESEARCH.md)

---

## Architecture

```
+---------------------------------------------------------------+
|                      BROWSER CLIENT                           |
|    Chat UI  /  Message Store  /  Encrypted Key Storage        |
+---------------------------------------------------------------+
|                      WEB WORKER                               |
|    Crypto Operations (isolated from main thread XSS)          |
+---------------------------------------------------------------+
|                      SHARED WORKER                            |
|    WebSocket Pool  /  Reconnection  /  Message Queue          |
+---------------------------------------------------------------+
|                    TRANSPORT LAYER                             |
|    SMP Profile: SMP over WSS     GRP Profile: GRP over WSS   |
|    (@noble/curves, NaCl)         (Noise, ML-KEM-768)          |
+-------------------------------+-------------------------------+
|        ANY SMP SERVER         |         GORELAY SERVER        |
|    Queue Management           |    Queue Management           |
|    WSS + TLS on port 443      |    Noise + PQ on port 7443    |
|                               |    Two-hop routing            |
|                               |    Cover traffic              |
|                               |    Zero-knowledge storage     |
|                               |    Cryptographic deletion     |
+-------------------------------+-------------------------------+
|       SIMPLEX APP             |       SIMPLEGO HARDWARE       |
|    Phone / Desktop            |    ESP32-S3 / Custom PCB      |
|    Standard E2E               |    4-layer encryption         |
|                               |    Post-quantum (sntrup761)   |
|                               |    Hardware key storage       |
+-------------------------------+-------------------------------+
```

### Multi-user support

Each website visitor connects via a permanent contact address and receives their own isolated queue pair. The operator sees each visitor as a separate contact. Multiple concurrent conversations are handled natively by the relay server - no additional infrastructure needed.

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
| WebSocket transport client | WS-1 to WS-4 | Browser-side WebSocket client + SharedWorker pool |
| SMP commands | CMD-1 to CMD-5 | NEW, SUB, SEND, MSG, ACK, KEY, DEL |
| Connection flow | CONN-1 to CONN-4 | Contact address parsing, queue pair setup, state machine |
| E2E encryption | E2E-1 to E2E-3 | NaCl box MVP via @noble/ciphers, key storage, later Double Ratchet |
| Security hardening | SEC-1 to SEC-5 | CSP, SRI, Web Worker isolation, TLS strategy |
| Chat UI (customer) | UI-1 to UI-8 | Intercom-level panel, animations, encryption badge, accessibility |
| Admin Panel (support) | ADM-1 to ADM-4 | Multi-conversation dashboard, agent management, E2E encrypted admin interface |
| GRP transport | GRP-1 to GRP-4 | Noise protocol, ML-KEM-768, two-hop routing (future) |
| Deployment | OPS-1 to OPS-3 | SMP server, TLS, contact address, monitoring |

Full task breakdown: [docs/PROTOCOL.md](docs/PROTOCOL.md)

---

## Season-based development

We develop in seasons - each with a clear goal, defined scope, and a protocol document recording successes, failures, and learnings. Code is written by Claude Code, directed and reviewed by Sascha, planned by Prinzessin Mausi.

| Season | Focus | Status |
|:-------|:------|:-------|
| **S1** | Planning, documentation, and research | Complete |
| **S2** | WebSocket transport client (SMP) | Current |
| **S3** | SMP commands | Planned |
| **S4** | Connection flow (browser to SimpleX app) | Planned |
| **S5** | End-to-end encryption (@noble/curves) | Planned |
| **S6** | Chat UI (Intercom-level design) | Planned |
| **S7** | SimpleGo website integration | Planned |
| **S7.5** | Admin Panel (browser-based support dashboard) | Planned |
| **S8** | Production hardening + security review | Planned |
| **S9+** | GRP profile, Noise transport, post-quantum, Triple Shield | Future |

**Critical path:** S1 - S2 - S3 - S4 - S7 - S8  
**Parallel track:** S5 (encryption) and S6 (UI) can run alongside S4  
**GRP track:** Begins after SMP profile is production-ready

Full season plan: [docs/seasons/SEASON-PLAN.md](docs/seasons/SEASON-PLAN.md)

---

## Repository structure

```
GoChat/
+-- .github/assets/                 # Banner and images
+-- .claude/                        # Claude Code project instructions
+-- smp-web/                        # SMP browser client (spike + our work)
|   +-- src/
|       +-- index.ts                # Re-exports encoding primitives
|       +-- protocol.ts             # SMP transmission encode/decode, LGET/LNK
|       +-- types.ts                # ChatTransport interface, SMP types
|       +-- transport.ts            # SMPWebSocketTransport (16KB block framing)
+-- xftp-web/                       # Shared infrastructure (upstream)
|   +-- src/
|       +-- client.ts               # HTTP/2 transport, handshake, retry
|       +-- protocol/               # Encoding, transmission, handshake
|       +-- crypto/                 # X25519, NaCl, SHA-256, identity
+-- protocol/                       # SMP protocol specification (upstream reference)
+-- docs/
|   +-- PROTOCOL.md                 # Main technical protocol document
|   +-- RESEARCH.md                 # Browser crypto, security, and design research
|   +-- seasons/
|       +-- SEASON-PLAN.md          # Season overview and workflow
|       +-- SEASON-01-planning.md   # Season 1 learnings
+-- LICENSE                         # AGPL-3.0
+-- README.md
```

---

## Getting started

**Clone and switch to the working branch:**

```powershell
git clone https://github.com/saschadaemgen/GoChat.git
cd GoChat
git checkout feat/simplego-support-chat
```

**Explore the spike:**

```powershell
cat smp-web/src/protocol.ts         # SMP protocol in TypeScript
cat smp-web/src/index.ts            # Shared encoding primitives
cat xftp-web/src/client.ts          # Transport reference implementation
```

---

## SimpleGo ecosystem

GoChat is one component of a larger ecosystem for encrypted communication across platforms - from dedicated microcontroller hardware to relay servers to the browser.

| Project | What it does | Language | Repository |
|:--------|:-------------|:---------|:-----------|
| **[SimpleGo](https://github.com/saschadaemgen/SimpleGo)** | First native C implementation of SimpleX protocol on ESP32-S3 hardware. Autonomous encrypted messaging device with 4-layer encryption, Double Ratchet, and post-quantum key exchange (sntrup761). | C | [SimpleGo](https://github.com/saschadaemgen/SimpleGo) |
| **GoRelay** | Dual-protocol relay server. SMP on port 5223 for SimpleX compatibility, GRP on port 7443 with Noise transport, mandatory post-quantum crypto (ML-KEM-768), two-hop routing, cover traffic, and zero-knowledge storage with cryptographic deletion. | Go | GoRelay |
| **GoChat** | Browser-native encrypted messenger. SMP profile for everyday use, GRP profile for high-security. Customer chat widget and admin support dashboard, both E2E encrypted. No app install needed. (This project) | TypeScript | [GoChat](https://github.com/saschadaemgen/GoChat) |

### How the ecosystem connects

The three projects cover the complete communication chain from silicon to browser:

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

**SMP path (top):** Standard SimpleX-compatible communication. Any SMP server works as relay. On the receiving end: SimpleX Chat app on phone or desktop, GoChat Admin Panel in the browser, or a SimpleGo terminal in a shop, office, or home. This is the path for everyday use - customer support, community engagement, family communication, business inquiries.

**GRP path (bottom):** High-security communication with post-quantum protection, Noise transport, and two-hop routing. GoRelay is the exclusive relay. On the receiving end: SimpleGo hardware with no smartphone OS, no baseband processor, and hardware-backed key storage. This path is for environments where the threat model includes well-resourced adversaries.

**GoRelay as bridge:** GoRelay's dual-protocol architecture allows cross-protocol message delivery. A message arriving via SMP can be delivered to a GRP subscriber, and vice versa. This means a visitor using the SMP profile in their browser can reach a SimpleGo hardware device behind GRP - GoRelay handles the translation transparently.

### What SimpleX provides - and what we extend

SimpleX Chat provides excellent mobile and desktop applications for Android, iOS, macOS, Windows, and Linux. The SimpleX protocol and its ecosystem of clients and servers form a robust foundation for private communication. GoChat does not replace any of this. Instead, it fills the one gap that remains: the browser.

The GRP profile, available through GoRelay, is an extension of the SimpleX network - not a replacement. It adds a post-quantum, zero-knowledge communication layer on top of the existing infrastructure for environments where standard SMP encryption - while strong - does not meet the elevated requirements of certain sectors. Both layers coexist, interoperate through GoRelay, and share the fundamental SimpleX design principle: no user identifiers of any kind.

There is no plan to develop dedicated mobile applications. SimpleX already covers mobile and desktop platforms with proven, audited software. The SimpleGo ecosystem contributes where SimpleX does not: dedicated hardware endpoints, a Go-based relay server with dual-protocol support, and now a browser-native client. Each project strengthens the overall network without duplicating what already works.

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

Season 1 (planning, documentation, and research) is complete. Season 2 (WebSocket transport) is in progress.

| Component | Status |
|:----------|:-------|
| Technical protocol document | Done |
| Repository fork and branch setup | Done |
| Season plan and workflow | Done |
| Deep research (security, design, crypto) | Done |
| Dual-profile architecture design | Done |
| WebSocket transport client | Season 2 (in progress) |
| SMP command implementation | Season 3 |
| Browser-to-app connection | Season 4 |
| End-to-end encryption | Season 5 |
| Chat UI (Intercom-level) | Season 6 |
| Website integration | Season 7 |
| Admin Panel (support dashboard) | Season 7.5 |
| Production deployment + security review | Season 8 |
| GRP profile + post-quantum + Noise | Season 9+ |

---

## Documentation

| Resource | Link |
|:---------|:-----|
| Technical protocol | [docs/PROTOCOL.md](docs/PROTOCOL.md) |
| Research findings | [docs/RESEARCH.md](docs/RESEARCH.md) |
| Season plan | [docs/seasons/SEASON-PLAN.md](docs/seasons/SEASON-PLAN.md) |
| SimpleGo main project | [github.com/saschadaemgen/SimpleGo](https://github.com/saschadaemgen/SimpleGo) |
| SimpleGo documentation | [wiki.simplego.dev](https://wiki.simplego.dev) |
| GoRelay documentation | [wiki.gorelay.dev](https://wiki.gorelay.dev) |
| SimpleX Chat | [simplex.chat](https://simplex.chat/) |
| SimpleX protocol specification | [SMP protocol](https://github.com/simplex-chat/simplexmq/blob/stable/protocol/simplex-messaging.md) |

---

## Commit convention

All commits follow [Conventional Commits](https://www.conventionalcommits.org/) format:

```
type(scope): description
```

| Type | Usage |
|:-----|:------|
| `feat` | New feature or functionality |
| `fix` | Bug fix |
| `docs` | Documentation changes |
| `chore` | Maintenance, cleanup, dependencies |
| `refactor` | Code restructuring without behavior change |
| `test` | Adding or updating tests |

Commits are made as granular as possible - each with its own descriptive title and professional commit message. Multiple files share a commit only when they are logically inseparable. Each season's protocol document lists all commits with hashes and descriptions.

---

## License

| Component | License |
|:----------|:--------|
| GoChat (this repository) | [AGPL-3.0](LICENSE) |
| Upstream SimpleXMQ | [AGPL-3.0](https://github.com/simplex-chat/simplexmq/blob/stable/LICENSE) |
| SimpleGo parent project | [AGPL-3.0](https://github.com/saschadaemgen/SimpleGo/blob/main/LICENSE) |

This project is a derivative work of SimpleXMQ by SimpleX Chat Ltd, licensed under AGPL-3.0. All modifications and additions are released under the same license. Source code for all server-side components is available in this repository as required by AGPL-3.0.

## Acknowledgments

[SimpleX Chat](https://simplex.chat/) (SimpleX Messaging Protocol and simplexmq reference implementation) - [Evgeny Poberezkin](https://github.com/epoberezkin) (smp-web spike and WebSocket server support) - [@noble/hashes](https://github.com/paulmillr/noble-hashes) (SHA-256, SHA-512) - [@noble/curves](https://github.com/paulmillr/noble-curves) (Ed25519, X25519) - [@noble/ciphers](https://github.com/paulmillr/noble-ciphers) (XSalsa20-Poly1305, AES-256-GCM)

---

<p align="center">
  <i>GoChat is a sub-project of <a href="https://github.com/saschadaemgen/SimpleGo">SimpleGo</a> by IT and More Systems, Recklinghausen, Germany.</i><br>
  <i>Built on top of <a href="https://github.com/simplex-chat/simplexmq">SimpleXMQ</a> (AGPL-3.0) by <a href="https://simplex.chat/">SimpleX Chat</a>.</i><br>
  <i>Not affiliated with or endorsed by SimpleX Chat Ltd.</i>
</p>

<p align="center">
  <strong>GoChat - Encrypted messaging in the browser. No app, no account, no compromises.</strong>
</p>
