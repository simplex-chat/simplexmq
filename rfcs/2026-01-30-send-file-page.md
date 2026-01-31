# Send File Page — Web-based XFTP File Transfer

## 1. Problem & Business Case

There is no way to send or receive files using SimpleX without installing the app. A static web page that implements the XFTP protocol client-side would allow anyone with a browser to upload and download files via XFTP servers, promoting app adoption.

**Business constraints:**
- Web page allows up to 100 MB uploads; app allows up to 1 GB.
- Page must promote app installation (e.g., banner, messaging around limits).

**Security constraint:**
- The server hosting the page must never access file content or file descriptions. The file description is carried in the URL hash fragment (`#`), which browsers do not send to the server.
- The only way to compromise transfer security is page substitution (serving malicious JS). Mitigations: standard web security (HTTPS, CSP, SRI) and IPFS hosting with page fingerprints published in multiple independent locations.

## 2. Design Overview

```
┌─────────────────────────────────────────────────────────────────┐
│  Static web page (HTML + JS bundle)                             │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │  TypeScript XFTP Client Library                           │  │
│  │  ┌──────────┐ ┌──────────┐ ┌───────────┐ ┌─────────────┐  │  │
│  │  │ Protocol │ │ Crypto   │ │ Transport │ │ Description │  │  │
│  │  │ Encoding │ │(libsodium│ │ (fetch    │ │ (YAML parse │  │  │
│  │  │          │ │  .js)    │ │  API)     │ │  + encode)  │  │  │
│  │  └──────────┘ └──────────┘ └───────────┘ └─────────────┘  │  │
│  └───────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
         │ fetch() over HTTP/2          │ fetch() over HTTP/2
         ▼                              ▼
┌─────────────────┐            ┌─────────────────┐
│ XFTP Server 1   │            │ XFTP Server 2   │
│ (SNI→web cert)  │            │ (SNI→web cert)  │
│ (+CORS headers) │            │ (+CORS headers) │
└─────────────────┘            └─────────────────┘
```

**Key decisions:**
- **Language:** TypeScript (readable, auditable, good ecosystem, Node.js for testing).
- **Crypto:** libsodium.js (WASM-compiled libsodium; provides XSalsa20-Poly1305, Ed25519, X25519).
- **Transport:** Browser `fetch()` API over HTTP/2 with `ReadableStream` for streaming.
- **No backend logic:** The page is entirely static. All XFTP operations happen client-side.

## 3. Web Page UX

### 3.1 Upload Flow

