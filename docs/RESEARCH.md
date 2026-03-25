<p align="center">
  <img src="../.github/assets/gochat_banner.png" alt="GoChat" width="1500" height="230">
</p>

<h1 align="center">GoChat - Research Findings</h1>

<p align="center">
  <strong>Deep research on browser-native encrypted messaging, design patterns, and security.</strong><br>
  Dual-profile architecture: SMP for everyday use, GRP for high-security environments.<br>
  Conducted during Season 1 planning phase, 2026-03-25.
</p>

---

## 1. Market position: GoChat would be a world first

No browser-native SMP client exists anywhere. Not from SimpleX Chat, not from the community, not from any third party. GitHub Issue #747 (open since June 2022) requests a web interface but has no official response.

The only TypeScript packages from SimpleX (`simplex-chat` on npm and `@simplex-chat/webrtc-client`) wrap the compiled Haskell native library or control the CLI via WebSocket. Neither implements the SMP protocol itself in JavaScript.

Additionally, no open-source support chat tool offers E2E encryption on the customer-facing widget side:

| Tool | GitHub Stars | Customer-facing E2E | Internal E2E |
|:-----|:------------|:-------------------|:-------------|
| Chatwoot | 27,700+ | No | No |
| Rocket.Chat | 41,000+ | No | Yes (RSA-OAEP + AES-GCM) |
| Crisp | Closed source | No | No |
| Intercom | Closed source | No | No |
| tawk.to | Closed source | No | No |
| Papercups | 5,700 (maintenance mode) | No | No |
| **GoChat** | **New** | **Yes** | **N/A** |

GoChat would be first on three counts: first browser-native SMP client, first E2E encrypted customer support widget, and the only browser messenger offering a dual-profile architecture where users can choose between standard SMP encryption for everyday use and a high-security GRP profile with post-quantum cryptography, Noise transport, and two-hop relay routing.

No existing tool - open source or commercial - offers anything comparable to the GRP profile in a browser context. Signal, Matrix, and Wire provide strong E2E encryption but none offer post-quantum transport, mandatory multi-hop routing, or cover traffic in their web clients.

---

## 2. Browser cryptography maturity

### 2.1 Native Web Crypto API support (2025+)

X25519 and Ed25519 are now natively available across all major browsers:

| Browser | X25519 | Ed25519 | Since |
|:--------|:-------|:--------|:------|
| Chrome | 133+ | 133+ | February 2025 |
| Firefox | 135+ | 135+ | 2025 |
| Safari | 17+ | 17+ | 2023-2025 |

This was a multi-year effort by Igalia funded by Protocol Labs.

For GoChat's SMP profile, this means the core key exchange primitives are natively available in all target browsers. The GRP profile requires additional algorithms (ChaCha20-Poly1305 for Noise, ML-KEM-768 for post-quantum) that are not yet in Web Crypto and must come from external libraries or WASM modules.

### 2.2 What Web Crypto still lacks

- XSalsa20-Poly1305 (needed for SMP NaCl crypto_box)
- XChaCha20-Poly1305
- ChaCha20-Poly1305 AEAD (needed for GRP Noise transport)
- ML-KEM-768 (needed for GRP post-quantum key exchange)
- BLAKE2s (needed for GRP Noise hash function)
- Argon2 (key derivation)
- sntrup761 (post-quantum KEM, used by SimpleGo hardware)

These require external JavaScript libraries. For the SMP profile, the @noble suite covers all needs. For the GRP profile, ML-KEM-768 is the biggest open question - no mature, audited JavaScript implementation exists yet. Options include a pure JS implementation (auditable but potentially vulnerable to side-channel attacks) or a WASM-compiled Rust/C library (better side-channel resistance but harder to audit in the browser context).

### 2.3 Recommended crypto library: @noble/curves

The noble cryptography suite by Paul Miller is the recommended choice for both profiles:

