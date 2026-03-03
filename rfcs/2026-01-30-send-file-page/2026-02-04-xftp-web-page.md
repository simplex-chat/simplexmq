# Send File Web Page — Implementation Plan

## TOC
1. Executive Summary
2. Architecture
3. CryptoBackend & Web Worker
4. Server Configuration
5. Page Structure & UI
6. Upload Flow
7. Download Flow
8. Build & Dev Setup
9. agent.ts Changes
10. Testing
11. Files
12. Implementation Order

## 1. Executive Summary

Build a static web page for browser-based XFTP file transfer (Phase 5 of master RFC). The page supports upload (drag-drop → encrypt → upload → shareable link) and download (open link → download → decrypt → save). Crypto runs in a Web Worker; large files use OPFS temp storage.

Two build variants:
- **Local**: single test server at `localhost:7000` (development/testing)
- **Production**: 12 preset XFTP servers (6 SimpleX + 6 Flux)

Uses Vite for bundling (already a dependency via vitest). No CSS framework — plain CSS per RFC spec.

## 2. Architecture

```
xftp-web/
├── src/                        # Library (existing, targeted changes)
│   ├── agent.ts                # Modified: uploadFile readChunk, downloadFileRaw
│   ├── client.ts               # Modified: downloadXFTPChunkRaw
│   ├── crypto/                 # Unchanged
│   ├── download.ts             # Unchanged
│   └── protocol/
│       └── description.ts      # Fix: SHA-256 → SHA-512 comment on digest field
├── web/                        # Web page (new)
│   ├── index.html              # Entry point (CSP meta tag)
│   ├── main.ts                 # Router + sodium.ready init
│   ├── upload.ts               # Upload UI + orchestration
│   ├── download.ts             # Download UI + orchestration
│   ├── progress.ts             # Circular progress canvas component
│   ├── servers.ts              # Server list (build-time configured, imports servers.json)
│   ├── servers.json            # Preset server addresses (shared with vite.config.ts)
│   ├── crypto-backend.ts       # CryptoBackend interface + WorkerBackend
│   ├── crypto.worker.ts        # Web Worker: encrypt/decrypt/OPFS
│   └── style.css               # Minimal styling
├── vite.config.ts              # Page build config (new)
├── tsconfig.web.json           # IDE/CI type-check for web/ (new)
├── tsconfig.worker.json        # IDE/CI type-check for worker (new)
├── playwright.config.ts        # Page E2E test config (new)
├── vitest.config.ts            # Test config (existing)
├── .gitignore                  # Existing (add dist-web/)
└── test/                       # Tests (existing + new page test)
```

Data flow:

```
                  ┌───────────────────────────────────────────┐
                  │ Main Thread                                 │
                  │                                             │
                  │  Upload:  upload.ts ──► agent.ts ──► fetch()│
                  │  Download: download.ts ──► agent.ts ──► fetch()
                  │         │                                   │
                  │    postMessage                        HTTP/2 │
                  │         ▼                                   ▼
                  │ ┌─────────────────┐             ┌──────────┐│
                  │ │ Web Worker       │             │ XFTP     ││
                  │ │ crypto.worker.ts │             │ Server   ││
                  │ │ ┌─────────────┐ │             └──────────┘│
                  │ │ │ OPFS temp   │ │                         │
                  │ │ └─────────────┘ │                         │
                  │ └─────────────────┘                         │
                  └───────────────────────────────────────────┘
```

Both upload and download use `agent.ts` for orchestration (connection pooling, parallel chunk transfers, redirect handling). Upload uses a `readChunk` callback for Worker data access. Download uses an `onRawChunk` callback to route raw encrypted chunks to the Worker for decryption (see §7.2). ACK is the caller's responsibility — `downloadFileRaw` returns the resolved `FileDescription` without ACKing, so the caller can verify integrity before acknowledging.

## 3. CryptoBackend & Web Worker

### 3.1 Interface

```typescript
// crypto-backend.ts
export interface CryptoBackend {
  // Upload: encrypt file, store encrypted data in OPFS
  encrypt(data: Uint8Array, fileName: string,
          onProgress?: (done: number, total: number) => void
  ): Promise<EncryptResult>

  // Upload: read encrypted chunk from OPFS (called by agent.ts via readChunk callback)
  readChunk(offset: number, size: number): Promise<Uint8Array>

  // Download: transit-decrypt raw chunk and store in OPFS
  decryptAndStoreChunk(
    dhSecret: Uint8Array, nonce: Uint8Array,
    body: Uint8Array, digest: Uint8Array, chunkNo: number
  ): Promise<void>

  // Download: verify digest + file-level decrypt all stored chunks
  // Only needs size/digest/key/nonce — not the full FileDescription (avoids sending private keys to Worker)
  verifyAndDecrypt(params: {size: number, digest: Uint8Array, key: Uint8Array, nonce: Uint8Array}
  ): Promise<{header: FileHeader, content: Uint8Array}>

  cleanup(): Promise<void>
}

// Structurally identical to EncryptedFileMetadata from agent.ts (§9.1).
// Kept separate to avoid crypto-backend.ts importing from agent.ts
// (which would pull in node:http2 via client.ts, breaking Worker bundling).
// TypeScript structural typing makes them assignment-compatible.
export interface EncryptResult {
  digest: Uint8Array
  key: Uint8Array
  nonce: Uint8Array
  chunkSizes: number[]
}
```

### 3.2 Factory

```typescript
export function createCryptoBackend(): CryptoBackend {
  if (typeof Worker === 'undefined') {
    throw new Error('Web Workers required — update your browser')
  }
  return new WorkerBackend()
}
```

The Worker always uses OPFS for temp storage (single code path — no memory/disk branching). OPFS I/O overhead is negligible relative to crypto and network time. Each Worker session creates a unique directory in OPFS root named `session-<Date.now()>-<crypto.randomUUID()>`, containing `upload.bin` and `download.bin` as needed. `cleanup()` deletes the entire session directory. On Worker startup (before processing messages), sweep OPFS root and delete any `session-*` directories whose embedded timestamp (parsed from the name) is older than 1 hour — this handles stale files from crashed tabs. The OPFS API does not expose directory timestamps, so the name-encoded timestamp is the only reliable mechanism. This prevents cross-tab collisions and unbounded OPFS growth.