1. **Landing state:** Drag-and-drop zone with centered upload icon and "Drop file here or click to upload" text. File size limit displayed ("Up to 100 MB — install SimpleX app for up to 1 GB"). Simple white background, no decoration.
2. **File selected:** Show file name and size. Begin upload immediately.
3. **Upload progress:** Large circular progress indicator (clockwise, starting from 3 o'clock position). Percentage in center. Cancel button below.
4. **Upload complete:** Show shareable link with copy button. QR code if link is short enough (≤ ~1000 chars). "Install SimpleX for larger files" CTA.

### 3.2 Download Flow

1. **Link opened:** Page parses hash fragment, shows file name and size. "Download" button.
2. **Download progress:** Same circular progress indicator as upload.
3. **Download complete:** Browser save dialog triggered (via Blob + download link, or File System Access API where available).

### 3.3 Error States

- File too large (> 100 MB): Show limit message with app install CTA.
- Server unreachable: Retry with exponential backoff, show error after exhausting retries.
- File expired: "This file is no longer available" message.
- Decryption failure: "File corrupted or link invalid" message.

## 4. URL Scheme

### 4.1 Format

```
https://example.com/file/#<compressed-base64url-encoded-file-description>
```

- Hash fragment is never sent to the server.
- Compression: DEFLATE (raw, no gzip/zlib wrapper) — better ratio than LZW for structured text like YAML.
- Encoding: Base64url (RFC 4648 §5) — no `+`, `/`, `=`, or `%` characters.

Alternative: LZW + base64url if DEFLATE proves problematic. Both should be evaluated.

### 4.2 Redirect Mechanism

For files with many chunks, the YAML file description can exceed a practical URL length. The threshold is ~600 bytes of compressed+encoded description (configurable).

**Flow when description is too large:**
1. Serialize recipient file description to YAML.
2. Encrypt YAML using fresh key + nonce (same XSalsa20-Poly1305 as files).
3. Upload encrypted YAML as a single-chunk "file" to one randomly chosen XFTP server.
4. Create redirect description pointing to this uploaded description.
5. Encode redirect description into URL (always small — single chunk).

**Download with redirect:**
1. Parse URL → redirect description (has `redirect` field with `size` and `digest`).
2. Download the description "file" using the single chunk reference.
3. Decrypt → get full YAML description.
4. Validate size and digest match redirect metadata.
5. Proceed with normal download using full description.

### 4.3 Estimated URL Lengths

These estimates are preliminary and may be incorrect.

| Scenario | Chunks | Compressed+encoded size | URL length |
|----------|--------|------------------------|------------|
| Small file (1 chunk, 1 server) | 1 | ~300 bytes | ~350 chars |
| Medium file (5 chunks, 1 server) | 5 | ~500 bytes | ~550 chars |
| Large file (25+ chunks) | 25 | Exceeds threshold → redirect | ~350 chars |

## 5. TypeScript XFTP Client Library

### 5.1 Module Structure

```
xftp-web/src/                      # Separate npm project (see §12.19)
├── protocol/
│   ├── encoding.ts        # Binary encoding/decoding matching Haskell Encoding module
│   ├── commands.ts         # XFTP command types (FNEW, FPUT, FGET, etc.)
│   ├── responses.ts        # XFTP response types (FRSndIds, FRFile, etc.)
│   └── transmission.ts     # Transmission framing, signing, padding
├── crypto/
│   ├── secretbox.ts        # XSalsa20-Poly1305 streaming encryption/decryption
│   ├── file.ts             # File-level encryption/decryption (encryptFile, decryptChunks)
│   ├── keys.ts             # Ed25519, X25519 key generation and operations
│   ├── digest.ts           # SHA-256/SHA-512 hashing
│   └── padding.ts          # Block padding/unpadding (2-byte length prefix + '#' fill)
├── transport/
│   ├── client.ts           # HTTP/2 client via fetch(), streaming body
│   ├── handshake.ts        # XFTP handshake (standard + web variant)
│   └── cors.ts             # CORS-aware request handling
├── description/
│   ├── types.ts            # FileDescription, FileChunk, FileChunkReplica types
│   ├── yaml.ts             # YAML serialization/deserialization
│   ├── uri.ts              # URL encoding/decoding with compression
│   └── validation.ts       # Description validation (sequential chunks, size match)
├── agent/
│   ├── upload.ts           # Full upload orchestration
│   ├── download.ts         # Full download orchestration
│   └── chunking.ts         # File splitting, chunk size selection
└── index.ts                # Public API
```

### 5.2 Binary Encoding

The XFTP wire format uses a custom binary encoding (from `Simplex.Messaging.Encoding`). Key patterns:

- **Length-prefixed bytestrings:** `<1-byte length><bytes>` (`ByteString`, max 255 bytes — used for entity IDs, short fields) or `<2-byte big-endian length><bytes>` (`Large`, max 65535 bytes — used for larger data).
- **Transmission format:** `<signature> <corrId> <entityId> <command>`
  - Fields separated by space (0x20).
  - `signature`: Ed25519 signature over `(sessionId ++ corrId ++ entityId ++ encodedCommand)`.
  - `corrId`: Correlation ID (arbitrary, echoed in response).
  - `entityId`: File/chunk ID on server.
  - Command: tag + space-separated fields.
- **Padding:** 2-byte big-endian length prefix + message + `#` (0x23) fill to block size (16384 bytes).

### 5.3 Crypto Operations Catalog

| Operation | Algorithm | Key Size | Nonce Size | Tag Size | Library |
|-----------|-----------|----------|------------|----------|---------|
| File encryption | XSalsa20-Poly1305 | 32 B | 24 B | 16 B | libsodium.js |
| File decryption | XSalsa20-Poly1305 | 32 B | 24 B | 16 B | libsodium.js |
| Transit decryption (download) | XSalsa20-Poly1305 (streaming: `cbInit` + `sbDecryptChunk`) | DH shared secret | 24 B | 16 B | libsodium.js |
| Command signing | Ed25519 | 64 B (private) | — | 64 B (sig) | libsodium.js |
| DH key exchange | X25519 | 32 B | — | — | libsodium.js |
| Chunk digest | SHA-256 | — | — | 32 B | Web Crypto API |
| File digest | SHA-512 | — | — | 64 B | Web Crypto API |
| Random bytes | ChaCha20-DRBG | — | — | — | libsodium.js `randombytes_buf` |

**Streaming encryption detail:**

The Haskell implementation uses a custom streaming wrapper over XSalsa20-Poly1305:
1. Initialize: `(xsalsa20_state, poly1305_state) = sbInit(key, nonce)`
   - Generate 32-byte Poly1305 key from first XSalsa20 output block
   - Initialize Poly1305 state with this key
2. Encrypt chunk: XOR plaintext with XSalsa20 keystream, update Poly1305 with ciphertext
3. Finalize: Compute 16-byte Poly1305 tag, append to stream

This is NOT compatible with standard NaCl `crypto_secretbox` (see §11.2). The TypeScript implementation must reimplement the exact streaming logic using libsodium's low-level XSalsa20 and Poly1305 APIs. See §12.4 for the complete function mapping.

### 5.4 Transport via fetch()

Each XFTP command is an HTTP/2 POST request:

```typescript
async function sendXFTPCommand(
  serverUrl: string,
  commandBlock: Uint8Array,        // 16384 bytes, padded
  fileChunk?: ReadableStream<Uint8Array>  // optional, for FPUT
): Promise<{ responseBlock: Uint8Array; body?: ReadableStream<Uint8Array> }> {

  const bodyStream = fileChunk
    ? concatStreams(streamFromBytes(commandBlock), fileChunk)
    : streamFromBytes(commandBlock);

  const response = await fetch(serverUrl, {
    method: 'POST',
    body: bodyStream,
    duplex: 'half',  // Required for streaming request bodies
    // No Content-Type header — binary protocol
  });

  const reader = response.body!.getReader();
  const responseBlock = await readExactly(reader, 16384);
  const body = hasMoreData(reader) ? wrapAsStream(reader) : undefined;

  return { responseBlock, body };
}
```

**Browser compatibility for streaming uploads:**
- Chrome 105+, Edge 105+: `fetch()` with `ReadableStream` body + `duplex: 'half'`
- Firefox 102+: Supported
- Safari 16.4+: Supported

For older browsers, fall back to `ArrayBuffer` body (buffer entire chunk in memory).

### 5.5 Upload Orchestration

```
1. Read file via File API (drag-drop or file picker)
2. Validate size ≤ 100 MB
3. Generate random SbKey (32 bytes) + CbNonce (24 bytes)
4. Create FileHeader { fileName }
5. Encrypt file (see §12.8 for algorithm detail):
   a. Init streaming state: `sbInit(key, nonce)`
   b. Encrypt `smpEncode(fileSize') <> headerBytes` where `fileSize'` = headerLen + originalFileSize
   c. Encrypt file data in 65536-byte chunks (threaded state)
   d. Encrypt `'#'` padding in 65536-byte chunks to fill `encSize - authTagSize - fileSize' - 8`
   e. Finalize: `sbAuth(state)` → append 16-byte auth tag
6. Compute SHA-512 digest of encrypted data
7. Split into chunks using prepareChunkSizes algorithm:
   - > 75% of 4MB → 4MB chunks
   - > 75% of 1MB → 1MB + 4MB chunks
   - Otherwise → 64KB + 256KB chunks
8. For each chunk (parallel, up to 8 concurrent):
   a. Generate Ed25519 sender keypair
   b. Generate Ed25519 recipient keypair (1 recipient for web)
   c. Compute SHA-256 chunk digest
   d. Connect to XFTP server (handshake if new connection)
   e. Send FNEW { sndKey, size, digest } + recipient keys → receive (senderId, [recipientId])
   f. Send FPUT with chunk data → receive OK
   g. Report progress
9. Build FileDescription YAML from all chunk metadata
10. If YAML size (compressed+encoded) > threshold:
    a. Encrypt YAML as a file
    b. Upload encrypted YAML (single chunk) → get redirect description
    c. Use redirect description for URL
11. Compress + base64url encode description
12. Display URL: https://example.com/file/#<encoded>
```

### 5.6 Download Orchestration

```
1. Parse URL hash fragment
2. Base64url decode + decompress → YAML
3. Parse YAML → FileDescription
4. Validate description (sequential chunks, sizes match)
5. If redirect field present:
   a. Download redirect file (single chunk)
   b. Decrypt, validate size+digest, parse inner description
   c. Continue with inner description
6. For each chunk (parallel, up to 8 concurrent):
   a. Generate ephemeral X25519 keypair
   b. Connect to XFTP server (web handshake)
   c. Send FGET { recipientDhPubKey } → receive (serverDhPubKey, cbNonce) + encrypted body
   d. Compute DH shared secret
   e. Transit-decrypt chunk body (XSalsa20-Poly1305 with DH secret)
   f. Verify chunk digest (SHA-256)
   g. Send FACK → receive OK
   h. Report progress
7. Concatenate all transit-decrypted chunks (in order) → encrypted file
8. Verify file digest (SHA-512)
9. File-decrypt entire stream (XSalsa20-Poly1305 with file key + nonce)
10. Extract FileHeader → get original fileName
11. Trigger browser download (Blob + <a download> or File System Access API)
```

## 6. XFTP Server Changes

### 6.1 SNI-Based Certificate Switching

The SMP server already implements SNI-based certificate switching (see `Transport/Server.hs:255-269`). The same mechanism must be added to the XFTP server.

**Current SMP implementation:**
```haskell
T.onServerNameIndication = case sniCredential of
    Nothing -> \_ -> pure $ T.Credentials [credential]
    Just sniCred -> \case
      Nothing -> pure $ T.Credentials [credential]
      Just _host -> T.Credentials [sniCred] <$ atomically (writeTVar sniCredUsed True)
```

**XFTP changes needed:**
1. Add `httpCredentials :: Maybe T.Credential` to `XFTPServerConfig`.
2. Add configuration section `[WEB]` to `file-server.ini` for HTTPS cert/key paths.
3. Create `TLSServerCredential` with both XFTP and web certificates.
4. Pass combined credentials to `runHTTP2Server` → `runTransportServerState_`.
5. Use `sniCredUsed` flag to distinguish web vs. native clients.

**Certificate setup:**
- XFTP identity certificate: Existing self-signed CA chain (used for protocol identity via fingerprint).
- Web certificate: Standard CA-issued TLS certificate (e.g., Let's Encrypt) for the server's FQDN.
- Both certificates served on the same port (443).

### 6.2 CORS Support

Browsers enforce same-origin policy. The web page (served from `example.com`) must make cross-origin requests to XFTP servers (`xftp1.simplex.im`, etc.).

**Required server changes:**

1. **Handle OPTIONS preflight requests:**
   ```
   OPTIONS /
   Response headers:
     Access-Control-Allow-Origin: *
     Access-Control-Allow-Methods: POST, OPTIONS
     Access-Control-Allow-Headers: Content-Type
     Access-Control-Max-Age: 86400
   Response body: empty
   Response status: 200
   ```

2. **Add CORS headers to all POST responses (when Origin header present):**
   ```
   Access-Control-Allow-Origin: *
   Access-Control-Expose-Headers: *
   ```

3. **Implementation location:** In `runHTTP2Server` handler or a wrapper around the XFTP request handler. Detect the `Origin` header → add CORS headers. This can be conditional on web mode being enabled in config.

**Security consideration:** `Access-Control-Allow-Origin: *` is safe here because:
- All XFTP commands require Ed25519 authentication (per-chunk keys from file description).
- No cookies or browser credentials are involved.
- File content is end-to-end encrypted.

### 6.3 Web Handshake with Server Identity Proof

**Both SNI and web handshake are required.** They solve different problems:

1. **SNI certificate switching** is required because browsers reject self-signed certificates. The XFTP identity certificate is self-signed (CA chain with offline root), so the server must present a standard CA-issued web certificate (e.g., Let's Encrypt) when a browser connects. SNI is how the server detects this.

2. **Web handshake with challenge-response** is required because browsers cannot access the TLS certificate fingerprint or the TLS-unique channel binding (`sessionId`). The native client validates XFTP identity by checking the certificate chain fingerprint against the known `keyHash` and binding it to the TLS session. The browser gets none of this — it only knows TLS succeeded with some CA-issued cert. So the XFTP identity must be proven at the protocol level.

**Standard handshake (unchanged for native clients):**
```
1. Client → empty POST body → Server
2. Server → padded { vRange, sessionId, CertChainPubKey } → Client
3. Client → padded { version, keyHash } → Server
4. Server → empty → Client
```

**Web handshake (new, when SNI is detected):**
```
1. Client → padded { challenge: 32 random bytes } → Server
2. Server → padded { vRange, sessionId, CertChainPubKey } (header block)
            + extended body { fullCertChain, signature(challenge ++ sessionId) } → Client
3. Client validates:
   - Certificate chain CA fingerprint matches known keyHash
   - Signature over (challenge ++ sessionId) is valid under cert's public key
   - This proves: server controls XFTP identity key AND is live (not replay)
4. Client → padded { version, keyHash } → Server
5. Server → empty → Client
```

**Detection mechanism:** The server detects web clients by the `sniCredUsed` flag (already available from the TLS layer). When SNI is detected, the server expects a challenge in the first POST body (non-empty, unlike standard handshake where it is empty). No marker byte is needed — SNI presence is the discriminator.

**Block size note:** The XFTP block size is 16384 bytes (`Protocol.hs:65`). The XFTP identity certificate chain fits within this block. The signed challenge response is sent as an extended body (streamed after the 16384-byte header block), same mechanism as file chunk data.

### 6.4 Protocol Version and Handshake Extension

Current XFTP versions: v1 (initial), v2 (auth commands), v3 (blocked files). These version numbers refer to wire encoding format changes, not handshake changes.

The XFTP handshake is binary-encoded via the `Encoding` typeclass (`Transport.hs:128-142`). Both `XFTPServerHandshake` and `XFTPClientHandshake` parsers end with `Tail _compat <- smpP`, which consumes any remaining bytes. This `Tail` extension field allows adding new fields to the handshake without breaking existing parsers — old clients/servers simply ignore the extra bytes.

**No protocol version bump is needed** for the web handshake. The web handshake is detected via SNI (transport layer), and the challenge/response extension can use the existing `Tail` field. When SNI is detected:
1. Use web TLS certificate (existing SNI mechanism).
2. Expect challenge in first POST body (non-empty body = web client).
3. Include certificate proof in response extended body.
4. Add CORS headers to all responses for this connection.

### 6.5 Serving the Static Page

The XFTP server can optionally serve the static web page itself (similar to how SMP servers serve info pages). When a browser connects via SNI and sends a GET request (not POST), the server serves the HTML/JS/CSS bundle.

This can be implemented identically to the SMP server's static page serving (`apps/smp-server/web/Static.hs`), using Warp to handle HTTP requests on the same TLS connection.

Alternatively, the page is hosted on a separate web server (e.g., `files.simplex.chat`). The XFTP servers only need to handle XFTP protocol requests (POST) with CORS headers.

## 7. Security Analysis

### 7.1 Threat Model

| Threat | Mitigation | Residual Risk |
|--------|-----------|---------------|
| Page substitution (malicious JS) | HTTPS, CSP, SRI; IPFS hosting with fingerprints in multiple locations | If web server is compromised and IPFS is not used, all guarantees lost. Fundamental limitation of web-based E2E crypto, mitigated by IPFS. |
| MITM between browser and XFTP server | XFTP identity verification via challenge-response handshake | Attacker can relay traffic (see §7.2) but cannot read file content due to E2E encryption. |
| File description leakage | Hash fragment (`#`) is never sent to server | If browser extension or malware reads URL bar, description is exposed. |
| Server learns file content | File encrypted client-side before upload (XSalsa20-Poly1305) | Server sees encrypted chunks only. |
| Traffic analysis | File size visible to network observers | Same as native XFTP client. |

### 7.2 Relay Attack Analysis

An attacker who controls the network could relay all traffic between the browser and the real XFTP server:

1. Browser sends challenge to "attacker's server"
2. Attacker relays to real server
3. Real server signs challenge + sessionId with XFTP identity key
4. Attacker relays signed response to browser
5. Browser validates ✓ (signature is from the real server)

However, the attacker **cannot read file content** because:
- File encryption key is in the hash fragment (never sent over network)
- Transit encryption uses DH key exchange (FGET) — attacker doesn't have server's DH private key
- The attacker can observe transfer sizes and timing, but this is already visible via traffic analysis

The relay attack is equivalent to a passive network observer, which is the same threat model as native XFTP.

### 7.3 Comparison with Native Client Security

| Property | Native Client | Web Client |
|----------|--------------|------------|
| TLS certificate validation | XFTP identity cert via fingerprint pinning | Web CA cert via browser + XFTP identity via challenge-response |
| Session binding | TLS-unique binds to XFTP identity cert | TLS-unique binds to web cert; challenge binds to XFTP identity |
| Code integrity | Binary signed/distributed via app stores | Served over HTTPS; SRI for subresources; IPFS hosting option; vulnerable to server compromise |
| File encryption | XSalsa20-Poly1305 | Same |
| Transit encryption | DH + XSalsa20-Poly1305 | Same |

### 7.4 Layman Security Summary (Displayed on Page)

The web page should display a brief, non-technical security summary explaining to users:
- Files are encrypted in the browser before upload — the server never sees file contents.
- The file link (URL) contains the decryption key in the hash fragment, which the browser never sends to any server.
- Only someone with the exact link can download and decrypt the file.
- The main risk is if the web page itself is tampered with (page substitution attack). IPFS hosting mitigates this.
- For maximum security, use the SimpleX app instead.

## 8. Implementation Approach Discussion

### 8.1 Option 1: Haskell to WASM

**Verdict: Not practical.**

- Template Haskell is used extensively (`Data.Aeson.TH`, `deriveJSON`) — incompatible with GHC WASM backend.
- Deep dependencies on STM, IORef, SQLite (for agent) — would need extensive modification.
- GHC WASM backend is experimental, large binary output (~10+ MB).
- Hard to debug in browser context.

### 8.2 Option 2: TypeScript Reimplementation (Recommended)

**Verdict: Best approach.**

- Well-understood, readable, auditable by the community.
- Rich crypto ecosystem (libsodium.js provides all needed NaCl primitives as WASM).
- Direct access to browser APIs (fetch, File, ReadableStream, Blob).
- Testable in Node.js against Haskell XFTP server.
- Small bundle size (~200 KB with libsodium WASM).

**Risk:** Exact byte-level wire compatibility requires careful encoding implementation and thorough testing against the Haskell server.

### 8.3 Option 3: C to WASM

**Verdict: Viable but unnecessary.**

- Could use libsodium C code directly for crypto (faster, reference implementation).
- But protocol encoding + YAML + orchestration still needs a higher-level language.
- Emscripten toolchain adds build complexity.
- In practice, libsodium.js already IS C-to-WASM, so Option 2 gets this benefit.

### 8.4 Option 4: Hybrid (TypeScript + C/WASM crypto)

**Verdict: This IS Option 2**, since libsodium.js is WASM-compiled C. The TypeScript code calls into WASM for crypto, implements protocol/transport/orchestration in TypeScript.

## 9. Implementation Plan

### Phase 1: TypeScript XFTP Client Core

**Goal:** A Node.js-runnable XFTP client that can upload and download files against a real Haskell XFTP server.

1. **Binary encoding module** — Implement `Encoding` equivalent: length-prefixed bytestrings, padding, SMP-style encoding for all XFTP types.
2. **Crypto module** — Wrapper around libsodium.js for: key generation (Ed25519, X25519), signing, XSalsa20-Poly1305 streaming encryption/decryption, SHA-256/SHA-512 hashing.
3. **Protocol module** — XFTP command encoding (FNEW, FADD, FPUT, FDEL, FGET, FACK, PING) and response decoding (FRSndIds, FRRcvIds, FRFile, FROk, FRErr, FRPong). Transmission framing with signing and padding.
4. **Transport module** — HTTP/2 client using `fetch()` (Node.js 18+ built-in or `undici`). Handshake implementation (standard XFTP handshake first, web variant later).
5. **File description module** — YAML serialization/deserialization matching Haskell's `StrEncoding` for `FileDescription`. Validation.
6. **Agent module** — Upload orchestration (encrypt → chunk → register → upload → build description). Download orchestration (parse description → download → transit-decrypt → file-decrypt).

### Phase 2: Integration Testing

**Goal:** Prove the TypeScript client is wire-compatible with the Haskell server.

1. **Test harness** — Node.js test (`xftp-web/test/integration.test.ts`) spawns `xftp-server` and `xftp` CLI as subprocesses.
2. **Upload test** — TypeScript uploads file → Haskell client downloads it → verify contents match.
3. **Download test** — Haskell client uploads file → TypeScript downloads it → verify contents match.
4. **Round-trip test** — TypeScript upload → TypeScript download → verify.
5. **Edge cases** — Single chunk, many chunks, exactly-sized chunks, redirect descriptions.

### Phase 3: XFTP Server Changes

**Goal:** XFTP servers support web client connections.

1. **SNI certificate switching** — Port SMP server's `TLSServerCredential` mechanism to XFTP server.
2. **CORS headers** — Add OPTIONS handler and CORS response headers when Origin is present.
3. **Web handshake** — Detect web client (SNI-based), include identity proof (cert chain + signed challenge) in handshake response.
4. **Configuration** — Add `[WEB]` section to `file-server.ini` for HTTPS cert paths and web mode toggle.

### Phase 4: Web Page

**Goal:** Static HTML page with upload/download UX.

1. **Bundle TypeScript** — Compile to ES module bundle with libsodium.js WASM included.
2. **Upload UI** — Drag-drop zone, file picker, progress circle, link display.
3. **Download UI** — Parse URL, show file info, download button, progress circle.
4. **URL encoding** — DEFLATE compression + base64url for file description in hash fragment.
5. **App install CTA** — Banner/messaging promoting SimpleX app for larger files.

### Phase 5: Server-Hosted Page (Optional)

**Goal:** XFTP servers can optionally serve the web page themselves.

1. **Static file serving** — Similar to SMP server's `attachStaticFiles`.
2. **GET handler** — When web client sends HTTP GET (not POST), serve HTML page.
3. **Page generation** — Embed page bundle at server build time.

## 10. Testing Strategy

### 10.1 Per-Function Unit Tests (Haskell-driven)

**Haskell is the test driver.** For each TypeScript function, there is one Haskell test case that:
1. Calls the Haskell function with known (or random) input → gets expected output.
2. Calls the same-named TypeScript function via `node` → gets actual output.
3. Asserts byte-identical results.

This means **zero special test code on the TypeScript side** — node just `require`s the production module and calls the exported function. The Haskell test file is pure boilerplate.

**Haskell helper** (defined once in the test file):
```haskell
callTS :: FilePath -> String -> ByteString -> IO ByteString
callTS modulePath funcName inputHex = do
  let script = "const m = require('./" <> modulePath <> "'); "
            <> "process.stdout.write(m." <> funcName
            <> "(Buffer.from('" <> B.unpack (Base16.encode inputHex) <> "', 'hex')))"
  (_, Just hout, _, ph) <- createProcess (proc "node" ["-e", script])
    {std_out = CreatePipe, cwd = Just xftpWebDir}
  out <- B.hGetContents hout
  void $ waitForProcess ph
  pure out
```

**Example test cases:**
```haskell
describe "protocol/encoding" $ do
  it "encodeWord16" $ do
    let expected = smpEncode (42 :: Word16)
    actual <- callTS "src/protocol/encoding" "encodeWord16" (smpEncode (42 :: Word16))
    actual `shouldBe` expected

describe "crypto/secretbox" $ do
  it "sbEncryptTailTag" $ do
    let Right expected = LC.sbEncryptTailTag testKey testNonce testData testLen testPadLen
    actual <- callTS "src/crypto/secretbox" "sbEncryptTailTag"
      (smpEncode testKey <> smpEncode testNonce <> testData <> smpEncode testLen <> smpEncode testPadLen)
    actual `shouldBe` LB.toStrict expected
  it "sbEncryptTailTag round-trip" $ do
    let Right ct = LC.sbEncryptTailTag testKey testNonce testData testLen testPadLen
    actual <- callTS "src/crypto/secretbox" "sbDecryptTailTag"
      (smpEncode testKey <> smpEncode testNonce <> smpEncode testPadLen <> LB.toStrict ct)
    actual `shouldBe` LB.toStrict testData

describe "crypto/padding" $ do
  it "pad" $ do
    let Right expected = C.pad testMsg 16384
    actual <- callTS "src/crypto/padding" "pad" (encodeTestArgs testMsg (16384 :: Int))
    actual `shouldBe` expected
```

**Each row in §12.1–12.17 function mapping tables becomes a test case.** The tables serve as the test case list.

**Development workflow:** Implement one TS function → run its Haskell test → fix until it passes → move to next function. Bottom-up confidence building. No guessing what's broken.

**Test execution:** Tests live in `tests/XFTPWebTests.hs` in the simplexmq repo, skipped by default (require compiled TS project path). Run with:
```bash
cabal test --test-option=--match="/XFTP Web Client/"
```

**Random inputs:** Haskell tests can use QuickCheck to generate random inputs each run, not just hardcoded values. This catches edge cases that fixed test vectors miss.

### 10.2 Integration Tests (TS-driven, spawns Haskell server)

**Only attempted after all per-function tests (§10.1) pass.** These are end-to-end tests that verify the full upload/download pipeline works against a real XFTP server.

**Approach:** Node.js test (`xftp-web/test/integration.test.ts`) spawns `xftp-server` and `xftp` CLI as subprocesses.

```
┌────────────────────────────────────────────────────────────────┐
│  Node.js test process (integration.test.ts)                    │
│                                                                │
│  1. Spawn xftp-server subprocess                               │
│  2. Run TypeScript XFTP client (under test) ──── HTTP/2 ────┐  │
│  3. Spawn xftp CLI to download/verify          │            │  │
│                                                │            │  │
│  ┌──────────────────────┐    ┌─────────────────▼──────────┐ │  │
│  │ xftp CLI (Haskell)   │    │ xftp-server (Haskell)      │ │  │
│  │ (verify/upload)      │◄───│ (subprocess)               │ │  │
│  └──────────────────────┘    └────────────────────────────┘ │  │
└────────────────────────────────────────────────────────────────┘
```

**Test scenarios:**
1. TypeScript uploads → Haskell `xftp` CLI downloads → content verified.
2. Haskell `xftp` CLI uploads → TypeScript downloads → content verified.
3. TypeScript upload + download round-trip.
4. Web handshake with challenge-response validation.
5. Redirect descriptions (large file → compressed description upload).
6. Multiple chunks across multiple servers.
7. Error cases: expired file, auth failure, digest mismatch.

### 10.3 Browser Tests

- Manual testing in Chrome, Firefox, Safari.
- Automated via Playwright or Puppeteer (optional, for CI).
- Focus on: streaming upload/download, progress reporting, URL parsing, CORS.

### 10.4 Test Ordering (Bottom-Up)

The per-function tests (§10.1) must pass before attempting integration tests (§10.2). Implementation and testing order:

1. **Encoding primitives** — `encodeWord16`, `encodeBytes`, `encodeLarge`, `pad`, `unPad` (§12.1, §12.7)
2. **Crypto primitives** — `sha256`, `sha512`, `sign`, `verify`, `dh`, key generation (§12.5, §12.6)
3. **Streaming crypto** — `sbInit`, `sbEncryptChunk`, `sbDecryptChunk`, `sbAuth` (§12.4)
4. **File crypto** — `padLazy`, `unPadLazy` (§12.7), then `encryptFile`, `decryptChunks` (§12.8 — uses streaming crypto from step 3, not padLazy)
5. **Protocol encoding** — command/response encoding, transmission framing (§12.2, §12.3)
6. **Handshake** — handshake type encoding/decoding (§12.9)
7. **Description** — YAML serialization, validation (§12.12–§12.14)
8. **Chunk sizing** — `prepareChunkSizes`, `getChunkDigest` (§12.11)
9. **Transport client** — `sendCommand`, `createChunk`, `uploadChunk`, `downloadChunk` (§12.10)
10. **Integration** — full upload/download round-trips (§10.2)

## 11. Resolved Design Decisions

### 11.1 Block Size

The XFTP block size is 16384 bytes (`Protocol.hs:65`). The XFTP identity certificate chain fits within a single block. The signed challenge response for web handshake is sent as an extended body after the header block.

### 11.2 Streaming Encryption Compatibility

**The Haskell streaming XSalsa20-Poly1305 is NOT compatible with standard NaCl `crypto_secretbox`.** Analysis of `Crypto/Lazy.hs` confirms:

- `SbState` (line 196) is `(XSalsa.State, Poly1305.State)` — explicit state pair.
- `sbInit` (line 202) generates a 32-byte Poly1305 key from the first XSalsa20 keystream block, then initializes both states.
- `sbEncryptChunk` (line 229) XORs plaintext with keystream and updates Poly1305 with the ciphertext.
- `sbAuth` (line 241) finalizes Poly1305 → 16-byte auth tag.
- **Auth tag is appended at the END** for files (`sbEncryptTailTag`, line 134), unlike standard NaCl which prepends it.
- Standard `crypto_secretbox` produces `tag ++ ciphertext`; this produces `ciphertext ++ tag`.

The TypeScript implementation must reimplement the exact streaming logic using libsodium's low-level XSalsa20 and Poly1305 APIs. `crypto_secretbox_easy` cannot be used.

### 11.3 Web Client Detection

Both SNI and web handshake are mandatory (see §6.3). SNI detection (`sniCredUsed` flag) is the discriminator — when SNI is detected, the server expects the web handshake variant.

### 11.4 URL Compression

DEFLATE (raw, no gzip/zlib wrapper). Available in modern browsers via `DecompressionStream`. Modern browsers only — no polyfill needed.

### 11.5 Testing Architecture

Two levels: (1) Haskell-driven per-function tests (`tests/XFTPWebTests.hs`) that call each TS function via `node` and compare output with the Haskell equivalent — zero TS test code needed, see §10.1. (2) TS-driven integration tests (`xftp-web/test/integration.test.ts`) that spawn `xftp-server` and `xftp` CLI as subprocesses for full round-trip verification — only attempted after all per-function tests pass, see §10.2.

### 11.6 Memory Management for 100 MB Files

XSalsa20-Poly1305 streaming encryption/decryption is sequential — each 64KB block's state depends on the previous block, and the auth tag is computed/verified at the end. This means both upload and download have the same structure: one sequential crypto pass + one parallel network pass.

**Upload flow:**
1. `File.stream()` → encrypt sequentially (state threading) → buffer encrypted output
2. Compute SHA-512 digest of encrypted data
3. Split into chunks, upload in parallel to 8 randomly selected servers (from 6 default servers in `Presets.hs`)

**Download flow:**
1. Download chunks in parallel from servers → buffer encrypted data
2. Decrypt sequentially (state threading) → verify auth tag
3. Trigger browser save

Both directions buffer ~100 MB of encrypted data. The approach should be symmetric.

**Option A — Memory buffer:** Buffer encrypted data as `ArrayBuffer`. 100 MB peak memory is feasible on modern devices. Simple implementation, no Web Worker needed. Chunk slicing is zero-copy via `ArrayBuffer.slice()`.

**Option B — OPFS ([Origin Private File System](https://developer.mozilla.org/en-US/docs/Web/API/File_System_API/Origin_private_file_system)):** Write encrypted data to OPFS instead of holding in memory. OPFS storage quota is shared with IndexedDB/Cache API — typically hundreds of MB to several GB ([quota details](https://developer.mozilla.org/en-US/docs/Web/API/Storage_API/Storage_quotas_and_eviction_criteria)). The fast synchronous API (`createSyncAccessHandle()`) requires a [Web Worker](https://developer.mozilla.org/en-US/docs/Web/API/FileSystemFileHandle/createSyncAccessHandle) but is [3-4x faster than IndexedDB](https://web.dev/articles/origin-private-file-system). The async API (`createWritable()`) works on the main thread.

**Decision:** Use OPFS with a Web Worker. While 100 MB fits in memory, OPFS future-proofs the implementation for raising the file size limit (250 MB, 500 MB, etc.) without code changes. The Web Worker also keeps the main thread responsive during encryption/decryption. The implementation cost is modest — a single worker that runs the sequential crypto pipeline, reading/writing OPFS files.

### 11.7 Server Page Hosting

Excluded from initial implementation. Added at the very end (Phase 5) as optional feature. Initial deployment serves the page from a separate web host.

### 11.8 File Expiry Communication

Hardcode 48 hours for standalone web page. Server-hosted page can use server-configurable TTL. The page should also display which XFTP servers were used for the upload.

### 11.9 Concurrent Operations

8 parallel operations in the browser. The Haskell CLI uses 16, but browsers have per-origin connection limits (6-8). Since chunks typically go to different servers (different origins), 8 provides good parallelism without hitting browser limits.

## 12. Haskell-to-TypeScript Function Mapping

This section maps every TypeScript module to the Haskell functions it must reimplement. File paths are relative to `src/`. Line numbers reference the current codebase. Each TypeScript function must produce byte-identical output to its Haskell counterpart — this is transpilation, not reimplementation.

### 12.1 `protocol/encoding.ts` ← `Simplex/Messaging/Encoding.hs`

Binary encoding primitives. Every XFTP type's wire format is built from these.

| TypeScript function | Haskell function | Line | Description |
|---|---|---|---|
| `encodeWord16(n)` | `smpEncode :: Word16` | 70 | 2-byte big-endian |
| `decodeWord16(buf)` | `smpP :: Word16` | 70 | Parse 2-byte big-endian |
| `encodeWord32(n)` | `smpEncode :: Word32` | 76 | 4-byte big-endian |
| `decodeWord32(buf)` | `smpP :: Word32` | 76 | Parse 4-byte big-endian |
| `encodeInt64(n)` | `smpEncode :: Int64` | 82 | Two Word32s (high, low) |
| `decodeInt64(buf)` | `smpP :: Int64` | 82 | Parse two Word32s |
| `encodeBytes(bs)` | `smpEncode :: ByteString` | 100 | 1-byte length prefix + bytes |
| `decodeBytes(buf)` | `smpP :: ByteString` | 100 | Parse 1-byte length prefix |
| `encodeLarge(bs)` | `smpEncode :: Large` | 133 | 2-byte length prefix + bytes |
| `decodeLarge(buf)` | `smpP :: Large` | 133 | Parse 2-byte length prefix |
| `encodeTail(bs)` | `smpEncode :: Tail` | 124 | Raw bytes (no prefix) |
| `decodeTail(buf)` | `smpP :: Tail` | 124 | Take all remaining bytes |
| `encodeBool(b)` | `smpEncode :: Bool` | 58 | `'T'` or `'F'` |
| `decodeBool(buf)` | `smpP :: Bool` | 58 | Parse `'T'`/`'F'` |
| `encodeString(s)` | `smpEncode :: String` | 159 | Via ByteString encoding |
| `encodeMaybe(enc, v)` | `smpEncode :: Maybe a` | 114 | `'0'` for Nothing, `'1'` + value for Just |
| `decodeMaybe(dec, buf)` | `smpP :: Maybe a` | 114 | Parse optional value |
| `encodeNonEmpty(enc, xs)` | `smpEncode :: NonEmpty a` | 165 | 1-byte length + elements |
| `decodeNonEmpty(dec, buf)` | `smpP :: NonEmpty a` | 165 | Parse length-prefixed list |

**Tuple encoding:** Tuples are encoded by concatenating encoded fields. Decoded by parsing fields sequentially. Instances at lines 172-212.

### 12.2 `protocol/commands.ts` ← `Simplex/FileTransfer/Protocol.hs`

XFTP commands and their wire encoding.

| TypeScript type/function | Haskell type/function | Line | Description |
|---|---|---|---|
| `FileInfo` | `FileInfo` | 174 | `{sndKey, size :: Word32, digest :: ByteString}` |
| `encodeFNEW(info, rcvKeys, auth)` | `FNEW` encoding | 183 | `smpEncode (FNEW_)` + fields |
| `encodeFADD(rcvKeys)` | `FADD` encoding | 183 | Add recipient keys |
| `encodeFPUT()` | `FPUT` encoding | 183 | Upload marker (no fields) |
| `encodeFDEL()` | `FDEL` encoding | 183 | Delete marker |
| `encodeFGET(dhPubKey)` | `FGET` encoding | 183 | Download with DH key |
| `encodeFACK()` | `FACK` encoding | 183 | Acknowledge marker |
| `encodePING()` | `PING` encoding | 183 | Ping marker |
| `decodeFRSndIds(buf)` | `FRSndIds` parser | 285 | `(SenderId, NonEmpty RecipientId)` |
| `decodeFRRcvIds(buf)` | `FRRcvIds` parser | 285 | `NonEmpty RecipientId` |
| `decodeFRFile(buf)` | `FRFile` parser | 285 | `(RcvPublicDhKey, CbNonce)` |
| `decodeFROk()` | `FROk` parser | 285 | Success |
| `decodeFRErr(buf)` | `FRErr` parser | 285 | Error type |
| `decodeFRPong()` | `FRPong` parser | 285 | Pong |
| `XFTPErrorType` | `XFTPErrorType` | 206 | Error enumeration (Transport.hs) |

**Command tags** (`FileCommandTag`, line 103): Each command is prefixed by its tag string (`"FNEW"`, `"FADD"`, etc.) encoded via `smpEncode`.

### 12.3 `protocol/transmission.ts` ← `Simplex/FileTransfer/Protocol.hs`

Transmission framing: sign, encode, pad to block size.

| TypeScript function | Haskell function | Line | Description |
|---|---|---|---|
| `xftpEncodeAuthTransmission(key, ...)` | `xftpEncodeAuthTransmission` | 340 | Sign + encode + pad to 16384 |
| `xftpDecodeTransmission(buf)` | `xftpDecodeTransmission` | 360 | Parse padded response block |
| `xftpBlockSize` | `xftpBlockSize` | 65 | `16384` constant |

**Wire format:** `<signature> <corrId> <entityId> <encodedCommand>` padded with `#` to 16384 bytes. Signature is Ed25519 over `(sessionId ++ corrId ++ entityId ++ encodedCommand)`.

**Padding:** Uses `Crypto.pad` (`Crypto.hs:1077`) — 2-byte big-endian length prefix + message + `#` (0x23) fill.

### 12.4 `crypto/secretbox.ts` ← `Simplex/Messaging/Crypto.hs` + `Simplex/Messaging/Crypto/Lazy.hs`

Streaming XSalsa20-Poly1305 encryption/decryption.

| TypeScript function | Haskell function | File | Line | Description |
|---|---|---|---|---|
| `sbInit(key, nonce)` | `sbInit` | Crypto/Lazy.hs | 202 | Init `(XSalsa.State, Poly1305.State)` |
| `cbInit(dhSecret, nonce)` | `cbInit` | Crypto/Lazy.hs | 198 | Init from DH secret (transit) |
| `sbEncryptChunk(state, chunk)` | `sbEncryptChunk` | Crypto/Lazy.hs | 229 | XOR + Poly1305 update → `(ciphertext, newState)` |
| `sbDecryptChunk(state, chunk)` | `sbDecryptChunk` | Crypto/Lazy.hs | 235 | XOR + Poly1305 update → `(plaintext, newState)` |
| `sbAuth(state)` | `sbAuth` | Crypto/Lazy.hs | 241 | Finalize → 16-byte auth tag |
| `sbEncryptTailTag(key, nonce, data, len, padLen)` | `sbEncryptTailTag` | Crypto/Lazy.hs | 134 | Full encrypt, tag appended |
| `sbDecryptTailTag(key, nonce, paddedLen, data)` | `sbDecryptTailTag` | Crypto/Lazy.hs | 153 | Full decrypt, verify appended tag |
| `cryptoBox(key, iv, msg)` | `cryptoBox` | Crypto.hs | 1313 | XSalsa20 + Poly1305 (tag prepended) |
| `cbEncrypt(dhSecret, nonce, msg, padLen)` | `cbEncrypt` | Crypto.hs | 1286 | Crypto box with DH secret |
| `cbDecrypt(dhSecret, nonce, msg)` | `cbDecrypt` | Crypto.hs | 1320 | Crypto box decrypt |

**Note:** `cryptoBox`, `cbEncrypt`, and `cbDecrypt` are included for completeness but are **not used by the web XFTP client**. They implement single-shot crypto_box (tag prepended) used for SMP protocol messages. The web client only needs `cbInit` (for transit decryption) and the streaming functions (`sbEncryptChunk`, `sbDecryptChunk`, `sbAuth`, `sbEncryptTailTag`, `sbDecryptTailTag`).

**Internal init (`sbInit_`)** at `Crypto/Lazy.hs:210`:
1. Call `xSalsa20(key, nonce, zeroes_32)` → `(poly1305Key, xsalsaState)`
2. Initialize Poly1305 with `poly1305Key`
3. Return `(xsalsaState, poly1305State)`

The `xSalsa20` function (`Crypto.hs:1467`) uses: `initialize 20 secret (zero8 ++ iv0)`, then `derive state0 iv1`, then `generate state1 32` for keystream, `combine state2 msg` for encryption.

### 12.5 `crypto/keys.ts` ← `Simplex/Messaging/Crypto.hs`

Key generation, signing, DH.

| TypeScript function | Haskell function | Line | Description |
|---|---|---|---|
| `generateEd25519KeyPair()` | `generateAuthKeyPair` | 726 | Ed25519 keypair from CSPRNG |
| `generateX25519KeyPair()` | via `generateKeyPair` | — | X25519 keypair for DH |
| `sign(privateKey, msg)` | `sign'` | 1175 | Ed25519 signature (64 bytes) |
| `verify(publicKey, sig, msg)` | `verify'` | 1270 | Ed25519 verification |
| `dh(pubKey, privKey)` | `dh'` | 1280 | X25519 DH → shared secret |

**Key types:**
- `SbKey` (`Crypto.hs:1411`): 32-byte symmetric key (newtype over ByteString)
- `CbNonce` (`Crypto.hs:1368`): 24-byte nonce (newtype over ByteString)
- `KeyHash` (`Crypto.hs:981`): SHA-256 of certificate public key

### 12.6 `crypto/digest.ts` ← `Simplex/Messaging/Crypto.hs`

Hash functions.

| TypeScript function | Haskell function | Line | Description |
|---|---|---|---|
| `sha256(data)` | `sha256Hash` | 1006 | SHA-256 digest (32 bytes) |
| `sha512(data)` | `sha512Hash` | 1011 | SHA-512 digest (64 bytes) |

### 12.7 `crypto/padding.ts` ← `Simplex/Messaging/Crypto.hs` + `Simplex/Messaging/Crypto/Lazy.hs`

Block padding used for protocol messages and file encryption.

| TypeScript function | Haskell function | File | Line | Description |
|---|---|---|---|---|
| `pad(msg, blockSize)` | `pad` | Crypto.hs | 1077 | 2-byte BE length + msg + `#` fill |
| `unPad(buf)` | `unPad` | Crypto.hs | 1085 | Extract msg from padded block |
| `padLazy(msg, msgLen, padLen)` | `pad` | Crypto/Lazy.hs | 70 | 8-byte Int64 length + msg + `#` fill |
| `unPadLazy(buf)` | `unPad` | Crypto/Lazy.hs | 91 | Extract msg from lazy-padded block |

**Strict pad format (protocol messages):** `[2-byte BE length][message][# # # ...]`
**Lazy pad format (file encryption):** `[8-byte Int64 length][message][# # # ...]`

### 12.8 `crypto/file.ts` ← `Simplex/FileTransfer/Crypto.hs`

File-level encryption/decryption orchestrating the streaming primitives.

| TypeScript function | Haskell function | Line | Description |
|---|---|---|---|
| `encryptFile(source, header, key, nonce, fileSize, padSize, dest)` | `encryptFile` | 30 | Stream-encrypt file with header, 64KB chunks, appended auth tag |
| `decryptChunks(paddedSize, chunks, key, nonce)` | `decryptChunks` | 57 | Decrypt concatenated chunks, verify auth tag, extract header |
| `readChunks(paths)` | `readChunks` | 113 | Concatenate chunk files |

**`encryptFile` algorithm** (lines 30-42):
1. Init state: `sbInit(key, nonce)`
2. Encrypt header: `sbEncryptChunk(state, smpEncode(fileSize') <> headerBytes)` — `fileSize'` = headerLen + originalFileSize; `smpEncode(fileSize')` produces the 8-byte Int64 length prefix, which is concatenated with `headerBytes` and encrypted together as one piece
3. Encrypt file data in 65536-byte chunks: `sbEncryptChunk(state, chunk)` → thread state through each chunk
4. Encrypt padding in 65536-byte chunks: same chunked loop as step 3 using `'#'` fill. `padLen = encSize - authTagSize - fileSize' - 8`
5. Finalize: `sbAuth(state)` → append 16-byte auth tag

Note: `encryptFile` does NOT use `padLazy` or `sbEncryptTailTag`. It manually prepends the length, encrypts header+data+padding as separate chunk sequences, and appends the auth tag. The `sbEncryptTailTag` function (which does use `padLazy`) is used elsewhere but not by `encryptFile`.

**`decryptChunks` algorithm** (lines 57-111) — two paths:

**Single chunk (one file, line 60):** Calls `sbDecryptTailTag(key, nonce, encSize - authTagSize, data)` directly. This internally decrypts, verifies auth tag, and strips the 8-byte length prefix + padding via `unPad`. Returns `(authOk, content)`. Then parses `FileHeader` from content.

**Multi-chunk (line 67):**
1. `sbInit(key, nonce)` → init state
2. Decrypt first chunk file: `sbDecryptChunkLazy(state, chunk)` → `splitLen` extracts 8-byte `expectedLen` → parse `FileHeader`
3. Decrypt middle chunk files: `sbDecryptChunkLazy(state, chunk)` loop, write to output, accumulate `len`
4. Decrypt last chunk file: split off last 16 bytes as auth tag → `sbDecryptChunkLazy(state, remaining)` → truncate padding using `expectedLen` vs accumulated `len` → verify `sbAuth(finalState) == authTag`

**`FileHeader`** (`Types.hs:35`): `{fileName :: String, fileExtra :: Maybe String}`, parsed via `smpP`.

### 12.9 `transport/handshake.ts` ← `Simplex/FileTransfer/Transport.hs`

XFTP handshake types and encoding.

| TypeScript type/function | Haskell type/function | Line | Description |
|---|---|---|---|
| `XFTPServerHandshake` | `XFTPServerHandshake` | 114 | `{xftpVersionRange, sessionId, authPubKey}` |
| `encodeServerHandshake(hs)` | `smpEncode :: XFTPServerHandshake` | 136 | Binary encode |
| `decodeServerHandshake(buf)` | `smpP :: XFTPServerHandshake` | 136 | Parse with `Tail _compat` (line 142) |
| `XFTPClientHandshake` | `XFTPClientHandshake` | 121 | `{xftpVersion, keyHash}` |
| `encodeClientHandshake(hs)` | `smpEncode :: XFTPClientHandshake` | 128 | Binary encode |
| `decodeClientHandshake(buf)` | `smpP :: XFTPClientHandshake` | 128 | Parse with `Tail _compat` (line 133) |
| `XFTP_VERSION_RANGE` | `supportedFileServerVRange` | 101 | Version 1..3 |
| `CURRENT_XFTP_VERSION` | `currentXFTPVersion` | 98 | Version 3 |

### 12.10 `transport/client.ts` ← `Simplex/FileTransfer/Client.hs`

HTTP/2 client, command sending, chunk upload/download.

| TypeScript function | Haskell function | Line | Description |
|---|---|---|---|
| `connectXFTP(server, config)` | `getXFTPClient` | 111 | Establish HTTP/2 connection + handshake |
| `xftpHandshakeV1(vRange, keyHash, http2)` | `xftpClientHandshakeV1` | 137 | Two-stage handshake over HTTP/2 |
| `sendCommand(client, key, fileId, cmd, chunk?)` | `sendXFTPCommand` | 199 | Encode + sign + send + parse response |
| `createChunk(client, key, info, rcvKeys, auth?)` | `createXFTPChunk` | 231 | FNEW → (senderId, recipientIds) |
| `addRecipients(client, key, fileId, rcvKeys)` | `addXFTPRecipients` | 243 | FADD → recipientIds |
| `uploadChunk(client, key, fileId, spec)` | `uploadXFTPChunk` | 249 | FPUT with streaming body |
| `downloadChunk(rng, client, key, fileId, spec)` | `downloadXFTPChunk` | 253 | FGET → transit-decrypt → save |
| `deleteChunk(client, key, senderId)` | `deleteXFTPChunk` | 285 | FDEL |
| `ackChunk(client, key, recipientId)` | `ackXFTPChunk` | 288 | FACK |
| `ping(client)` | `pingXFTP` | 291 | PING → PONG |

### 12.11 `agent/chunking.ts` ← `Simplex/FileTransfer/Client.hs` + `Simplex/FileTransfer/Chunks.hs`

Chunk size selection and file splitting.

| TypeScript function/constant | Haskell function/constant | File | Line | Description |
|---|---|---|---|---|
| `CHUNK_SIZE_64K` | `chunkSize0` | Chunks.hs | 9 | 65536 |
| `CHUNK_SIZE_256K` | `chunkSize1` | Chunks.hs | 13 | 262144 |
| `CHUNK_SIZE_1M` | `chunkSize2` | Chunks.hs | 17 | 1048576 |
| `CHUNK_SIZE_4M` | `chunkSize3` | Chunks.hs | 21 | 4194304 |
| `SERVER_CHUNK_SIZES` | `serverChunkSizes` | Chunks.hs | 5 | `[64K, 256K, 1M, 4M]` |
| `singleChunkSize(fileSize)` | `singleChunkSize` | Client.hs | 315 | Smallest chunk size ≥ fileSize, or Nothing |
| `prepareChunkSizes(fileSize)` | `prepareChunkSizes` | Client.hs | 321 | Split file into chunk sizes |
| `prepareChunkSpecs(path, sizes)` | `prepareChunkSpecs` | Client.hs | 338 | Create offset-based chunk specs |
| `getChunkDigest(spec)` | `getChunkDigest` | Client.hs | 346 | SHA-256 of chunk data |

### 12.12 `description/types.ts` ← `Simplex/FileTransfer/Description.hs`

File description types matching the YAML format.

| TypeScript type | Haskell type | Line | Description |
|---|---|---|---|
| `FileDescription` | `FileDescription p` | 81 | `{party, size, digest, key, nonce, chunkSize, chunks, redirect?}` |
| `RedirectFileInfo` | `RedirectFileInfo` | 93 | `{size, digest}` |
| `FileDigest` | `FileDigest` | 114 | Newtype over ByteString (base64url encoded in YAML via `StrEncoding`) |
| `FileSize` | `FileSize a` | 186 | Newtype wrapper; human-readable `StrEncoding` ("26mb", "8mb", "100kb", "1gb") |
| `FileChunk` | `FileChunk` | 132 | `{chunkNo, chunkSize, digest, replicas}` |
| `FileChunkReplica` | `FileChunkReplica` | 140 | `{server, replicaId, replicaKey}` |
| `ChunkReplicaId` | `ChunkReplicaId` | 147 | Newtype over XFTPFileId |
| `FileDescriptionURI` | `FileDescriptionURI` | 243 | `{scheme, description, clientData?}` — Haskell format (`simplex:/file#/?desc=...`); web client uses different URL format (§4.1) |

**Size constants:**
- `qrSizeLimit` (line 269): 1002 bytes
- `maxFileSize` (line 273): 1 GB
- `fileSizeLen` (line 283): 8 bytes

### 12.13 `description/yaml.ts` ← `Simplex/FileTransfer/Description.hs`

YAML serialization via `Data.Yaml` (aeson) through intermediate `YAMLFileDescription` type (line 158).

| TypeScript function | Haskell function | Line | Description |
|---|---|---|---|
| `encodeFileDescription(desc)` | `encodeFileDescription` | 230 | `FileDescription` → `YAMLFileDescription` → YAML bytes |
| `decodeFileDescription(yaml)` | `strDecode` instance | — | YAML bytes → `YAMLFileDescription` → `FileDescription` |
| `fileDescriptionURI(desc)` | `fileDescriptionURI` | 252 | Wrap in URI format |

**Intermediate YAML types:**
- `YAMLFileDescription` (line 158): `{party, size :: String, digest, key, nonce, chunkSize :: String, replicas :: [YAMLServerReplicas], redirect :: Maybe RedirectFileInfo}` — `size` and `chunkSize` use human-readable `StrEncoding` format.
- `YAMLServerReplicas` (line 170): `{server :: XFTPServer, chunks :: [String]}` — replicas grouped by server.
- Binary fields (`digest`, `key`, `nonce`) are base64url-encoded via `StrEncoding` / `strToJSON`.
- Chunk replica string format: `chunkNo:replicaId:replicaKey[:digest][:chunkSize]`

### 12.14 `description/validation.ts` ← `Simplex/FileTransfer/Description.hs`

| TypeScript function | Haskell function | Line | Description |
|---|---|---|---|
| `validateFileDescription(desc)` | `validateFileDescription` | 221 | Check sequential chunk numbers and total size match |

### 12.15 `agent/upload.ts` ← `Simplex/FileTransfer/Client/Main.hs`

Upload orchestration — the top-level flow.

| TypeScript function | Haskell function | Line | Description |
|---|---|---|---|
| `encryptFileForUpload(file)` | `encryptFileForUpload` | 264 | Generate key/nonce, encrypt, compute digest, split |
| `uploadFile(chunks, servers)` | `uploadFile` | 285 | Parallel upload (8 concurrent) |
| `uploadFileChunk(agent, chunk, server)` | `uploadFileChunk` | 301 | FNEW + FPUT for one chunk |
| `createRcvFileDescriptions(desc, sentChunks)` | `createRcvFileDescriptions` | 329 | Build recipient descriptions |

**Upload call sequence** (`cliSendFileOpts`, line 243):
1. `encryptFileForUpload` (line 264) — `C.randomSbKey` + `C.randomCbNonce` → `encryptFile` → `sha512Hash` digest → `prepareChunkSpecs`
2. `uploadFile` (line 285) — `pooledForConcurrentlyN 16 chunks uploadFileChunk`
3. `uploadFileChunk` (line 301) — `getChunkDigest` (line 306) → `createXFTPChunk` → `uploadXFTPChunk`
4. `createRcvFileDescriptions` (line 329) — assembles `FileDescription 'FRecipient` from sent chunks
5. `writeFileDescriptions` (line 376) — serializes to YAML files

### 12.16 `agent/download.ts` ← `Simplex/FileTransfer/Client/Main.hs`

Download orchestration — the top-level flow.

| TypeScript function | Haskell function | Line | Description |
|---|---|---|---|
| `downloadFile(description)` | `cliReceiveFile` | 388 | Full download flow |
| `downloadFileChunk(rng, agent, path, size, chunk)` | `downloadFileChunk` | 418 | FGET + transit-decrypt one chunk |
| `ackFileChunk(agent, chunk)` | `acknowledgeFileChunk` | 440 | FACK one chunk |

**Download call sequence** (`cliReceiveFile`, line 388):
1. Parse and validate `FileDescription` from YAML
2. Group chunks by server: `groupAllOn srv chunks` (line 402, local `srv` helper extracts first replica's server)
3. Parallel download: `pooledForConcurrentlyN 16 srvChunks downloadFileChunk`
4. `downloadFileChunk` (line 418) — calls `downloadXFTPChunk` (`Client.hs:253`) which does FGET → DH → transit-decrypt
5. `readChunks` (`Crypto.hs:113`) — concatenate chunk files
6. Verify file digest (SHA-512)
7. `decryptChunks` (`Crypto.hs:57`) — file-level decrypt with auth tag verification
8. Parallel acknowledge: `acknowledgeFileChunk` → `ackXFTPChunk`

### 12.17 Transit Encryption Detail ← `Simplex/FileTransfer/Client.hs:253-275`

`downloadXFTPChunk` performs transit decryption after FGET:

1. Generate ephemeral X25519 keypair
2. Send `FGET(rcvDhPubKey)` → receive `FRFile(sndDhPubKey, cbNonce)` + encrypted body
3. Compute DH shared secret: `dh'(sndDhPubKey, rcvDhPrivKey)` (`Crypto.hs:1280`)
4. Transit-decrypt body via `receiveSbFile` (`Transport.hs:176`): `cbInit(dhSecret, cbNonce)` → `sbDecryptChunk` loop (`fileBlockSize` = 16384-byte blocks, `Transport/HTTP2/File.hs:14`) → `sbAuth` tag verification at end
5. Verify chunk digest (SHA-256): `getChunkDigest` (`Client.hs:346`)

### 12.18 Per-Function Testing: Haskell Drives Node

**Mechanism:** Haskell test file (`tests/XFTPWebTests.hs`) imports the real Haskell library functions, calls each one, then calls the corresponding TypeScript function via `node`, and asserts byte-identical output. See §10.1 for the `callTS` helper and example test cases.

**Each row in the tables in §12.1–12.17 is one test case.** The function mapping tables serve as the exhaustive test case list. For example, §12.1 has 19 encoding functions → 19 Haskell test cases. §12.4 has 10 crypto functions → 10 test cases. Total: ~100 per-function test cases across all modules.

**TS function contract:** Each TypeScript function exported from a module must accept a `Buffer` of serialized input arguments and return a `Buffer` of serialized output. The serialization format is simple concatenation of the same binary encoding used by the protocol (using the encoding primitives from §12.1). This means the TS functions can be called both from production code (with native types) and from the Haskell test harness (with raw buffers). A thin wrapper per module handles deserialization.

**Stateful functions (streaming crypto):** `XSalsa.State` and `Poly1305.State` are opaque types in the crypton library — they cannot be serialized to bytes. Therefore `sbEncryptChunk` / `sbDecryptChunk` cannot be tested individually across the Haskell↔TS boundary. Instead, test the composite operations:
- `sbEncryptTailTag(key, nonce, data, len, padLen)` — Haskell encrypts, TS encrypts same input, compare ciphertext + tag.
- `sbDecryptTailTag(key, nonce, paddedLen, ciphertext)` — Haskell decrypts, TS decrypts, compare plaintext.
- Round-trip: Haskell encrypts → TS decrypts (and vice versa) → compare content.
- Multi-chunk: Haskell runs `sbInit` + N × `sbEncryptChunk` + `sbAuth` as one sequence, TS does the same, compare final ciphertext and tag. The `callTS` script runs the full sequence in one node invocation.

**Development workflow:**
1. Implement `encodeWord16` in `src/protocol/encoding.ts`
2. Run `cabal test --test-option=--match="/XFTP Web Client/encoding/encodeWord16"`
3. If it fails: Haskell says `expected 002a, got 2a00` → immediately know it's an endianness bug
4. Fix → rerun → passes → move to `encodeWord32`
5. Repeat until all per-function tests pass
6. Then attempt integration tests (§10.2) — by this point, every building block is verified

**Integration tests** (separate, TS-driven via Node.js spawning `xftp-server`):
1. Node.js test spawns `xftp-server` binary as subprocess.
2. TypeScript client connects, uploads file, gets description.
3. Haskell `xftp` CLI (spawned as subprocess) downloads and verifies content.
4. Reverse: Haskell CLI uploads, TypeScript downloads and verifies.
5. Round-trip: TypeScript uploads → TypeScript downloads → verify.

### 12.19 Project Structure Summary

**TypeScript project (`xftp-web/`):**
```
xftp-web/                          # Separate npm project
├── src/
│   ├── protocol/
│   │   ├── encoding.ts            # ← Simplex.Messaging.Encoding
│   │   ├── commands.ts            # ← Simplex.FileTransfer.Protocol (commands)
│   │   ├── responses.ts           # ← Simplex.FileTransfer.Protocol (responses)
│   │   └── transmission.ts        # ← Simplex.FileTransfer.Protocol (framing)
│   ├── crypto/
│   │   ├── secretbox.ts           # ← Simplex.Messaging.Crypto + Crypto.Lazy
│   │   ├── file.ts                # ← Simplex.FileTransfer.Crypto
│   │   ├── keys.ts                # ← Simplex.Messaging.Crypto (keys, sign, DH)
│   │   ├── digest.ts              # ← Simplex.Messaging.Crypto (sha256, sha512)
│   │   └── padding.ts             # ← Simplex.Messaging.Crypto (pad/unPad)
│   ├── transport/
│   │   ├── client.ts              # ← Simplex.FileTransfer.Client
│   │   ├── handshake.ts           # ← Simplex.FileTransfer.Transport
│   │   └── cors.ts                # CORS-aware request handling
│   ├── description/
│   │   ├── types.ts               # ← Simplex.FileTransfer.Description (types)
│   │   ├── yaml.ts                # ← Simplex.FileTransfer.Description (encoding)
│   │   ├── uri.ts                 # ← URL encoding/decoding with compression (§4.1)
│   │   └── validation.ts          # ← Simplex.FileTransfer.Description (validation)
│   ├── agent/
│   │   ├── upload.ts              # ← Simplex.FileTransfer.Client.Main (upload)
│   │   ├── download.ts            # ← Simplex.FileTransfer.Client.Main (download)
│   │   └── chunking.ts            # ← Simplex.FileTransfer.Client + Chunks
│   └── index.ts                   # Public API
├── test/
│   └── integration.test.ts        # TS-driven: spawns xftp-server, full round-trips
├── web/                           # Browser UI (Phase 4)
│   ├── index.html
│   ├── upload.ts
│   ├── download.ts
│   └── progress.ts                # Circular progress component
├── package.json
└── tsconfig.json
```

**Haskell per-function tests (in simplexmq repo):**
```
tests/
└── XFTPWebTests.hs               # Haskell-driven: calls each TS function via node,
                                   # compares output with Haskell function (see §10.1)
                                   # ~100 test cases, one per row in §12.1–12.17 tables
```

No fixture files, no TS test harness for unit tests. The Haskell test file IS the test — it calls both Haskell and TypeScript functions directly and compares outputs. TS-side integration tests (`test/integration.test.ts`) are separate and only run after all per-function tests pass.
