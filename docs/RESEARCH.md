<p align="center">
  <img src="../.github/assets/gochat_banner.png" alt="GoChat" width="1500" height="230">
</p>

<h1 align="center">GoChat - Research Findings</h1>

<p align="center">
  <strong>Deep research on browser-native encrypted messaging, design patterns, and security.</strong><br>
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

GoChat would be first on both counts: first browser-native SMP client AND first E2E encrypted customer support widget.

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

### 2.2 What Web Crypto still lacks

- XSalsa20-Poly1305 (needed for SMP NaCl crypto_box)
- XChaCha20-Poly1305
- Argon2 (key derivation)
- sntrup761 (post-quantum KEM)

These require external JavaScript libraries.

### 2.3 Recommended crypto library: @noble/curves

The noble cryptography suite by Paul Miller is the recommended choice:

- **6 professional security audits** (Cure53 x4, Trail of Bits x1, Kudelski Security x1)
- Zero dependencies, PGP-signed releases, transparent npm builds
- ~5KB for Ed25519 (vs ~290KB for libsodium.js)
- Used in production by: Proton Mail, Tutanota, MetaMask, Phantom, ethers.js, Trezor Suite
- The xftp-web infrastructure in the smp-web spike already uses @noble/hashes

Relevant packages:
- `@noble/curves` - Ed25519, X25519
- `@noble/ciphers` - XSalsa20-Poly1305, AES-256-GCM, Salsa20
- `@noble/hashes` - SHA-256, SHA-512, HKDF

### 2.4 Industry trend: Rust to WASM

Every major encrypted messenger has converged on Rust crypto compiled to WASM:

- **Element Web** (Matrix): Migrated to matrix-sdk-crypto (Rust->WASM), 14x faster key sharing
- **Signal Desktop**: Uses libsignal (Rust->WASM)
- **Wire**: Uses core-crypto (Rust->WASM), encrypts IndexedDB with AES-256-GCM

For GoChat Phase 1: Pure TypeScript with noble libraries is simpler to ship. A WASM-compiled Rust crypto core could be a Phase 2 optimization for better side-channel resistance.

---

## 3. Security analysis

### 3.1 The existential threat: XSS

A single XSS vulnerability defeats ALL encryption by intercepting plaintext before encryption or after decryption. The 2022 Matrix "Nebuchadnezzar" vulnerabilities demonstrated this in practice - researchers found exploitable bugs allowing confidentiality breaks and impersonation.

**Mitigations:**
- Strict CSP: `script-src 'self'` - no eval, no inline scripts
- Subresource Integrity (SRI) on all external scripts
- Minimal dependencies to reduce supply chain attack surface
- All crypto operations in a dedicated Web Worker (isolated from main thread)

The September 2025 npm supply chain attack compromised packages with 1 billion+ weekly downloads (chalk, debug, ansi-styles) - a stark reminder that dependency minimization is security-critical.

### 3.2 The trust boundary: server-delivered code

Unlike native apps distributed through signed app stores, web applications reload from the server on every visit. A compromised or malicious server can serve different code to different users.

**GoChat must document this trust boundary honestly while mitigating with:**
- Reproducible builds
- SRI hashes
- Potentially browser extension-based code verification
- Transparent security documentation

### 3.3 TLS certificate challenge

SMP servers use self-signed certificate chains where the offline CA certificate hash is embedded in the server address (`smp://fingerprint@host`). Browsers reject WSS connections to servers with untrusted certificates.

**Solution:** GoChat's SMP servers must use standard CA-signed certificates (e.g., Let's Encrypt) for the TLS layer. SMP's own DH key exchange provides a second encryption envelope independent of the TLS CA chain. The SMP server fingerprint verification happens at the application layer, not the TLS layer.

### 3.4 WebSocket-specific attacks

**Cross-Site WebSocket Hijacking (CSWSH):** Since WebSocket is not bound by Same-Origin Policy, a malicious page can open connections using the victim's cookies.

**Solution:** Use token-based authentication (not cookies) - pass tokens in the first WebSocket message after connection. This eliminates CSWSH entirely since there are no ambient credentials.

### 3.5 Browser key storage

Recommended layered approach:
- Store CryptoKey objects in IndexedDB with `extractable: false`
- Encrypt all sensitive data with AES-256-GCM before writing to IndexedDB
- Derive wrapping key from user password/PIN via PBKDF2 (>=2^19 iterations)
- Run crypto operations in a dedicated Web Worker
- Clear key material from memory as aggressively as JS GC allows

---

## 4. WebSocket architecture

### 4.1 SharedWorker for connection management

To maintain chat state across tab switches and SPA navigation:

```
Browser Tab(s) <-> SharedWorker (WS Pool + Reconnection + Queue) <-> SMP Servers
                       |
                  IndexedDB (persistent message queue + encrypted key store)
```

### 4.2 Reconnection strategy

Production messaging apps use exponential backoff with jitter:
- 500ms base delay
- 2x multiplier per attempt
- 30-second maximum cap
- 50-100% multiplicative jitter (prevents thundering herd)
- After 12 attempts (~2 minutes): show "Connection lost" with manual reconnect
- Use `navigator.onLine` and `visibilitychange` for network-aware behavior

### 4.3 Performance considerations

- Disable `permessage-deflate` compression (encrypted payloads are incompressible)
- Use binary WebSocket frames (not text) to avoid 33% Base64 overhead
- Browser limits: ~6-30 WebSocket connections per domain in Chrome, ~200 total in Firefox
- Multiplex multiple SMP queues over a single WebSocket per server

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

---

## 6. Competitive analysis summary

| Feature | Intercom | Crisp | Chatwoot | GoChat |
|:--------|:---------|:------|:---------|:-------|
| E2E encrypted | No | No | No | **Yes** |
| No account needed | No | Partial | No | **Yes** |
| Self-hosted | No | No | Yes | **Yes** |
| Open source | No | No | Yes (MIT) | **Yes (AGPL-3.0)** |
| Dark mode | Yes | Yes | Yes | **Yes** |
| File sharing | Yes | Yes | Yes | **Planned** |
| Mobile responsive | Yes | Yes | Yes | **Planned** |
| Multi-agent | Yes | Yes | Yes | **Planned** |
| AI integration | Yes | Yes | Partial | **Planned** |

---

## 7. Impact on GoChat season plan

### New tasks identified

- **WS-4:** SharedWorker for WebSocket connection pool management
- **SEC-1:** Content Security Policy implementation (strict, no eval)
- **SEC-2:** Subresource Integrity for all external scripts
- **SEC-3:** Web Worker isolation for crypto operations
- **SEC-4:** Security documentation - transparent trust boundary communication
- **SEC-5:** TLS certificate strategy (Let's Encrypt + SMP fingerprint at app layer)
- **UI-6:** Intercom-level animation system (panel, messages, typing, launcher)
- **UI-7:** Encryption indicator design and placement
- **UI-8:** Accessibility audit (WCAG 2.1 AA compliance)

### Modified decisions

- **Crypto library:** Use @noble/curves + @noble/ciphers instead of direct Web Crypto API
- **Post-quantum:** Defer sntrup761 to future season (no mature JS implementation)
- **Design ambition:** Target Intercom-level polish, not "functional minimum"
- **WebSocket architecture:** Add SharedWorker layer for tab persistence

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

---

## Changelog

| Date | Change |
|------|--------|
| 2026-03-25 | Initial research document. Comprehensive analysis of browser crypto, security, design, and competitive landscape. |
