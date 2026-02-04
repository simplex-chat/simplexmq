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
│   └── protocol/               # Unchanged
├── web/                        # Web page (new)
│   ├── index.html              # Entry point (CSP meta tag)
│   ├── main.ts                 # Router + sodium.ready init
│   ├── upload.ts               # Upload UI + orchestration
│   ├── download.ts             # Download UI + orchestration
│   ├── progress.ts             # Circular progress canvas component
│   ├── servers.ts              # Server list (build-time configured)
│   ├── crypto-backend.ts       # CryptoBackend interface + WorkerBackend
│   ├── crypto.worker.ts        # Web Worker: encrypt/decrypt/OPFS
│   └── style.css               # Minimal styling
├── vite.config.ts              # Page build config (new)
├── playwright.config.ts        # Page E2E test config (new)
├── vitest.config.ts            # Test config (existing)
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

Both upload and download use `agent.ts` for orchestration (connection pooling, parallel chunk transfers, redirect handling, ACK). Upload uses a `readChunk` callback for Worker data access. Download uses a `onRawChunk` callback to route raw encrypted chunks to the Worker for decryption (see §7.2).

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
  verifyAndDecrypt(fd: FileDescription
  ): Promise<{header: FileHeader, content: Uint8Array}>

  cleanup(): Promise<void>
}