- **6 professional security audits** (Cure53 x4, Trail of Bits x1, Kudelski Security x1)
- Zero dependencies, PGP-signed releases, transparent npm builds
- ~5KB for Ed25519 (vs ~290KB for libsodium.js)
- Used in production by: Proton Mail, Tutanota, MetaMask, Phantom, ethers.js, Trezor Suite
- The xftp-web infrastructure in the smp-web spike already uses @noble/hashes

Relevant packages:
- `@noble/curves` - Ed25519, X25519 (both profiles)
- `@noble/ciphers` - XSalsa20-Poly1305 (SMP), ChaCha20-Poly1305 (GRP Noise), AES-256-GCM (key storage)
- `@noble/hashes` - SHA-256, SHA-512, HKDF, BLAKE2s (GRP Noise)

For the GRP profile specifically, @noble/ciphers provides ChaCha20-Poly1305 and @noble/hashes provides BLAKE2s - both required by the Noise cipher suite `Noise_IK_25519_ChaChaPoly_BLAKE2s`. This means a single library family covers the cryptographic needs of both communication profiles.

### 2.4 Industry trend: Rust to WASM

Every major encrypted messenger has converged on Rust crypto compiled to WASM:

- **Element Web** (Matrix): Migrated to matrix-sdk-crypto (Rust->WASM), 14x faster key sharing
- **Signal Desktop**: Uses libsignal (Rust->WASM)
- **Wire**: Uses core-crypto (Rust->WASM), encrypts IndexedDB with AES-256-GCM

For GoChat's SMP profile: Pure TypeScript with noble libraries is simpler to ship. For the GRP profile: a WASM-compiled ML-KEM-768 implementation may be necessary because post-quantum algorithms are computationally heavier and more sensitive to side-channel attacks than classical algorithms. This decision will be revisited when the GRP profile enters active development (Season 9+).

### 2.5 Post-quantum cryptography in the browser (GRP profile)

The GRP profile mandates hybrid X25519 + ML-KEM-768 key exchange. This creates a unique browser challenge because no standardized Web Crypto API for ML-KEM exists yet. Options for the GRP profile:

| Approach | Pros | Cons |
|:---------|:-----|:-----|
| Pure JS (@noble-style) | Auditable, no build tooling, consistent with SMP profile | Side-channel risk in JS, no FIPS validation |
| WASM (Rust compiled) | Better side-channel resistance, faster, FIPS-validated source | Harder to audit in-browser, larger bundle, build complexity |
| WebAssembly + JS hybrid | Best of both: WASM for ML-KEM, JS for classical crypto | Two crypto runtimes to maintain |

Go 1.24's stdlib includes FIPS-validated ML-KEM-768 - GoRelay uses this server-side. The browser needs an equivalent. This is an open research question tracked as GRP-2 in the protocol document.

---

## 3. Security analysis

### 3.1 The existential threat: XSS

A single XSS vulnerability defeats ALL encryption - both SMP and GRP profiles - by intercepting plaintext before encryption or after decryption. The 2022 Matrix "Nebuchadnezzar" vulnerabilities demonstrated this in practice - researchers found exploitable bugs allowing confidentiality breaks and impersonation.

This is the fundamental limitation of browser-based encryption that no amount of protocol-level security can fix. The GRP profile with its Noise transport, post-quantum crypto, and two-hop routing is still vulnerable to XSS at the browser endpoint. This is why GoChat's security documentation (SEC-4) must be transparent about the trust boundary.

For the highest security requirements, the GRP profile combined with a SimpleGo hardware endpoint eliminates the browser trust boundary entirely on the receiving side - the hardware device runs auditable firmware with no server-delivered code, no smartphone OS, and hardware-backed key storage with optional eFuse protection.