### 3.3 Worker message protocol

Every request carries a numeric `id`. Responses carry the same `id`. WorkerBackend maintains a `Map<number, {resolve, reject}>` to match responses to pending promises.

Main → Worker (fields marked `†` are Transferable — arrive as `ArrayBuffer` in Worker, must be wrapped with `new Uint8Array(...)` before use):
- `{id: number, type: 'encrypt', data†: ArrayBuffer, fileName: string}` — encrypt file, store in OPFS
- `{id: number, type: 'readChunk', offset: number, size: number}` — read encrypted chunk from OPFS
- `{id: number, type: 'decryptAndStoreChunk', dhSecret: Uint8Array, nonce: Uint8Array, body†: ArrayBuffer, chunkDigest: Uint8Array, chunkNo: number}` — transit-decrypt + store in OPFS. `chunkDigest` is the per-chunk SHA-256 digest (verified by `decryptReceivedChunk`). Distinct from the file-level SHA-512 digest in `verifyAndDecrypt`.
- `{id: number, type: 'verifyAndDecrypt', size: number, digest: Uint8Array, key: Uint8Array, nonce: Uint8Array}` — verify digest + file-level decrypt all chunks. Only the four fields needed for verification/decryption are sent — not the full `FileDescription`, which contains private replica keys that the Worker doesn't need.
- `{id: number, type: 'cleanup'}` — delete OPFS temp files

Worker → Main (fields marked `†` are Transferable):
- `{id: number, type: 'progress', done: number, total: number}` — encryption/decryption progress (fire-and-forget, no promise)
- `{id: number, type: 'encrypted', digest: Uint8Array, key: Uint8Array, nonce: Uint8Array, chunkSizes: number[]}` — all fields structured-cloned (not transferred)
- `{id: number, type: 'chunk', data†: ArrayBuffer}` — readChunk response
- `{id: number, type: 'stored'}` — decryptAndStore acknowledgment
- `{id: number, type: 'decrypted', header: FileHeader, content†: ArrayBuffer}` — verifyAndDecrypt response
- `{id: number, type: 'cleaned'}`
- `{id: number, type: 'error', message: string}` — rejects the pending promise for this `id`

All messages carrying large `ArrayBuffer` payloads use `postMessage(msg, [transferables])` to transfer ownership instead of structured-clone copying. Only `ArrayBuffer` can be transferred — `Uint8Array`, `number[]`, and other types are always structured-cloned. This applies to: `encrypt` request (`data`), `readChunk` response (`data`), `decryptAndStoreChunk` request (`body`), and `verifyAndDecrypt` response (`content`). The `WorkerBackend` implementation must ensure the transferred `ArrayBuffer` covers the full `Uint8Array` — if `byteOffset !== 0` or `byteLength !== buffer.byteLength`, slice first: `data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength)`. This is required for `decryptAndStore` request bodies: `sendXFTPCommand` returns `body = fullResp.subarray(XFTP_BLOCK_SIZE)`, which has `byteOffset = XFTP_BLOCK_SIZE`. Other payloads are full-buffer views (§6 step 3 creates `new Uint8Array(await file.arrayBuffer())`; Worker responses allocate fresh buffers) but `WorkerBackend` should guard unconditionally.

### 3.4 Worker internals

**Imports:** The Worker imports directly from `libsodium-wrappers-sumo` (for `await sodium.ready`), `src/crypto/file.js` (`encryptFile`, `encodeFileHeader`, `decryptChunks`), `src/crypto/digest.js` (`sha512`), `src/protocol/chunks.js` (`prepareChunkSizes`, `fileSizeLen`, `authTagSize`), `src/protocol/encoding.js` (`concatBytes`), and `src/download.js` (`decryptReceivedChunk`). `download.js` directly imports `src/protocol/client.js` (for `decryptTransportChunk`). These transitively pull in `src/crypto/secretbox.js`, `src/crypto/keys.js`, and `src/crypto/padding.js`. None of these import `src/agent.ts` or `src/client.ts` — those pull in `node:http2` via dynamic import which would break Worker bundling. Vite tree-shakes the transitive deps automatically. Note: `download.js` → `protocol/client.js` → `crypto/keys.js` transitively pulls in `@noble/curves` (~50-80KB). This is unavoidable since `decryptTransportChunk` needs `dh` from `keys.js`. If Worker bundle size becomes a concern, `decryptReceivedChunk` could be refactored out of `download.js` into a separate module that doesn't import `protocol/client.js`.

**ArrayBuffer → Uint8Array conversion:** All Transferable fields arrive in the Worker as `ArrayBuffer`. The Worker's message handler must wrap them before passing to library functions: `new Uint8Array(msg.data)` for encrypt, `new Uint8Array(msg.body)` for decryptAndStore. Non-transferred fields (`dhSecret`, `nonce`, `digest`, `chunkSizes`) arrive as their original types (`Uint8Array` / `number[]`) via structured clone.

The Worker's encrypt handler calls the same functions as `encryptFileForUpload` in agent.ts (key/nonce generation → `encryptFile` → `sha512` → `prepareChunkSizes`). This is not reimplementation — it's calling the same library functions from a different entry point.

**Libsodium init:** Both the Worker and the main thread must `await sodium.ready` before calling any crypto functions that use libsodium. The Worker does this once on startup before processing messages. The main thread needs it before `connectXFTP` (which uses libsodium via `verifyIdentityProof`) and before `downloadXFTPChunkRaw` (which uses libsodium via `generateX25519KeyPair` + `dh`). In practice, `main.ts` calls `await sodium.ready` at page load, before any XFTP calls.