export interface EncryptResult {
  digest: Uint8Array
  key: Uint8Array
  nonce: Uint8Array
  chunkSizes: number[]
  totalSize: number
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

The Worker always uses OPFS for temp storage (single code path — no memory/disk branching). OPFS I/O overhead is negligible relative to crypto and network time.

### 3.3 Worker message protocol

Every request carries a numeric `id`. Responses carry the same `id`. WorkerBackend maintains a `Map<number, {resolve, reject}>` to match responses to pending promises.

Main → Worker:
- `{id, type: 'encrypt', data: ArrayBuffer, fileName: string}` — encrypt file, store in OPFS
- `{id, type: 'readChunk', offset, size}` — read encrypted chunk from OPFS
- `{id, type: 'decryptAndStore', dhSecret, nonce, body: ArrayBuffer, digest, chunkNo}` — transit-decrypt + store in OPFS
- `{id, type: 'verifyAndDecrypt', fd: {...}}` — verify digest + file-level decrypt all chunks
- `{id, type: 'cleanup'}` — delete OPFS temp files

Worker → Main:
- `{id, type: 'progress', done, total}` — encryption/decryption progress (fire-and-forget, no promise)
- `{id, type: 'encrypted', digest, key, nonce, chunkSizes, totalSize}`
- `{id, type: 'chunk', data: ArrayBuffer}`
- `{id, type: 'stored'}` — decryptAndStore acknowledgment
- `{id, type: 'decrypted', header, content: ArrayBuffer}`
- `{id, type: 'cleaned'}`
- `{id, type: 'error', message}` — rejects the pending promise for this `id`

### 3.4 Worker internals

**Imports:** The Worker imports directly from `src/crypto/file.js` (`encryptFile`, `encodeFileHeader`), `src/crypto/digest.js` (`sha512`), `src/protocol/chunks.js` (`prepareChunkSizes`, `fileSizeLen`, `authTagSize`), `src/protocol/encoding.js` (`concatBytes`), and `src/download.js` (`decryptReceivedChunk`, `processDownloadedFile`). It does NOT import from `src/agent.ts` or `src/client.ts` — those pull in `node:http2` via dynamic import which would break Worker bundling.

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
8. `digest = sha512(encData)`
9. Write `encData` to OPFS via `createSyncAccessHandle`, null out reference
10. Post back `{digest, key, nonce, chunkSizes, totalSize: encData.length}` (no encData transfer)

readChunk:
- `handle.read(buf, {at: offset})` → return slice as transferable ArrayBuffer

decryptAndStoreChunk:
1. `decryptReceivedChunk(dhSecret, nonce, body, digest)` → transit-decrypted chunk data
2. Write decrypted chunk to OPFS download temp file at `chunkNo`-based offset

verifyAndDecrypt (mirrors size/digest checks in agent.ts `downloadFile`):
1. Read all chunks from OPFS into memory: `combined = concatBytes(...chunks)`
2. Verify total size matches `fd.size`: `combined.length === fd.size`
3. Verify SHA-512 digest: `sha512(combined)` matches `fd.digest`
4. Call `processDownloadedFile(fd, chunks)` from `download.js` → return `{header, content}`
5. Delete OPFS download temp file
6. Content is posted back via transferable ArrayBuffer

### 3.5 Browser requirements

The page requires a modern browser with Web Worker and OPFS support:
- Chrome 102+, Firefox 111+, Safari 15.2+ (Workers + OPFS)
- If Worker or OPFS is unavailable, the page shows an error message rather than falling back silently.

No `DirectBackend` is needed — the page is browser-only, and tests run in vitest browser mode (real Chromium). The existing library tests (`test/browser.test.ts`) test the crypto/upload/download pipeline directly without Workers.

## 4. Server Configuration

### 4.1 Server lists

`web/servers.ts`:

```typescript
import {parseXFTPServer, type XFTPServer} from '../src/protocol/address.js'

// SimpleX-operated (from simplexmq/src/Simplex/FileTransfer/Client/Presets.hs)
const SIMPLEX_SERVERS = [
  "xftp://da1aH3nOT-9G8lV7bWamhxpDYdJ1xmW7j3JpGaDR5Ug=@xftp1.simplex.im",
  "xftp://5vog2Imy1ExJB_7zDZrkV1KDWi96jYFyy9CL6fndBVw=@xftp2.simplex.im",
  "xftp://PYa32DdYNFWi0uZZOprWQoQpIk5qyjRJ3EF7bVpbsn8=@xftp3.simplex.im",
  "xftp://k_GgQl40UZVV0Y4BX9ZTyMVqX5ZewcLW0waQIl7AYDE=@xftp4.simplex.im",
  "xftp://-bIo6o8wuVc4wpZkZD3tH-rCeYaeER_0lz1ffQcSJDs=@xftp5.simplex.im",
  "xftp://6nSvtY9pJn6PXWTAIMNl95E1Kk1vD7FM2TeOA64CFLg=@xftp6.simplex.im",
]

// Flux-operated (from simplex-chat/src/Simplex/Chat/Operators/Presets.hs)
const FLUX_SERVERS = [
  "xftp://92Sctlc09vHl_nAqF2min88zKyjdYJ9mgxRCJns5K2U=@xftp1.simplexonflux.com",
  "xftp://YBXy4f5zU1CEhnbbCzVWTNVNsaETcAGmYqGNxHntiE8=@xftp2.simplexonflux.com",
  "xftp://ARQO74ZSvv2OrulRF3CdgwPz_AMy27r0phtLSq5b664=@xftp3.simplexonflux.com",
  "xftp://ub2jmAa9U0uQCy90O-fSUNaYCj6sdhl49Jh3VpNXP58=@xftp4.simplexonflux.com",
  "xftp://Rh19D5e4Eez37DEE9hAlXDB3gZa1BdFYJTPgJWPO9OI=@xftp5.simplexonflux.com",
  "xftp://0AznwoyfX8Od9T_acp1QeeKtxUi676IBIiQjXVwbdyU=@xftp6.simplexonflux.com",
]

declare const __XFTP_SERVERS__: string[]

const serverAddresses: string[] = typeof __XFTP_SERVERS__ !== 'undefined'
  ? __XFTP_SERVERS__
  : [...SIMPLEX_SERVERS, ...FLUX_SERVERS]

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

1. **Ready**: File size displayed (file name is unavailable — it's inside the encrypted content), download button
2. **Downloading**: Circular progress, percentage
3. **Complete**: Browser save dialog triggered automatically
4. **Error**: Error message (expired, corrupted, unreachable)

### 5.4 Security summary (RFC §7.4)

Both upload-complete and download-ready states display a brief non-technical security summary:
- Files are encrypted in the browser before upload — the server never sees file contents.
- The link contains the decryption key in the hash fragment, which the browser never sends to any server.
- For maximum security, use the SimpleX app.

### 5.5 File expiry

Hardcode 48-hour expiry. Display on upload-complete state: "This link expires in 48 hours."

### 5.6 Styling

Plain CSS, no framework. White background, centered content, responsive. Circular progress via `<canvas>` (arc drawing, percentage text in center).

File size limit: 100MB. Displayed on upload page.

### 5.7 CSP

`index.html` includes a `<meta>` Content-Security-Policy tag: `default-src 'self'; worker-src 'self' blob:; style-src 'self' 'unsafe-inline'; connect-src https:;`

## 6. Upload Flow

`web/upload.ts`:

1. User drops/picks file → `File` object
2. Validate `file.size <= 100 * 1024 * 1024` — show error if exceeded
3. Read file: `new Uint8Array(await file.arrayBuffer())`
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
2. Display file size (`fd.size` bytes, formatted human-readable). If `fd.redirect !== null`, size comes from `fd.redirect.size`.
3. User clicks "Download"
4. Create `CryptoBackend` and `XFTPClientAgent`
5. Call `downloadFileRaw(agent, fd, onRawChunk, {onProgress, concurrency: 3})`:
   - `onRawChunk` forwards each raw chunk to the Worker: `backend.decryptAndStoreChunk(raw.dhSecret, raw.nonce, raw.body, raw.digest, raw.chunkNo)`
   - `downloadFileRaw` handles redirect resolution internally (see §7.1), parallel downloads, connection pooling, and ACK
6. `backend.verifyAndDecrypt(fd)` → `{header, content}`
   - Verifies size + SHA-512 digest + file-level decryption inside Worker
7. Trigger browser save: `new Blob([content])` → `<a download="${header.fileName}">` click
8. Cleanup: `backend.cleanup()`, `closeXFTPAgent(agent)`

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
import {defineConfig} from 'vite'
import {readFileSync} from 'fs'
import {createHash} from 'crypto'

export default defineConfig(({mode}) => {
  const define: Record<string, string> = {}

  if (mode === 'local') {
    const pem = readFileSync('../tests/fixtures/ca.crt', 'utf-8')
    const der = Buffer.from(pem.replace(/-----[^-]+-----/g, '').replace(/\s/g, ''), 'base64')
    const fp = createHash('sha256').update(der).digest('base64')
      .replace(/\+/g, '-').replace(/\//g, '_')
    define['__XFTP_SERVERS__'] = JSON.stringify([`xftp://${fp}@localhost:7000`])
  }

  return {
    root: 'web',
    build: {outDir: '../dist-web'},
    define,
    worker: {format: 'es'},
  }
})
```

### 8.2 package.json scripts

```json
"dev": "vite --mode local",
"build:local": "vite build --mode local",
"build:prod": "vite build --mode production",
"preview": "vite preview"
```

### 8.3 TypeScript configuration

The existing `tsconfig.json` has `rootDir: "src"` and `include: ["src/**/*.ts"]` — this is for library compilation only (output to `dist/`). Vite handles `web/` TypeScript compilation independently via esbuild, so no tsconfig changes are needed. `web/*.ts` files import from `../src/*.js` using relative paths.

### 8.4 Dev workflow

`npm run dev` → Vite dev server at `localhost:5173`, configured for local test server. Start `xftp-server` on port 7000 separately (or via the existing globalSetup).

## 9. Library Changes (agent.ts + client.ts)

Changes to support the web page: upload `readChunk` callback, download `onRawChunk` callback with parallel chunk downloads.

### 9.1 New types

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
- Chunk read: `const read = options?.readChunk ?? ((off, sz) => Promise.resolve((encrypted as EncryptedFileInfo).encData.subarray(off, off + sz)))`
- Progress total: `const total = encrypted.chunkSizes.reduce((a, b) => a + b, 0)` — replaces `encrypted.encData.length` (line 129) since `EncryptedFileMetadata` has no `encData`. The values are identical: `encData.length === sum(chunkSizes)`.
- `buildDescription` parameter type: change from `EncryptedFileInfo` to `EncryptedFileMetadata` — it only accesses `chunkSizes`, `digest`, `key`, `nonce` (not `encData`).

`uploadRedirectDescription` (internal) is unchanged — redirect descriptions are always small and created in-memory by `encryptFileForUpload`.

### 9.3 Backward compatibility

The signature change from positional params `(agent, server, encrypted, onProgress?, redirectThreshold?)` to `(agent, server, encrypted, options?)` is a breaking change for callers that pass `onProgress` or `redirectThreshold`. In practice, the only callers are the browser test (which passes no options — no change needed) and the web page (new code). `EncryptedFileInfo` extends `EncryptedFileMetadata`, so existing callers that pass `EncryptedFileInfo` work without change.

### 9.4 client.ts: downloadXFTPChunkRaw

Split `downloadXFTPChunk` at the network/crypto boundary. The new function does DH key exchange and network I/O but skips transit decryption:

```typescript
export interface RawDownloadedChunk {
  chunkNo: number
  dhSecret: Uint8Array
  nonce: Uint8Array
  body: Uint8Array
  digest: Uint8Array
}

export async function downloadXFTPChunkRaw(
  c: XFTPClient, rpKey: Uint8Array, fId: Uint8Array
): Promise<{dhSecret: Uint8Array, nonce: Uint8Array, body: Uint8Array}> {
  const {publicKey, privateKey} = generateX25519KeyPair()
  const cmd = encodeFGET(encodePubKeyX25519(publicKey))
  const {response, body} = await sendXFTPCommand(c, rpKey, fId, cmd)
  if (response.type !== "FRFile") throw new Error("unexpected response: " + response.type)
  const dhSecret = dh(response.rcvDhKey, privateKey)
  return {dhSecret, nonce: response.nonce, body}
}
```

The existing `downloadXFTPChunk` is refactored to call `downloadXFTPChunkRaw` + `decryptReceivedChunk`:

```typescript
export async function downloadXFTPChunk(
  c: XFTPClient, rpKey: Uint8Array, fId: Uint8Array, digest?: Uint8Array
): Promise<Uint8Array> {
  const {dhSecret, nonce, body} = await downloadXFTPChunkRaw(c, rpKey, fId)
  return decryptReceivedChunk(dhSecret, nonce, body, digest ?? null)
}
```

### 9.5 agent.ts: downloadFileRaw

New function providing download orchestration with a raw chunk callback. Handles connection pooling, parallel downloads, redirect resolution, ACK, and progress.

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
): Promise<void>
```

Internal structure:

1. Validate `fd` via `validateFileDescription`
2. If `fd.redirect !== null`: resolve redirect on main thread (redirect data is small):
   a. Download redirect chunks via `downloadXFTPChunk` (not raw — main thread decryption is fine for a few KB)
   b. Verify size + digest, `processDownloadedFile` → YAML bytes
   c. Parse inner `FileDescription`, validate against `fd.redirect.{size, digest}`
   d. ACK redirect chunks (best-effort)
   e. Replace `fd` with inner description
3. Download file chunks in parallel (concurrency-limited):
   - For each chunk: derive key (`decodePrivKeyEd25519` → `ed25519KeyPairFromSeed`), get client (`getXFTPServerClient`), call `downloadXFTPChunkRaw`, call `onRawChunk` with result + `chunkNo` + `chunk.digest`
   - Update progress after each chunk
4. ACK all file chunks (best-effort)

The existing `downloadFile` is refactored to use `downloadFileRaw` internally:

```typescript
export async function downloadFile(
  agent: XFTPClientAgent,
  fd: FileDescription,
  onProgress?: (downloaded: number, total: number) => void
): Promise<DownloadResult> {
  const chunks: Uint8Array[] = new Array(fd.chunks.length)
  await downloadFileRaw(agent, fd, async (raw) => {
    chunks[raw.chunkNo - 1] = decryptReceivedChunk(
      raw.dhSecret, raw.nonce, raw.body, raw.digest
    )
  }, {onProgress})
  // verify + file-level decrypt (same as current code)
  const combined = chunks.length === 1 ? chunks[0] : concatBytes(...chunks)
  if (combined.length !== fd.size) throw new Error("downloadFile: file size mismatch")
  const digest = sha512(combined)
  if (!digestEqual(digest, fd.digest)) throw new Error("downloadFile: file digest mismatch")
  return processDownloadedFile(fd, chunks)
}
```

This gives existing callers parallel downloads for free. The browser test (`test/browser.test.ts`) continues to work unchanged.

### 9.6 Backward compatibility (download)

`downloadFile` signature is unchanged — existing callers are unaffected. The refactoring adds `downloadFileRaw` and `downloadXFTPChunkRaw` as new exports. `RawDownloadedChunk` is a new exported type from client.ts.

## 10. Testing

### 10.1 Existing tests (unchanged)

- `npm run test:browser` — vitest browser round-trip (library-level)
- `cabal test --test-option='--match=/XFTP Web Client/'` — Haskell per-function tests

### 10.2 New: page E2E test

Add `test/page.spec.ts` using `@playwright/test` (not vitest browser mode — vitest tests run IN the browser and can't control page navigation; Playwright tests run in Node.js and control the browser). Add `@playwright/test` as a devDependency.

Add `playwright.config.ts` at the project root (`xftp-web/`):
- `webServer`: runs `vite build --mode local && vite preview` to build and serve `dist-web/`
- `use.ignoreHTTPSErrors: true` (test server uses self-signed cert)
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
- `xftp-web/web/servers.ts` — server configuration
- `xftp-web/web/crypto-backend.ts` — CryptoBackend interface + WorkerBackend + factory
- `xftp-web/web/crypto.worker.ts` — Web Worker implementation
- `xftp-web/web/style.css` — styles
- `xftp-web/vite.config.ts` — page build config
- `xftp-web/playwright.config.ts` — Playwright E2E test config (webServer, globalSetup)
- `xftp-web/test/page.spec.ts` — page E2E test (Playwright)

**Modify:**
- `xftp-web/src/agent.ts` — add `EncryptedFileMetadata` type, `uploadFile` options bag with `readChunk`, `downloadFileRaw` with `onRawChunk` callback + parallel downloads, refactor `downloadFile` on top of `downloadFileRaw`
- `xftp-web/src/client.ts` — add `downloadXFTPChunkRaw`, `RawDownloadedChunk` type, refactor `downloadXFTPChunk` to use raw variant
- `xftp-web/package.json` — add dev/build/test:page scripts, add `@playwright/test` devDep
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