**Mitigations (both profiles):**
- Strict CSP: `script-src 'self'` - no eval, no inline scripts (SEC-1)
- Subresource Integrity (SRI) on all external scripts (SEC-2)
- Minimal dependencies to reduce supply chain attack surface
- All crypto operations in a dedicated Web Worker (SEC-3), isolated from main thread

The September 2025 npm supply chain attack compromised packages with 1 billion+ weekly downloads (chalk, debug, ansi-styles) - a stark reminder that dependency minimization is security-critical. GoChat's @noble-only crypto policy limits the attack surface to three well-audited packages.

### 3.2 The trust boundary: server-delivered code

Unlike native apps distributed through signed app stores, web applications reload from the server on every visit. A compromised or malicious server can serve different code to different users.

This trust boundary affects both profiles equally. Even GRP's Noise + ML-KEM-768 transport provides no protection if the browser code itself is compromised.

**GoChat must document this trust boundary honestly while mitigating with:**
- Reproducible builds
- SRI hashes
- Potentially browser extension-based code verification
- Transparent security documentation

**The dual-profile architecture provides a natural escape from this limitation:** for communications where the browser trust boundary is unacceptable, the GRP profile with a SimpleGo hardware endpoint on the receiving side ensures that at least one party is running verified, non-server-delivered code. The browser side remains the weaker link, but the hardware side is fully controlled.

### 3.3 TLS certificate challenge

SMP servers use self-signed certificate chains where the offline CA certificate hash is embedded in the server address (`smp://fingerprint@host`). Browsers reject WSS connections to servers with untrusted certificates.

**Solution:** GoChat's SMP servers must use standard CA-signed certificates (e.g., Let's Encrypt) for the TLS layer. SMP's own DH key exchange provides a second encryption envelope independent of the TLS CA chain. The SMP server fingerprint verification happens at the application layer, not the TLS layer.

For the GRP profile, this challenge does not apply in the same way. Noise Protocol uses the server's 32-byte Curve25519 public key as identity - no certificates, no CA chain, no expiry. The key IS the fingerprint. However, the initial WebSocket connection to the GoRelay server still needs a valid TLS certificate for the browser to accept the WSS upgrade. The Noise handshake then provides a second, independent encryption layer inside the WebSocket.

### 3.4 WebSocket-specific attacks

**Cross-Site WebSocket Hijacking (CSWSH):** Since WebSocket is not bound by Same-Origin Policy, a malicious page can open connections using the victim's cookies.

**Solution:** Use token-based authentication (not cookies) - pass tokens in the first WebSocket message after connection. This eliminates CSWSH entirely since there are no ambient credentials. This applies to both SMP and GRP profiles.

### 3.5 Browser key storage

Recommended layered approach (both profiles share the same key storage architecture):
- Store CryptoKey objects in IndexedDB with `extractable: false`
- Encrypt all sensitive data with AES-256-GCM before writing to IndexedDB
- Derive wrapping key from user password/PIN via PBKDF2 (>=2^19 iterations)
- Run crypto operations in a dedicated Web Worker
- Clear key material from memory as aggressively as JS GC allows

The GRP profile stores additional key material compared to SMP: the Noise static key pair, ML-KEM-768 keys (significantly larger - 1,184 bytes for the encapsulation key vs 32 bytes for X25519), and potentially Shamir share metadata. The IndexedDB encryption layer handles this transparently since it operates on arbitrary byte arrays.

---

## 4. WebSocket architecture

### 4.1 SharedWorker for connection management

To maintain chat state across tab switches and SPA navigation:

```
Browser Tab(s) <-> SharedWorker (WS Pool + Reconnection + Queue) <-> SMP/GRP Servers
                       |
                  IndexedDB (persistent message queue + encrypted key store)
```

The SharedWorker manages connections for both profiles. A single SharedWorker instance can maintain WebSocket connections to SMP servers (port 443) and GoRelay servers (port 7443) simultaneously, routing messages to the correct profile handler based on connection type.

### 4.2 Reconnection strategy