Encrypt (mirrors `encryptFileForUpload` in agent.ts):
1. Generate key (32B) + nonce (24B) via `crypto.getRandomValues`
2. `fileHdr = encodeFileHeader({fileName, fileExtra: null})`
3. `fileSize = BigInt(fileHdr.length + source.length)`
4. `payloadSize = Number(fileSize) + fileSizeLen + authTagSize`
5. `chunkSizes = prepareChunkSizes(payloadSize)`
6. `encSize = BigInt(chunkSizes.reduce((a, b) => a + b, 0))`
7. `encData = encryptFile(source, fileHdr, key, nonce, fileSize, encSize)`
8. `digest = sha512(encData)` — note: the `digest` field comment in `FileDescription` in `description.ts` says "SHA-256" but the actual hash is SHA-512 everywhere (`sha512` in agent.ts and download.ts). Fix the comment during implementation.
9. Open OPFS upload file via `createSyncAccessHandle`, write `encData`, flush, close handle. Null out `encData` reference.
10. Reopen the same OPFS file with `createSyncAccessHandle` as a persistent read handle (stored on the Worker module scope). This handle is used by all subsequent `readChunk` calls and closed on `cleanup`.
11. Post back `{digest, key, nonce, chunkSizes}` (no encData transfer — data stays in OPFS)

readChunk:
- Use the persistent read handle: `handle.read(buf, {at: offset})` → return slice as transferable ArrayBuffer. OPFS allows only one `FileSystemSyncAccessHandle` per file; the persistent handle avoids per-call open/close overhead.

decryptAndStoreChunk (removes transport encryption only — stored data is still file-level encrypted):
1. `decryptReceivedChunk(dhSecret, nonce, new Uint8Array(body), chunkDigest)` → transit-decrypted chunk data (still file-level encrypted — only the transport layer is removed). Argument order matches signature `(dhSecret, cbNonce, encData, expectedDigest)` from download.ts. `body` arrives as `ArrayBuffer` via Transferable and must be wrapped; `dhSecret`, `nonce`, `chunkDigest` arrive as `Uint8Array` via structured clone.
2. On first call, open the OPFS download temp file via `createSyncAccessHandle` and store as a persistent write handle. Record `{chunkNo, size: decrypted.length}` in an in-memory `chunkMeta: Map<number, {offset: number, size: number}>` — offset is the running sum of sizes for chunks stored so far (chunks may arrive out of order with `concurrency > 1`, so offset is assigned as `currentFileOffset`, then `currentFileOffset += size`)
3. Write decrypted chunk to the persistent handle at the recorded offset

verifyAndDecrypt (mirrors size/digest checks in agent.ts `downloadFile`):
1. Close the persistent download write handle (flush first), then reopen as a read handle. Read each chunk from OPFS into a `Uint8Array[]` array, ordered by `chunkNo`: for each entry in `chunkMeta` sorted by `chunkNo`, `handle.read(buf, {at: offset})` with the recorded offset and size
2. Concatenate for verification: `combined = concatBytes(...chunks)`
3. Verify total size: `combined.length === params.size`
4. Verify SHA-512 digest: `sha512(combined)` matches `params.digest`
5. Decrypt: `decryptChunks(BigInt(params.size), chunks, params.key, params.nonce)` — `params.size` is the encrypted file size (`fd.size` = `sum(chunkSizes)` = `decryptChunks`' first param `encSize`). Called directly instead of via `processDownloadedFile` (which expects a full `FileDescription`). Pass the original `chunks` array (not `combined`), as `decryptChunks` handles concatenation internally.
6. Delete OPFS download temp file
7. Return `{header, content}` via transferable ArrayBuffer

### 3.5 Browser requirements

The page requires a modern browser with Web Worker and OPFS support:
- Chrome 102+, Firefox 114+, Safari 15.2+ (Workers + OPFS + ES module Workers — Firefox added module Worker support in 114)
- If Worker or OPFS is unavailable, the page shows an error message rather than falling back silently.

No `DirectBackend` is needed — the page is browser-only, and tests run in vitest browser mode (real Chromium). The existing library tests (`test/browser.test.ts`) test the crypto/upload/download pipeline directly without Workers.

## 4. Server Configuration

### 4.1 Server lists

`web/servers.json` — single source of truth for preset server addresses (imported by both `servers.ts` and `vite.config.ts`):

```json
{
  "simplex": [
    "xftp://da1aH3nOT-9G8lV7bWamhxpDYdJ1xmW7j3JpGaDR5Ug=@xftp1.simplex.im",
    "xftp://5vog2Imy1ExJB_7zDZrkV1KDWi96jYFyy9CL6fndBVw=@xftp2.simplex.im",
    "xftp://PYa32DdYNFWi0uZZOprWQoQpIk5qyjRJ3EF7bVpbsn8=@xftp3.simplex.im",
    "xftp://k_GgQl40UZVV0Y4BX9ZTyMVqX5ZewcLW0waQIl7AYDE=@xftp4.simplex.im",
    "xftp://-bIo6o8wuVc4wpZkZD3tH-rCeYaeER_0lz1ffQcSJDs=@xftp5.simplex.im",
    "xftp://6nSvtY9pJn6PXWTAIMNl95E1Kk1vD7FM2TeOA64CFLg=@xftp6.simplex.im"
  ],
  "flux": [
    "xftp://92Sctlc09vHl_nAqF2min88zKyjdYJ9mgxRCJns5K2U=@xftp1.simplexonflux.com",
    "xftp://YBXy4f5zU1CEhnbbCzVWTNVNsaETcAGmYqGNxHntiE8=@xftp2.simplexonflux.com",
    "xftp://ARQO74ZSvv2OrulRF3CdgwPz_AMy27r0phtLSq5b664=@xftp3.simplexonflux.com",
    "xftp://ub2jmAa9U0uQCy90O-fSUNaYCj6sdhl49Jh3VpNXP58=@xftp4.simplexonflux.com",
    "xftp://Rh19D5e4Eez37DEE9hAlXDB3gZa1BdFYJTPgJWPO9OI=@xftp5.simplexonflux.com",
    "xftp://0AznwoyfX8Od9T_acp1QeeKtxUi676IBIiQjXVwbdyU=@xftp6.simplexonflux.com"
  ]
}
```

`web/servers.ts`:

```typescript
import {parseXFTPServer, type XFTPServer} from '../src/protocol/address.js'
import presets from './servers.json'

declare const __XFTP_SERVERS__: string[]

const serverAddresses: string[] = typeof __XFTP_SERVERS__ !== 'undefined'
  ? __XFTP_SERVERS__
  : [...presets.simplex, ...presets.flux]

export function getServers(): XFTPServer[] {
  return serverAddresses.map(parseXFTPServer)
}

export function pickRandomServer(servers: XFTPServer[]): XFTPServer {
  return servers[Math.floor(Math.random() * servers.length)]
}
```

### 4.2 Build-time injection

`vite.config.ts` defines `__XFTP_SERVERS__`:
- `mode === 'local'`: `["xftp://<test-fingerprint>@localhost:7000"]`
- `mode === 'production'`: not defined → falls through to hardcoded list

### 4.3 Assumption

Production XFTP servers must have `[WEB]` section configured with a CA-signed certificate for browser TLS. Without this, browsers will reject the self-signed XFTP identity cert. The local test server uses `tests/fixtures/` certs which Chromium accepts via `ignoreHTTPSErrors`.

## 5. Page Structure & UI

### 5.1 Routing

`main.ts` checks `window.location.hash` once on page load:
- Hash present → download mode
- Hash absent → upload mode

No `hashchange` listener — the shareable link opens in a new tab. Simple page-load routing.

### 5.2 Upload UI states

1. **Landing**: Drag-drop zone centered, file picker button, size limit note
2. **Uploading**: Circular progress (canvas), percentage, cancel button
3. **Complete**: Shareable link (input + copy button), "Install SimpleX" CTA
4. **Error**: Error message + retry button. On server-unreachable, auto-retry with exponential backoff (1s, 2s, 4s, up to 3 attempts) before showing the error state.

### 5.3 Download UI states

1. **Ready**: Approximate file size displayed (encrypted size from `fd.size` or `fd.redirect.size` — see §7 step 2; file name is unavailable — it's inside the encrypted content), download button
2. **Downloading**: Circular progress, percentage
3. **Complete**: Browser save dialog triggered automatically
4. **Error**: Error message (expired, corrupted, unreachable)

### 5.4 Security summary (RFC §7.4)

Both upload-complete and download-ready states display a brief non-technical security summary:
- Files are encrypted in the browser before upload — the server never sees file contents.
- The link contains the decryption key in the hash fragment, which the browser never sends to any server.
- For maximum security, use the SimpleX app.

### 5.5 File expiry

Display on upload-complete state: "Files are typically available for 48 hours." This is an approximation — actual expiry depends on each XFTP server's `[STORE_LOG]` retention configuration. The 48-hour figure matches the current preset server defaults.

### 5.6 Styling

Plain CSS, no framework. White background, centered content, responsive. Circular progress via `<canvas>` (arc drawing, percentage text in center).

File size limit: 100MB. Displayed on upload page.

### 5.7 CSP

`index.html` includes a `<meta>` Content-Security-Policy tag with a build-time placeholder:

```html
<meta http-equiv="Content-Security-Policy"
  content="default-src 'self'; worker-src 'self' blob:; style-src 'self' 'unsafe-inline'; connect-src __CSP_CONNECT_SRC__;">
```

Vite's `transformIndexHtml` hook (in `vite.config.ts`) replaces `__CSP_CONNECT_SRC__` at build time with origins derived from the server list:
- Local mode: `https://localhost:7000`
- Production: `https://xftp1.simplex.im:443 https://xftp2.simplex.im:443 ...` (all 12 servers)

## 6. Upload Flow

`web/upload.ts`:

1. User drops/picks file → `File` object
2. Validate `file.size <= 100 * 1024 * 1024` — show error if exceeded
3. Read file: `new Uint8Array(await file.arrayBuffer())` — note: after `backend.encrypt()` transfers the buffer to the Worker, `fileData` is detached (zero-length). Peak memory is ~2× file size (main thread holds original until transfer, Worker holds encrypted copy before OPFS write). Acceptable for the 100MB limit; do not raise the limit without considering memory implications.
4. Create `CryptoBackend` via factory
5. Create `XFTPClientAgent`
6. `backend.encrypt(fileData, file.name, onProgress)` → `EncryptResult`
   - Encryption progress shown on canvas (Worker posts progress messages)
7. Pick one random server from configured list (V1: all chunks to same server)
8. Call `uploadFile(agent, server, metadata, {onProgress, readChunk: (off, sz) => backend.readChunk(off, sz)})`:
   - `metadata` = `{digest, key, nonce, chunkSizes}` from EncryptResult
   - Network progress shown on canvas
   - Returns `{rcvDescription, sndDescription, uri}`
9. Construct full URL: `window.location.origin + window.location.pathname + '#' + uri`
10. Display link, copy button
11. Cleanup: `backend.cleanup()`, `closeXFTPAgent(agent)`

**Cancel:** User can abort via cancel button. Sets an `AbortController` signal that:
- Sends `{type: 'cleanup'}` to Worker
- Closes the XFTPClientAgent (drops HTTP/2 connections)
- Resets UI to landing state

## 7. Download Flow

`web/download.ts`:

1. Parse `window.location.hash.slice(1)` → `decodeDescriptionURI(fragment)` → `FileDescription`
2. Display file size (`fd.size` bytes, formatted human-readable). Note: `fd.size` is the encrypted size (slightly larger than plaintext due to padding + auth tag). The plaintext size is not available until decryption — display it as an approximate file size. If `fd.redirect !== null`, size comes from `fd.redirect.size` (which is the inner encrypted size).
3. User clicks "Download"
4. Create `CryptoBackend` and `XFTPClientAgent`
5. Call `downloadFileRaw(agent, fd, onRawChunk, {onProgress, concurrency: 3})`:
   - `onRawChunk` forwards each raw chunk to the Worker: `backend.decryptAndStoreChunk(raw.dhSecret, raw.nonce, raw.body, raw.digest, raw.chunkNo)`
   - `downloadFileRaw` handles redirect resolution internally (see §7.1), parallel downloads, and connection pooling
   - Returns the resolved `FileDescription` (inner fd for redirect case, original fd otherwise)
6. `backend.verifyAndDecrypt({size: resolvedFd.size, digest: resolvedFd.digest, key: resolvedFd.key, nonce: resolvedFd.nonce})` → `{header, content}`
   - Verifies size + SHA-512 digest + file-level decryption inside Worker. Only the four needed fields are sent — private replica keys stay on the main thread.
7. ACK: `ackFileChunks(agent, resolvedFd)` — best-effort, after verification succeeds
8. Sanitize `header.fileName` before use: strip path separators (`/`, `\`), replace null/control characters (U+0000-U+001F, U+007F), strip Unicode bidi override characters (U+202A-U+202E, U+2066-U+2069 — prevents `doc.pdf.exe` appearing as `doc.exe.pdf`), limit length to 255 chars. The filename is user-controlled (set by the uploader) and arrives via decrypted content. Then trigger browser save: `new Blob([content])` → `<a download="${sanitizedName}">` click
9. Cleanup: `backend.cleanup()`, `closeXFTPAgent(agent)`

### 7.1 Redirect handling

Handled inside `downloadFileRaw` in agent.ts — the web page doesn't see it. When `fd.redirect !== null`:

1. Download redirect chunks via `downloadXFTPChunkRaw` (parallel, same as regular chunks)
2. Transit-decrypt + verify + file-level decrypt on main thread (redirect data is always small — a few KB of YAML, so main thread decryption is fine)
3. Parse YAML → inner `FileDescription`, validate against `fd.redirect.{size, digest}`
4. ACK redirect chunks (best-effort)
5. Continue downloading inner description's chunks, calling `onRawChunk` for each

### 7.2 Architecture note: download refactoring

Both upload and download use `agent.ts` for orchestration. The key difference is where the crypto/network split happens:

- **Upload**: agent.ts reads encrypted chunks from the Worker via `readChunk` callback, sends them over the network.
- **Download**: agent.ts receives raw encrypted responses from the network via `downloadXFTPChunkRaw` (DH key exchange + network only, no decryption), passes them to the web page via `onRawChunk` callback, which routes them to the Worker for transit decryption.

This split keeps all expensive crypto off the main thread. Transit decryption uses a custom JS Salsa20 implementation (`xorKeystream` in secretbox.ts) that would block the UI for ~50-200ms on a 4MB chunk. File-level decryption (`decryptChunks`) is similarly expensive. Both happen in the Worker.

The cheap operations stay on the main thread: DH key exchange (`generateX25519KeyPair` + `dh` — ~1ms via libsodium WASM), XFTP command encoding/decoding, connection management.

## 8. Build & Dev Setup

### 8.1 vite.config.ts (new, separate from vitest.config.ts)

```typescript
import {defineConfig, type Plugin} from 'vite'
import {readFileSync} from 'fs'
import {createHash} from 'crypto'
import presets from './web/servers.json'

function parseHost(addr: string): string {
  const m = addr.match(/@(.+)$/)
  if (!m) throw new Error('bad server address: ' + addr)
  const host = m[1].split(',')[0]
  return host.includes(':') ? host : host + ':443'
}

function cspPlugin(servers: string[]): Plugin {
  const origins = servers.map(s => 'https://' + parseHost(s)).join(' ')
  return {
    name: 'csp-connect-src',
    transformIndexHtml: {
      order: 'pre',
      handler(html, ctx) {
        if (ctx.server) {
          // Dev mode: remove CSP meta tag entirely — Vite HMR needs inline scripts
          return html.replace(/<meta\s[^>]*?Content-Security-Policy[\s\S]*?>/i, '')
        }
        return html.replace('__CSP_CONNECT_SRC__', origins)
      }
    }
  }
}

export default defineConfig(({mode}) => {
  const define: Record<string, string> = {}
  let servers: string[]

  if (mode === 'local') {
    const pem = readFileSync('../tests/fixtures/ca.crt', 'utf-8')
    const der = Buffer.from(pem.replace(/-----[^-]+-----/g, '').replace(/\s/g, ''), 'base64')
    const fp = createHash('sha256').update(der).digest('base64')
      .replace(/\+/g, '-').replace(/\//g, '_')
    servers = [`xftp://${fp}@localhost:7000`]
    define['__XFTP_SERVERS__'] = JSON.stringify(servers)
  } else {
    servers = [...presets.simplex, ...presets.flux]
  }

  return {
    root: 'web',
    build: {outDir: '../dist-web'},
    define,
    worker: {format: 'es'},
    plugins: [cspPlugin(servers)],
  }
})
```

### 8.2 package.json scripts

```json
"dev": "vite --mode local",
"build:local": "vite build --mode local",
"build:prod": "vite build --mode production",
"preview": "vite preview",
"check:web": "tsc -p tsconfig.web.json --noEmit && tsc -p tsconfig.worker.json --noEmit"
```

Note: `check:web` type-checks `src/` twice (once per config) — acceptable for this small library.

Add `vite` as an explicit devDependency (`^6.0.0` — matching the version vitest 3.x depends on transitively). Relying on transitive resolution is fragile across package managers.

### 8.3 TypeScript configuration

The existing `tsconfig.json` has `rootDir: "src"` and `include: ["src/**/*.ts"]` — this is for library compilation only (output to `dist/`). Vite handles `web/` TypeScript compilation independently via esbuild, so the main tsconfig is unchanged. `web/*.ts` files import from `../src/*.js` using relative paths.

Add two tsconfigs for `web/` type-checking — split by environment to avoid type pollution between DOM and WebWorker globals:

`tsconfig.web.json` — main-thread files (DOM globals: `document`, `window`, etc.):

```json
{
  "extends": "./tsconfig.json",
  "compilerOptions": {
    "rootDir": ".",
    "noEmit": true,
    "types": [],
    "moduleResolution": "bundler",
    "lib": ["ES2022", "DOM"]
  },
  "include": ["web/**/*.ts", "src/**/*.ts"],
  "exclude": ["web/crypto.worker.ts"]
}
```

`tsconfig.worker.json` — Worker file (`self`, `FileSystemSyncAccessHandle`, etc.):

```json
{
  "extends": "./tsconfig.json",
  "compilerOptions": {
    "rootDir": ".",
    "noEmit": true,
    "types": [],
    "moduleResolution": "bundler",
    "lib": ["ES2022", "WebWorker"]
  },
  "include": ["web/crypto.worker.ts", "src/**/*.ts"]
}
```

Both configs set `"types": []` to prevent auto-inclusion of `@types/node` and `"moduleResolution": "bundler"` for Vite-compatible resolution (JSON imports, `.js` extension mapping). The base config's `"moduleResolution": "node"` would cause false type errors on `import ... from './servers.json'`. Both override `@types/node`, which would pollute DOM/WebWorker environments with Node.js globals (`process`, `Buffer`, etc.). This means `src/client.ts`'s dynamic `import("node:http2")` will produce a type error in these configs. This is acceptable — `src/client.ts` provides `createNodeTransport` which is never used in browser code (Vite tree-shakes it out), and full `src/` type-checking is handled by the base `tsconfig.json`. If the error is distracting, add `src/client.ts` to both configs' `exclude` arrays.

Both extend the library tsconfig (inheriting `strict`, `module`, etc.) and include `src/**/*.ts` so imports from `../src/*.js` resolve. `"noEmit": true` means they're only used for type-checking — Vite handles actual compilation. The inherited `"exclude": ["node_modules", "dist", "test"]` intentionally excludes `test/` — test files are type-checked by their own vitest/playwright configs, not by `check:web`.

### 8.4 Dev workflow

`npm run dev` → Vite dev server at `localhost:5173`, configured for local test server. Start `xftp-server` on port 7000 separately (or via the existing globalSetup).

Note: The CSP meta tag's `default-src 'self'` blocks Vite's injected HMR inline scripts in dev mode. The `cspPlugin` handles this by removing the entire CSP `<meta>` tag in serve mode (dev server), so HMR works without restrictions. Production builds always have the correct CSP.

## 9. Library Changes (agent.ts + client.ts)

Changes to support the web page: upload `readChunk` callback, download `onRawChunk` callback with parallel chunk downloads.

### 9.1 Type changes

Split the existing `EncryptedFileInfo` (which currently has `encData`, `digest`, `key`, `nonce`, `chunkSizes` as direct fields) into a metadata-only base and an extension:

```typescript
// Metadata-only variant (no encData — data lives in Worker/OPFS)
export interface EncryptedFileMetadata {
  digest: Uint8Array
  key: Uint8Array
  nonce: Uint8Array
  chunkSizes: number[]
}

// Full variant (existing, extends metadata with data)
export interface EncryptedFileInfo extends EncryptedFileMetadata {
  encData: Uint8Array
}
```

### 9.2 uploadFile signature change

Replace positional optional params with an options bag. Add optional `readChunk`. When provided, `encrypted.encData` is not accessed.

```typescript
export interface UploadOptions {
  onProgress?: (uploaded: number, total: number) => void
  redirectThreshold?: number
  readChunk?: (offset: number, size: number) => Promise<Uint8Array>
}

export async function uploadFile(
  agent: XFTPClientAgent,
  server: XFTPServer,
  encrypted: EncryptedFileMetadata,
  options?: UploadOptions
): Promise<UploadResult>
```

Inside `uploadFile`:
- Chunk read: if `options?.readChunk` is provided, use it. Otherwise, verify `'encData' in encrypted` at runtime (throws `"uploadFile: readChunk required when encData is absent"` if missing), then use `(off, sz) => Promise.resolve((encrypted as EncryptedFileInfo).encData.subarray(off, off + sz))`. This guards against calling `uploadFile` with `EncryptedFileMetadata` but no `readChunk`. For each chunk, call `readChunk(offset, size)` once and use the returned `Uint8Array` for both `getChunkDigest(chunkData)` and `uploadXFTPChunk(..., chunkData)` — do not call `readChunk` twice per chunk.
- Progress total: `const total = encrypted.chunkSizes.reduce((a, b) => a + b, 0)` — replaces `encrypted.encData.length` (line 129) since `EncryptedFileMetadata` has no `encData`. The values are identical: `encData.length === sum(chunkSizes)`.
- `buildDescription` parameter type: change from `EncryptedFileInfo` to `EncryptedFileMetadata` — it only accesses `chunkSizes`, `digest`, `key`, `nonce` (not `encData`).

`uploadRedirectDescription` (internal) is unchanged — redirect descriptions are always small and created in-memory by `encryptFileForUpload`.

### 9.3 Backward compatibility

The signature change from positional params `(agent, server, encrypted, onProgress?, redirectThreshold?)` to `(agent, server, encrypted, options?)` is a breaking change for callers that pass `onProgress` or `redirectThreshold`. In practice, the only callers are the browser test (which passes no options — no change needed) and the web page (new code). `EncryptedFileInfo` extends `EncryptedFileMetadata`, so existing callers that pass `EncryptedFileInfo` work without change.

### 9.4 client.ts: downloadXFTPChunkRaw

Split `downloadXFTPChunk` at the network/crypto boundary. The new function does DH key exchange and network I/O but skips transit decryption:

```typescript
export interface RawChunkResponse {
  dhSecret: Uint8Array
  nonce: Uint8Array
  body: Uint8Array
}

export async function downloadXFTPChunkRaw(
  c: XFTPClient, rpKey: Uint8Array, fId: Uint8Array
): Promise<RawChunkResponse> {
  const {publicKey, privateKey} = generateX25519KeyPair()
  const cmd = encodeFGET(encodePubKeyX25519(publicKey))
  const {response, body} = await sendXFTPCommand(c, rpKey, fId, cmd)
  if (response.type !== "FRFile") throw new Error("unexpected response: " + response.type)
  const dhSecret = dh(response.rcvDhKey, privateKey)
  return {dhSecret, nonce: response.nonce, body}
}
```

`RawChunkResponse` contains only what client.ts produces (DH secret, nonce, encrypted body). The chunk metadata (`chunkNo`, `digest`) is added by agent.ts when constructing `RawDownloadedChunk` (see §9.5).

The existing `downloadXFTPChunk` is refactored to call `downloadXFTPChunkRaw` + `decryptReceivedChunk`:

```typescript
export async function downloadXFTPChunk(
  c: XFTPClient, rpKey: Uint8Array, fId: Uint8Array, digest?: Uint8Array
): Promise<Uint8Array> {
  const {dhSecret, nonce, body} = await downloadXFTPChunkRaw(c, rpKey, fId)
  return decryptReceivedChunk(dhSecret, nonce, body, digest ?? null)
}
```

### 9.5 agent.ts: downloadFileRaw, ackFileChunks, RawDownloadedChunk

New type combining client.ts's `RawChunkResponse` with chunk metadata from agent.ts:

```typescript
export interface RawDownloadedChunk {
  chunkNo: number
  dhSecret: Uint8Array
  nonce: Uint8Array
  body: Uint8Array
  digest: Uint8Array
}
```

New function providing download orchestration with a raw chunk callback. Handles connection pooling, parallel downloads, redirect resolution, and progress. Does **not** ACK — the caller ACKs after verification.

```typescript
export interface DownloadRawOptions {
  onProgress?: (downloaded: number, total: number) => void
  concurrency?: number  // max parallel chunk downloads, default 1
}

export async function downloadFileRaw(
  agent: XFTPClientAgent,
  fd: FileDescription,
  onRawChunk: (chunk: RawDownloadedChunk) => Promise<void>,
  options?: DownloadRawOptions
): Promise<FileDescription>
```

Returns the resolved `FileDescription` — for redirect files this is the inner fd, for non-redirect files this is the original fd. The caller uses this for verification and ACK.

Internal structure:

1. Validate `fd` via `validateFileDescription` (may double-validate if caller already validated via `decodeDescriptionURI` — harmless)
2. If `fd.redirect !== null`: resolve redirect on main thread (redirect data is small):
   a. Download redirect chunks via `downloadXFTPChunk` (not raw — main thread decryption is fine for a few KB)
   b. Verify size + digest, `processDownloadedFile` → YAML bytes
   c. Parse inner `FileDescription`, validate against `fd.redirect.{size, digest}`
   d. ACK redirect chunks (best-effort — redirect chunks are small and separate from the file chunks)
   e. Replace `fd` with inner description
3. Pre-connect: call `getXFTPServerClient(agent, server)` for each unique server before launching concurrent workers. This ensures the client connection exists in the agent's map, avoiding a race condition where multiple concurrent workers all see the client as missing and each call `connectXFTP` independently (leaking all but the last connection). Known limitation: if a connection drops mid-download and multiple workers attempt reconnection simultaneously, the same TOCTOU race reappears. This is a pre-existing issue in `getXFTPServerClient`; a proper fix (per-key connection promise) is out of scope for this plan but should be tracked for follow-up.
4. Download file chunks in parallel (concurrency-limited via sliding window):
   - Create a queue of chunk indices `[0, 1, ..., N-1]`. Launch `min(concurrency, N)` async workers, each pulling the next index from the queue until empty. Each worker loops: pull index → derive key → `getXFTPServerClient` → `downloadXFTPChunkRaw` → `await onRawChunk(...)` → update progress → next index. `await Promise.all(workers)` to wait for completion.
   - For each chunk: derive key (`decodePrivKeyEd25519` → `ed25519KeyPairFromSeed`), get client (`getXFTPServerClient`), call `downloadXFTPChunkRaw`, `await onRawChunk(...)` with result + `chunkNo` + `chunk.digest`
   - Each concurrency slot awaits its `onRawChunk` before starting the next download on that slot. With `concurrency > 1`, multiple `onRawChunk` calls may be in-flight concurrently (one per slot). The Worker handles this correctly — messages are queued and processed sequentially.
   - Update progress after each chunk: `downloaded += chunk.chunkSize; onProgress?.(downloaded, resolvedFd.size)` — both values use encrypted sizes for consistency
5. Return the resolved `fd`

New helper for ACKing after verification:

```typescript
export async function ackFileChunks(
  agent: XFTPClientAgent, fd: FileDescription
): Promise<void> {
  for (const chunk of fd.chunks) {
    const replica = chunk.replicas[0]
    if (!replica) continue
    try {
      const client = await getXFTPServerClient(agent, parseXFTPServer(replica.server))
      const seed = decodePrivKeyEd25519(replica.replicaKey)
      const kp = ed25519KeyPairFromSeed(seed)
      await ackXFTPChunk(client, kp.privateKey, replica.replicaId)
    } catch (_) {}
  }
}
```

The existing `downloadFile` is refactored to use `downloadFileRaw` internally:

```typescript
export async function downloadFile(
  agent: XFTPClientAgent,
  fd: FileDescription,
  onProgress?: (downloaded: number, total: number) => void
): Promise<DownloadResult> {
  const chunks: Uint8Array[] = []
  const resolvedFd = await downloadFileRaw(agent, fd, async (raw) => {
    chunks[raw.chunkNo - 1] = decryptReceivedChunk(
      raw.dhSecret, raw.nonce, raw.body, raw.digest
    )
  }, {onProgress})
  // verify + file-level decrypt using resolvedFd (inner fd for redirect case)
  const combined = chunks.length === 1 ? chunks[0] : concatBytes(...chunks)
  if (combined.length !== resolvedFd.size) throw new Error("downloadFile: file size mismatch")
  const digest = sha512(combined)
  if (!digestEqual(digest, resolvedFd.digest)) throw new Error("downloadFile: file digest mismatch")
  // processDownloadedFile re-concatenates chunks internally — this mirrors the
  // existing downloadFile pattern (verify on concatenated data, then pass chunks
  // array to decryptChunks which concatenates again). Acceptable overhead for
  // correctness: verification must happen on transit-decrypted data before
  // file-level decryption transforms it.
  const result = processDownloadedFile(resolvedFd, chunks)
  await ackFileChunks(agent, resolvedFd)
  return result
}
```

Existing callers retain serial behavior (`concurrency` defaults to 1). The web page opts into parallelism by passing `concurrency: 3`. The browser test (`test/browser.test.ts`) continues to work unchanged. The chunks array is initialized empty (`[]`) and populated by sparse index assignment (`chunks[raw.chunkNo - 1] = ...`), so it correctly handles both redirect and non-redirect cases regardless of the outer fd's chunk count. `digestEqual` is an existing module-private helper in agent.ts (line 327) that performs constant-time byte comparison.

### 9.6 Backward compatibility (download)

`downloadFile` signature is unchanged — existing callers are unaffected. The refactoring adds `downloadFileRaw`, `ackFileChunks`, and `RawDownloadedChunk` as new exports from agent.ts, and `downloadXFTPChunkRaw` + `RawChunkResponse` as new exports from client.ts.

## 10. Testing

### 10.1 Existing tests (unchanged)

- `npm run test:browser` — vitest browser round-trip (library-level)
- `cabal test --test-option='--match=/XFTP Web Client/'` — Haskell per-function tests

### 10.2 New: page E2E test

Add `test/page.spec.ts` using `@playwright/test` (not vitest browser mode — vitest tests run IN the browser and can't control page navigation; Playwright tests run in Node.js and control the browser). Add `@playwright/test` as a devDependency.

Add `playwright.config.ts` at the project root (`xftp-web/`):
- `webServer: { command: 'vite build --mode local && vite preview', url: 'http://localhost:4173', reuseExistingServer: !process.env.CI }` — the `url` property tells Playwright to wait until the preview server is ready before running tests
- `use.ignoreHTTPSErrors: true` (test server uses self-signed cert)
- `use.launchOptions: { args: ['--ignore-certificate-errors'] }` — required because Playwright's `ignoreHTTPSErrors` only affects page navigation, not `fetch()` calls from in-page JavaScript. Without this flag, the page's `createBrowserTransport` fetch to `https://localhost:7000` would fail TLS validation.
- `globalSetup`: `'./test/globalSetup.ts'` (starts xftp-server, shared with vitest)

```typescript
import {test, expect} from '@playwright/test'

test('page upload + download round-trip', async ({page}) => {
  await page.goto(PAGE_URL)
  // Set file input via page.setInputFiles()
  // Wait for upload link to appear: page.waitForSelector('[data-testid="share-link"]')
  // Extract hash from link text
  // Navigate to PAGE_URL + '#' + hash
  // Wait for download complete state
  // Verify file was offered for save (check download event)
})
```

Add script: `"test:page": "playwright test test/page.spec.ts"`

This tests the real bundle including Worker loading, OPFS, and CSP. The existing `test/browser.test.ts` continues to test the library-level pipeline (vitest browser mode, no Workers).

### 10.3 Manual testing

`npm run dev` → open `localhost:5173` in browser → drag file → get link → open link in new tab → download. Requires xftp-server running on port 7000 (local mode).

## 11. Files

**Create:**
- `xftp-web/web/index.html` — page entry point (includes CSP meta tag)
- `xftp-web/web/main.ts` — router + libsodium init
- `xftp-web/web/upload.ts` — upload UI + orchestration
- `xftp-web/web/download.ts` — download UI + orchestration
- `xftp-web/web/progress.ts` — circular progress canvas component
- `xftp-web/web/servers.json` — preset server addresses (shared by servers.ts and vite.config.ts)
- `xftp-web/web/servers.ts` — server configuration (imports servers.json)
- `xftp-web/web/crypto-backend.ts` — CryptoBackend interface + WorkerBackend + factory
- `xftp-web/web/crypto.worker.ts` — Web Worker implementation
- `xftp-web/web/style.css` — styles
- `xftp-web/vite.config.ts` — page build config (CSP generation, server list)
- `xftp-web/tsconfig.web.json` — IDE/CI type-checking for `web/` main-thread files (DOM)
- `xftp-web/tsconfig.worker.json` — IDE/CI type-checking for `web/crypto.worker.ts` (WebWorker)
- `xftp-web/playwright.config.ts` — Playwright E2E test config (webServer, globalSetup)
- `xftp-web/test/page.spec.ts` — page E2E test (Playwright)

**Modify:**
- `xftp-web/src/agent.ts` — add `EncryptedFileMetadata` type, `uploadFile` options bag with `readChunk`, `downloadFileRaw` with `onRawChunk` callback + parallel downloads, `ackFileChunks`, `RawDownloadedChunk` type, refactor `downloadFile` on top of `downloadFileRaw`, add `import {decryptReceivedChunk} from "./download.js"` (needed by refactored `downloadFile`)
- `xftp-web/src/client.ts` — add `downloadXFTPChunkRaw`, `RawChunkResponse` type, refactor `downloadXFTPChunk` to use raw variant
- `xftp-web/package.json` — add dev/build/check:web/test:page scripts, add `vite` + `@playwright/test` devDeps
- `xftp-web/src/protocol/description.ts` — fix stale "SHA-256" comment on `FileDescription.digest` to "SHA-512"
- `xftp-web/.gitignore` — add `dist-web/`

## 12. Implementation Order

1. **Library refactoring** — `client.ts`: add `downloadXFTPChunkRaw`; `agent.ts`: add `downloadFileRaw` + parallel downloads, `uploadFile` options bag with `readChunk`; refactor existing `downloadFile` on top of `downloadFileRaw`. Run existing tests to verify no regressions.
2. **Vite config + HTML shell** — `vite.config.ts`, `index.html`, `main.ts`, verify dev server works
3. **Server config** — `servers.ts` with both local and production server lists
4. **CryptoBackend + Worker** — interface, WorkerBackend, Worker implementation, OPFS logic
5. **Upload flow** — `upload.ts` with drag-drop, encrypt via Worker, upload via agent, show link
6. **Download flow** — `download.ts` with URL parsing, download via agent `downloadFileRaw`, Worker decrypt, browser save
7. **Progress component** — `progress.ts` canvas drawing
8. **Styling** — `style.css`
9. **Testing** — page E2E test, manual browser verification
10. **Build scripts** — `build:local`, `build:prod` in package.json