Production messaging apps use exponential backoff with jitter:
- 500ms base delay
- 2x multiplier per attempt
- 30-second maximum cap
- 50-100% multiplicative jitter (prevents thundering herd)
- After 12 attempts (~2 minutes): show "Connection lost" with manual reconnect
- Use `navigator.onLine` and `visibilitychange` for network-aware behavior

For the GRP profile, reconnection must re-establish the Noise session (full handshake) since Noise sessions cannot be trivially resumed. This adds approximately 100-400 microseconds for the hybrid PQ key exchange - imperceptible to users but architecturally different from SMP reconnection where the TLS session may be resumable.

### 4.3 Performance considerations

- Disable `permessage-deflate` compression (encrypted payloads are incompressible)
- Use binary WebSocket frames (not text) to avoid 33% Base64 overhead
- Browser limits: ~6-30 WebSocket connections per domain in Chrome, ~200 total in Firefox
- Multiplex multiple SMP queues over a single WebSocket per server

GRP connections through GoRelay's two-hop routing add 5-15ms latency per hop for same-region servers. For messaging where delivery latency of 1-5 seconds is normal, this is imperceptible. The cover traffic generated by GoRelay (Poisson-distributed dummy messages) adds bandwidth overhead but no user-visible latency.

---

## 5. Design specifications

### 5.1 Premium design targets

GoChat must achieve Intercom-level polish, not Chatwoot-level "it works".

| Element | Specification |
|:--------|:-------------|
| Panel width | 380px (350-400px range) |
| Panel height | 520-550px (100vh on mobile) |
| Launcher button | 56px circular FAB, bottom-right, 20px margin |
| Message font | 14px, system font stack, 1.5 line-height |
| Bubble border-radius | 18px (4px on tail corner) |
| Bubble max-width | 70-75% of container |
| Message spacing | 16px between senders, 2-4px within same sender |
| Dark mode background | #121212 (never pure black - causes halation) |
| Dark mode text | #E0E0E0 (never pure white) |
| Primary color | Blue (#3B82F6 range) - signals trust |
| Transitions | 200-300ms ease-out, only transform + opacity for 60fps |

### 5.2 Animation patterns

- **Message appear:** fade + translateY(10px->0) at 200ms ease-out
- **Panel open:** scale(0.9->1) + opacity(0->1) + translateY(20->0) with transform-origin: bottom right
- **Typing indicator:** Three 8px dots with staggered animation-delay, scale(0.6)->scale(1) at 1.4s
- **Launcher morph:** Chat bubble to X/close icon with 300ms rotation
- **All animations must respect** `prefers-reduced-motion`

### 5.3 The encryption indicator

GoChat's unique visual differentiator: A persistent lock icon with "End-to-end encrypted" badge, always visible. This is not just a feature - it is the brand. No competitor can match this.

For the dual-profile architecture, the encryption indicator should also communicate which profile is active. When using the GRP profile, an additional visual element (such as a shield icon or "Post-quantum secured" label) signals the elevated security level. The user should always know whether they are on SMP (standard encryption, any server) or GRP (Noise + PQ, GoRelay only).

### 5.4 Accessibility requirements

- Chat container: `role="log"` with `aria-live="polite"`
- All interactive elements: visible focus indicators + keyboard operability
- Touch targets: minimum 44x44px
- Color never the sole status indicator - always combine with icons or text

### 5.5 UX anti-patterns to avoid

Based on user complaints across all platforms:
1. **Never auto-open** the chat widget - use subtle launcher with optional badge
2. **Always provide** explicit "Talk to a human" button
3. **Never lose** conversation history between sessions (IndexedDB solves this)
4. **Never hide** the encryption status - transparency builds trust, especially when offering two security tiers

---

## 6. Competitive analysis summary

### 6.1 Feature comparison

| Feature | Intercom | Crisp | Chatwoot | GoChat (SMP) | GoChat (GRP) |
|:--------|:---------|:------|:---------|:-------------|:-------------|
| E2E encrypted | No | No | No | **Yes** | **Yes** |
| Post-quantum | No | No | No | No | **Yes (ML-KEM-768)** |
| No account needed | No | Partial | No | **Yes** | **Yes** |
| Self-hosted | No | No | Yes | **Yes** | **Yes** |
| Open source | No | No | Yes (MIT) | **Yes (AGPL-3.0)** | **Yes (AGPL-3.0)** |
| Dark mode | Yes | Yes | Yes | **Yes** | **Yes** |
| Multi-hop routing | No | No | No | No | **Yes (two-hop)** |
| Cover traffic | No | No | No | No | **Yes (Poisson)** |
| File sharing | Yes | Yes | Yes | **Planned** | **Planned** |
| Mobile responsive | Yes | Yes | Yes | **Planned** | **Planned** |
| Multi-agent | Yes | Yes | Yes | **Planned** | **Planned** |

### 6.2 Dual-profile positioning

The dual-profile architecture gives GoChat a unique market position that no competitor can replicate without fundamental re-architecture:

**SMP profile** competes with Chatwoot and open-source alternatives on features while adding E2E encryption as the key differentiator. The target audience is everyday businesses, communities, and personal use cases where "encrypted by default" is a selling point but the threat model does not include state-level adversaries.

**GRP profile** has no direct competitors in the browser space. Signal, Matrix, and Wire offer strong E2E encryption but none provide post-quantum transport, mandatory multi-hop routing, or cover traffic in their web clients. The closest comparison would be using Tor Browser with a messaging app - but that requires a separate application and does not integrate into a website.

The combination of both profiles in a single chat interface - selectable per connection - is unprecedented. A shop owner uses SMP for customer support. A journalist on the same website switches to GRP when contacting a source. Same UI, same codebase, fundamentally different security properties.

### 6.3 Encrypted messenger comparison (beyond support chat)

| Feature | Signal Web | Element Web | Wire Web | GoChat (SMP) | GoChat (GRP) |
|:--------|:-----------|:------------|:---------|:-------------|:-------------|
| Browser-native protocol | No (bridge) | Yes (Matrix) | Yes (Proteus/MLS) | **Yes (SMP)** | **Yes (GRP)** |
| Post-quantum transport | No | No | No | No | **Yes** |
| No app install | No | Yes | Yes | **Yes** | **Yes** |
| Embeddable widget | No | No | No | **Yes** | **Yes** |
| Noise transport | No | No | No | No | **Yes** |
| Cover traffic | No | No | No | No | **Yes** |
| Two-hop routing | No | No | No | No | **Yes** |
| Hardware endpoint | No | No | No | No | **Yes (SimpleGo)** |

---

## 7. Impact on GoChat season plan

### New tasks identified from research

- **WS-4:** SharedWorker for WebSocket connection pool management (both profiles)
- **SEC-1:** Content Security Policy implementation (strict, no eval)
- **SEC-2:** Subresource Integrity for all external scripts
- **SEC-3:** Web Worker isolation for crypto operations
- **SEC-4:** Security documentation - transparent trust boundary communication
- **SEC-5:** TLS certificate strategy (Let's Encrypt + SMP fingerprint at app layer)
- **UI-6:** Intercom-level animation system (panel, messages, typing, launcher)
- **UI-7:** Encryption indicator design and placement (with profile-aware display)
- **UI-8:** Accessibility audit (WCAG 2.1 AA compliance)

### Key architectural decisions

- **Dual-profile architecture:** SMP for everyday use, GRP for high-security. Both profiles share the same chat UI and the same ChatTransport interface abstraction. This is the single most important architectural decision in Season 1.
- **Crypto library:** Use @noble/curves + @noble/ciphers + @noble/hashes for both profiles. The @noble family covers SMP needs (X25519, NaCl) and GRP needs (ChaCha20-Poly1305, BLAKE2s) from a single audited source.
- **Post-quantum:** Defer ML-KEM-768 browser implementation to GRP development (Season 9+). No mature, audited JS implementation exists yet. Evaluate @noble/post-quantum vs WASM when the time comes.
- **Design ambition:** Target Intercom-level polish, not "functional minimum". The encryption badge is the brand.
- **WebSocket architecture:** SharedWorker layer for tab persistence, managing connections to both SMP and GoRelay servers.
- **ChatTransport interface from day one:** All transport code goes through the abstract interface. This ensures GRP can be added later without touching application-level code.
- **GRP as extension, not replacement:** GoChat does not replace SimpleX. It fills the browser gap. The GRP profile extends the SimpleX ecosystem for high-security environments via GoRelay's dual-protocol bridge.

### Modified decisions from initial planning

- **Crypto library:** Use @noble/curves + @noble/ciphers instead of direct Web Crypto API
- **Post-quantum (SMP):** sntrup761 deferred - no mature JS implementation. GRP uses ML-KEM-768 instead (NIST FIPS 203, Go stdlib available server-side).
- **Design ambition:** Target Intercom-level polish, not "functional minimum"
- **WebSocket architecture:** Add SharedWorker layer for tab persistence
- **Transport abstraction:** ChatTransport interface mandatory from the first line of transport code

---

## 8. References

| Topic | Source |
|:------|:-------|
| SMP Protocol Specification | simplex-chat/simplexmq protocol/simplex-messaging.md |
| SMP Server Hosting Guide | simplex.chat/docs/server.html |
| Noble Cryptography | paulmillr.com/noble/ |
| Ed25519 in Chrome | blogs.igalia.com (February 2025, August 2025) |
| Matrix Nebuchadnezzar Vulns | nebuchadnezzar-megolm.github.io |
| Element R (Rust->WASM crypto) | element.io/blog/meet-element-r |
| Wire core-crypto | github.com/wireapp/core-crypto |
| Browser E2E Encryption Overview | thomasbandt.com/browser-based-end-to-end-encryption-overview |
| OWASP WebSocket Security | cheatsheetseries.owasp.org |
| WebSocket Reconnection Guide | websocket.org/guides/reconnection/ |
| Chatwoot | github.com/chatwoot/chatwoot |
| Chat UI Design Patterns 2025 | bricxlabs.com/blogs/message-screen-ui-design |
| CSS Chat Box Templates | wpdean.com/css-chat-box/ |
| W3C ARIA role=log | w3.org/WAI/WCAG21/Techniques/aria/ARIA23 |
| Noise Protocol Framework | noiseprotocol.org |
| NIST FIPS 203 (ML-KEM) | csrc.nist.gov/pubs/fips/203/final |
| WireGuard Noise Implementation | wireguard.com/protocol/ |
| GoRelay Architecture | docs/ARCHITECTURE_AND_SECURITY.md (internal) |
| GoRelay Noise vs TLS Research | docs/research/03-noise-vs-tls.md (internal) |
| GoRelay PQ Landscape Research | docs/research/04-post-quantum-landscape.md (internal) |
| GoRelay Cover Traffic Research | docs/research/05-cover-traffic.md (internal) |
| GoRelay Two-Hop Routing Research | docs/research/06-dual-relay-routing.md (internal) |
| GoRelay Triple Shield Research | docs/research/12-triple-shield.md (internal) |

---

## Changelog

| Date | Change |
|------|--------|
| 2026-03-25 | Initial research document. Comprehensive analysis of browser crypto, security, design, and competitive landscape. |
| 2026-03-25 | Dual-profile update. Added GRP security context throughout, expanded competitive analysis with dual-profile positioning, added post-quantum browser crypto section, referenced GoRelay research documents, updated architectural decisions with ChatTransport interface and dual-profile as key Season 1 decision. |
