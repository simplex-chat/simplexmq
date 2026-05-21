
# Browser Transport & Web Worker Architecture

## TOC

1. Executive Summary
2. Transport: fetch() API
3. Architecture: Environment Abstraction
4. Web Worker Implementation
5. OPFS Implementation
6. Implementation Plan
7. Testing Strategy

## 1. Executive Summary

Adapt `client.ts` from `node:http2` to `fetch()` API for isomorphic Node.js/browser support. Add environment abstraction layer so the same upload/download pipeline works with or without Web Workers and with or without OPFS. In browsers, crypto runs in a Web Worker to keep UI responsive; in Node.js tests, crypto runs directly.

**Key architectural constraint:** Existing crypto functions (`encryptFile`, `decryptChunks`, etc.) remain unchanged. The abstraction layer wraps them, choosing execution context (direct vs Worker) and storage (memory vs OPFS) based on environment.

**Scope:**
- Replace `node:http2` with `fetch()` in `client.ts`
- Add `CryptoBackend` abstraction with three implementations
- Create Web Worker that calls existing crypto functions
- Add OPFS storage for large files in browser

**Out of scope:** Web page UI (Phase 5 in main RFC).

## 2. Transport: fetch() API

### 2.1 Current State

`client.ts` uses `node:http2`:
```typescript
import http2 from "node:http2"
const session = http2.connect(url)
const stream = session.request({':method': 'POST', ':path': '/'})
stream.write(commandBlock)
stream.end(chunkData)
```

### 2.2 Target State

Isomorphic `fetch()` (Node.js 18+ and browsers):
```typescript
const response = await fetch(url, {
  method: 'POST',
  body: concatStreams(commandBlock, chunkData),
  duplex: 'half',  // Required for streaming request body
})
const reader = response.body!.getReader()
```

### 2.3 Key Differences

| Aspect | node:http2 | fetch() |
|--------|-----------|---------|
| Session management | Explicit `session.connect()` / `session.close()` | Per-request (HTTP/2 connection reuse is automatic) |
| Streaming upload | `stream.write()` chunks | `ReadableStream` body + `duplex: 'half'` |
| Streaming download | `stream.on('data')` | `response.body.getReader()` |
| Connection pooling | Manual | Automatic per origin |

### 2.4 API Changes

```typescript
// Before (node:http2)
export interface XFTPClient {
  session: http2.ClientHttp2Session
  thParams: THParams
  server: XFTPServer
}

// After (fetch)
export interface XFTPClient {
  baseUrl: string           // "https://host:port"
  thParams: THParams
  server: XFTPServer
}
```

`connectXFTP()` performs handshake via fetch, returns `XFTPClient` with `baseUrl`.
Subsequent commands use `fetch(client.baseUrl, ...)`.

### 2.5 Handshake via fetch()

**TLS session binding:** Multiple fetch() requests to the same origin reuse the HTTP/2 connection, which means they share the same TLS session. The server's `sessionId` (derived from TLS channel binding) remains consistent across the handshake round-trips and subsequent commands.

```typescript
async function connectXFTP(server: XFTPServer): Promise<XFTPClient> {
  const baseUrl = `https://${server.host}:${server.port}`

  // Round-trip 1: challenge → server handshake + identity proof
  const challenge = crypto.getRandomValues(new Uint8Array(32))
  const req1 = pad(encodeWebClientHello(challenge), xftpBlockSize)
  const resp1 = await fetch(baseUrl, {method: 'POST', body: req1})

  const reader = resp1.body!.getReader()
  const serverBlock = await readExactly(reader, xftpBlockSize)
  const serverHs = decodeServerHandshake(unPad(serverBlock))
  const proofBody = await readRemaining(reader)
  verifyIdentityProof(server.keyHash, challenge, serverHs.sessionId, proofBody)

  // Round-trip 2: client handshake → server ack
  const clientHs = encodeClientHandshake({xftpVersion: 3, keyHash: server.keyHash})
  const req2 = pad(clientHs, xftpBlockSize)
  await fetch(baseUrl, {method: 'POST', body: req2})

  return {baseUrl, thParams: {sessionId: serverHs.sessionId, ...}, server}
}
```

### 2.6 Command Execution

```typescript
async function sendXFTPCommand(
  client: XFTPClient,
  key: Uint8Array,
  entityId: Uint8Array,
  cmd: Uint8Array,
  chunkData?: Uint8Array
): Promise<{response: Uint8Array, body?: ReadableStream}> {
  const block = xftpEncodeAuthTransmission(client.thParams, key, entityId, cmd)

  const reqBody = chunkData
    ? concatBytes(block, chunkData)
    : block

  const resp = await fetch(client.baseUrl, {
    method: 'POST',
    body: reqBody,
    duplex: 'half',
  })

  const reader = resp.body!.getReader()
  const responseBlock = await readExactly(reader, xftpBlockSize)
  const parsed = xftpDecodeTransmission(responseBlock)

  // For FGET: remaining body is encrypted chunk
  const hasMore = await peekReader(reader)
  return {
    response: parsed,
    body: hasMore ? wrapAsStream(reader) : undefined
  }
}
```

## 3. Architecture: Environment Abstraction

### 3.1 Core Principle

**Existing crypto functions remain unchanged.** The functions `encryptFile()`, `decryptChunks()`, `sha512()`, etc. in `crypto/file.ts` and `crypto/digest.ts` are pure computation — they take input bytes and produce output bytes. They have no knowledge of Workers, OPFS, or execution context.

The abstraction layer sits between `agent.ts` (upload/download orchestration) and these crypto functions:

```
┌─────────────────────────────────────────────────────────────────────┐
│  agent.ts (upload/download orchestration)                            │
│  - Unchanged logic: encrypt → chunk → upload → build description     │
│  - Calls CryptoBackend interface, not crypto functions directly      │
├─────────────────────────────────────────────────────────────────────┤
│  CryptoBackend interface (env.ts)                                    │
│  - Abstract interface for encrypt/decrypt/readChunk/writeChunk       │
│  - Factory function selects implementation based on environment      │
├──────────────┬──────────────────────┬───────────────────────────────┤
│ DirectMemory │ WorkerMemory         │ WorkerOPFS                    │
│ Backend      │ Backend              │ Backend                       │
│ (Node.js)    │ (Browser, ≤50MB)     │ (Browser, >50MB)              │
├──────────────┼──────────────────────┼───────────────────────────────┤
│ Calls crypto │ Posts to Worker,     │ Posts to Worker,              │
│ functions    │ Worker calls crypto  │ Worker calls crypto,          │
│ directly     │ functions, returns   │ streams through OPFS          │
│              │ via postMessage      │                               │
├──────────────┴──────────────────────┴───────────────────────────────┤
│  crypto/file.ts, crypto/digest.ts (unchanged)                        │
│  - encryptFile(), decryptChunks(), sha512(), etc.                    │
│  - Pure functions, no environment dependencies                       │
└─────────────────────────────────────────────────────────────────────┘
```

### 3.2 CryptoBackend Interface

```typescript
// env.ts
export interface CryptoBackend {
  // Encrypt file, store result (in memory or OPFS depending on backend)
  encrypt(
    data: Uint8Array,
    fileName: string,
    onProgress?: (done: number, total: number) => void
  ): Promise<EncryptResult>

  // Decrypt from stored encrypted data
  decrypt(
    key: Uint8Array,
    nonce: Uint8Array,
    size: number,
    onProgress?: (done: number, total: number) => void
  ): Promise<DecryptResult>

  // Read chunk from stored encrypted data (for upload)
  readChunk(offset: number, size: number): Promise<Uint8Array>

  // Write chunk to storage (for download, before decrypt)
  writeChunk(data: Uint8Array, offset: number): Promise<void>

  // Clean up temporary storage
  cleanup(): Promise<void>
}

export interface EncryptResult {
  digest: Uint8Array      // SHA-512 of encrypted data
  key: Uint8Array         // Generated encryption key
  nonce: Uint8Array       // Generated nonce
  chunkSizes: number[]    // Chunk sizes for upload
  totalSize: number       // Total encrypted size
}

export interface DecryptResult {
  header: FileHeader      // Extracted file header (fileName, etc.)
  content: Uint8Array     // Decrypted file content
}
```

### 3.3 Backend Implementations

**DirectMemoryBackend** (Node.js):
```typescript
class DirectMemoryBackend implements CryptoBackend {
  private encryptedData: Uint8Array | null = null

  async encrypt(data: Uint8Array, fileName: string, onProgress?): Promise<EncryptResult> {
    const key = randomBytes(32)
    const nonce = randomBytes(24)
    // Call existing crypto function directly
    this.encryptedData = encryptFile(data, fileName, key, nonce, onProgress)
    const digest = sha512(this.encryptedData)
    const chunkSizes = prepareChunkSizes(this.encryptedData.length)
    return { digest, key, nonce, chunkSizes, totalSize: this.encryptedData.length }
  }

  async decrypt(key, nonce, size, onProgress): Promise<DecryptResult> {
    // Call existing crypto function directly
    return decryptChunks([this.encryptedData!], key, nonce, size, onProgress)
  }

  async readChunk(offset: number, size: number): Promise<Uint8Array> {
    return this.encryptedData!.slice(offset, offset + size)
  }

  async writeChunk(data: Uint8Array, offset: number): Promise<void> {
    if (!this.encryptedData) this.encryptedData = new Uint8Array(offset + data.length)
    this.encryptedData.set(data, offset)
  }

  async cleanup(): Promise<void> {
    this.encryptedData = null
  }
}
```

**WorkerMemoryBackend** and **WorkerOPFSBackend** are similar but post messages to a Web Worker instead of calling crypto directly. The Worker then calls the same `encryptFile()`, `decryptChunks()` functions. See §4 for Worker implementation details.

### 3.4 Factory Function

```typescript
// env.ts
export function createCryptoBackend(fileSize: number): CryptoBackend {
  const hasWorker = typeof Worker !== 'undefined'
  const hasOPFS = typeof navigator?.storage?.getDirectory !== 'undefined'
  const isLargeFile = fileSize > 50 * 1024 * 1024

  if (hasWorker && hasOPFS && isLargeFile) {
    return new WorkerOPFSBackend()   // Browser + large file
  } else if (hasWorker) {
    return new WorkerMemoryBackend() // Browser + small file
  } else {
    return new DirectMemoryBackend() // Node.js
  }
}
```

### 3.5 Usage in agent.ts

```typescript
// agent.ts - upload orchestration (simplified)
export async function uploadFile(
  server: XFTPServer,
  fileData: Uint8Array,
  fileName: string,
  onProgress?: ProgressCallback
): Promise<string> {
  // Create backend based on environment
  const backend = createCryptoBackend(fileData.length)

  try {
    // Encrypt (runs in Worker in browser, directly in Node)
    const enc = await backend.encrypt(fileData, fileName, onProgress)

    // Upload chunks (same code regardless of backend)
    const client = await connectXFTP(server)
    const sentChunks = []
    let offset = 0
    for (const size of enc.chunkSizes) {
      const chunk = await backend.readChunk(offset, size)
      const sent = await uploadChunk(client, chunk, enc.digest)
      sentChunks.push(sent)
      offset += size
    }

    // Build description and URI
    const fd = buildFileDescription(enc, sentChunks)
    return encodeFileDescriptionURI(fd)
  } finally {
    await backend.cleanup()
  }
}
```

The key point: `uploadFile()` logic is identical regardless of whether crypto runs in a Worker or directly. The `CryptoBackend` abstraction hides that detail.

### 3.6 Why This Matters for Testing

- **Layer 1 tests** (per-function): Call `encryptFile()`, `decryptChunks()` directly via Node — unchanged
- **Layer 2 tests** (full flow): Call `uploadFile()`, `downloadFile()` in Node — uses `DirectMemoryBackend`, same code path as browser except for Worker
- **Layer 3 tests** (browser): Call `uploadFile()`, `downloadFile()` in Playwright — uses `WorkerMemoryBackend` or `WorkerOPFSBackend`

All three layers exercise the same crypto functions. The only difference is execution context.

## 4. Web Worker Implementation

### 4.1 Why Web Worker

File encryption (XSalsa20-Poly1305) is sequential and CPU-bound:
- 100 MB file ≈ 1-2 seconds of continuous computation
- Running on main thread blocks UI (no progress updates, frozen page)
- Chunking into async microtasks adds complexity and still causes jank

Web Worker runs crypto in parallel thread. Main thread stays responsive.

### 4.2 Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  Main Thread                                                 │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐  │
│  │ UI (upload/ │  │ Progress    │  │ Network (fetch)     │  │
│  │ download)   │  │ display     │  │                     │  │
│  └──────┬──────┘  └──────▲──────┘  └──────────▲──────────┘  │
│         │                │                    │              │
│         │ postMessage    │ progress          │ encrypted    │
│         ▼                │ events            │ chunks       │
├─────────────────────────────────────────────────────────────┤
│  Web Worker                                                  │
│  ┌─────────────────────────────────────────────────────────┐│
│  │ Crypto Pipeline                                          ││
│  │ - encryptFile() with progress callbacks                  ││
│  │ - decryptChunks() with progress callbacks                ││
│  │ - OPFS read/write for temp storage                       ││
│  └─────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────┘
```

### 4.3 Message Protocol

**Main → Worker:**

```typescript
type WorkerRequest =
  // Encrypt file, store result in OPFS (large) or memory (small)
  | {type: 'encrypt', file: File, fileName: string, useOPFS: boolean}
  // Read encrypted chunk from OPFS for upload
  | {type: 'readChunk', offset: number, size: number}
  // Write downloaded chunk to OPFS for later decryption
  | {type: 'writeChunk', data: ArrayBuffer, offset: number}
  // Decrypt from OPFS or provided chunks
  | {type: 'decrypt', key: Uint8Array, nonce: Uint8Array, size: number, chunks?: ArrayBuffer[]}
  // Delete OPFS temp files
  | {type: 'cleanup'}
  | {type: 'cancel'}
```

**Worker → Main:**

```typescript
type WorkerResponse =
  | {type: 'progress', phase: 'encrypt' | 'decrypt', done: number, total: number}
  // For OPFS: encData is empty, data lives in OPFS temp file
  | {type: 'encrypted', encData: ArrayBuffer | null, digest: Uint8Array, key: Uint8Array, nonce: Uint8Array, chunkSizes: number[]}
  | {type: 'chunk', data: ArrayBuffer}  // Response to readChunk
  | {type: 'chunkWritten'}              // Response to writeChunk
  | {type: 'decrypted', header: FileHeader, content: ArrayBuffer}
  | {type: 'cleaned'}                   // Response to cleanup
  | {type: 'error', message: string}
```

### 4.4 Worker Implementation

```typescript
// crypto.worker.ts
import {encryptFile, encryptFileStreaming, decryptChunks, decryptFromOPFS} from './crypto/file.js'
import {sha512} from './crypto/digest.js'
import {prepareChunkSizes} from './protocol/chunks.js'

let opfsHandle: FileSystemSyncAccessHandle | null = null

self.onmessage = async (e: MessageEvent<WorkerRequest>) => {
  const req = e.data

  if (req.type === 'encrypt') {
    const key = crypto.getRandomValues(new Uint8Array(32))
    const nonce = crypto.getRandomValues(new Uint8Array(24))

    if (req.useOPFS) {
      // Large file: stream through OPFS to avoid memory pressure
      const root = await navigator.storage.getDirectory()
      const fileHandle = await root.getFileHandle('encrypted-temp', {create: true})
      opfsHandle = await fileHandle.createSyncAccessHandle()

      // Stream encrypt: read 64KB from File, encrypt, write to OPFS
      const digest = await encryptFileStreaming(
        req.file,
        req.fileName,
        key,
        nonce,
        opfsHandle,
        (done, total) => self.postMessage({type: 'progress', phase: 'encrypt', done, total})
      )

      const encSize = opfsHandle.getSize()
      const chunkSizes = prepareChunkSizes(encSize)

      self.postMessage({
        type: 'encrypted',
        encData: null,  // Data in OPFS, not memory
        digest, key, nonce, chunkSizes
      })
    } else {
      // Small file: in-memory is fine
      const source = new Uint8Array(await req.file.arrayBuffer())
      const encData = encryptFile(source, req.fileName, key, nonce, (done, total) => {
        self.postMessage({type: 'progress', phase: 'encrypt', done, total})
      })

      const digest = sha512(encData)
      const chunkSizes = prepareChunkSizes(encData.length)

      self.postMessage({
        type: 'encrypted',
        encData: encData.buffer,
        digest, key, nonce, chunkSizes
      }, [encData.buffer])
    }
  }

  if (req.type === 'readChunk') {
    // Read chunk from OPFS for upload
    const chunk = new Uint8Array(req.size)
    opfsHandle!.read(chunk, {at: req.offset})
    self.postMessage({type: 'chunk', data: chunk.buffer}, [chunk.buffer])
  }

  if (req.type === 'writeChunk') {
    // Write downloaded chunk to OPFS
    if (!opfsHandle) {
      const root = await navigator.storage.getDirectory()
      const fileHandle = await root.getFileHandle('download-temp', {create: true})
      opfsHandle = await fileHandle.createSyncAccessHandle()
    }
    opfsHandle.write(new Uint8Array(req.data), {at: req.offset})
    self.postMessage({type: 'chunkWritten'})
  }

  if (req.type === 'decrypt') {
    let result
    if (req.chunks) {
      // Small file: chunks provided in memory
      const chunks = req.chunks.map(b => new Uint8Array(b))
      result = decryptChunks(chunks, req.key, req.nonce, req.size, (done, total) => {
        self.postMessage({type: 'progress', phase: 'decrypt', done, total})
      })
    } else {
      // Large file: read from OPFS
      result = decryptFromOPFS(opfsHandle!, req.key, req.nonce, req.size, (done, total) => {
        self.postMessage({type: 'progress', phase: 'decrypt', done, total})
      })
    }

    self.postMessage({
      type: 'decrypted',
      header: result.header,
      content: result.content.buffer
    }, [result.content.buffer])
  }

  if (req.type === 'cleanup') {
    if (opfsHandle) {
      opfsHandle.close()
      opfsHandle = null
    }
    const root = await navigator.storage.getDirectory()
    try { await root.removeEntry('encrypted-temp') } catch {}
    try { await root.removeEntry('download-temp') } catch {}
    self.postMessage({type: 'cleaned'})
  }
}
```

### 4.5 Main Thread Wrapper

```typescript
// crypto-worker.ts (main thread)
export class CryptoWorker {
  private worker: Worker
  private pending: Map<string, {resolve: Function, reject: Function}> = new Map()
  private onProgress?: (done: number, total: number) => void

  constructor() {
    this.worker = new Worker(new URL('./crypto.worker.js', import.meta.url), {type: 'module'})
    this.worker.onmessage = (e) => this.handleMessage(e.data)
  }

  async encrypt(file: File, onProgress?: (done: number, total: number) => void): Promise<EncryptedFileInfo> {
    const useOPFS = file.size > 50 * 1024 * 1024  // 50 MB threshold
    return new Promise((resolve, reject) => {
      this.pending.set('encrypt', {resolve, reject})
      this.onProgress = onProgress
      this.worker.postMessage({type: 'encrypt', file, fileName: file.name, useOPFS})
    })
  }

  async decrypt(
    chunks: Uint8Array[],
    key: Uint8Array,
    nonce: Uint8Array,
    size: number,
    onProgress?: (done: number, total: number) => void
  ): Promise<DownloadResult> {
    return new Promise((resolve, reject) => {
      this.pending.set('decrypt', {resolve, reject})
      this.onProgress = onProgress
      this.worker.postMessage({
        type: 'decrypt',
        chunks: chunks.map(c => c.buffer),
        key, nonce, size
      }, chunks.map(c => c.buffer))
    })
  }

  private handleMessage(msg: WorkerResponse) {
    if (msg.type === 'progress') {
      this.onProgress?.(msg.done, msg.total)
    } else if (msg.type === 'encrypted') {
      this.pending.get('encrypt')?.resolve({
        encData: msg.encData ? new Uint8Array(msg.encData) : null,  // null when using OPFS
        digest: msg.digest,
        key: msg.key,
        nonce: msg.nonce,
        chunkSizes: msg.chunkSizes
      })
    } else if (msg.type === 'decrypted') {
      this.pending.get('decrypt')?.resolve({
        header: msg.header,
        content: new Uint8Array(msg.content)
      })
    } else if (msg.type === 'error') {
      // Reject all pending
      for (const p of this.pending.values()) p.reject(new Error(msg.message))
    }
  }
}
```

## 5. OPFS Implementation

### 5.1 Purpose

For files approaching 100 MB, holding encrypted data in memory while uploading creates memory pressure. OPFS provides temporary file storage:
- Write encrypted data to OPFS as it's generated
- Read chunks from OPFS for upload
- Delete after upload completes

### 5.2 When to Use

- Files > 50 MB: Use OPFS
- Files ≤ 50 MB: In-memory (simpler, no OPFS overhead)

Threshold is configurable.

### 5.3 OPFS API

```typescript
// In Web Worker (synchronous API for performance)
const root = await navigator.storage.getDirectory()
const fileHandle = await root.getFileHandle('encrypted-temp', {create: true})
const accessHandle = await fileHandle.createSyncAccessHandle()

// Write encrypted chunks as they're generated
accessHandle.write(encryptedChunk, {at: offset})

// Read chunk for upload
const chunk = new Uint8Array(chunkSize)
accessHandle.read(chunk, {at: chunkOffset})

// Cleanup
accessHandle.close()
await root.removeEntry('encrypted-temp')
```

### 5.4 Upload Flow with OPFS

```
1. Main: user drops file
2. Main → Worker: {type: 'encrypt', file}
3. Worker:
   - Create OPFS temp file
   - Encrypt 64KB at a time, write to OPFS
   - Post progress every 64KB
   - Compute digest
   - Return {digest, key, nonce, chunkSizes} (data stays in OPFS)
4. Main: for each chunk:
   - Main → Worker: {type: 'readChunk', offset, size}
   - Worker: read from OPFS, return chunk
   - Main: upload chunk via fetch()
5. Main → Worker: {type: 'cleanup'}
6. Worker: delete OPFS temp file
```

### 5.5 Download Flow with OPFS

```
1. Main: parse URL, get FileDescription
2. Main: for each chunk:
   - Download via fetch()
   - Main → Worker: {type: 'writeChunk', data, offset}
   - Worker: write to OPFS temp file
3. Main → Worker: {type: 'decrypt', key, nonce, size}
4. Worker:
   - Read from OPFS
   - Decrypt, verify auth tag
   - Return {header, content}
5. Main: trigger browser download
6. Main → Worker: {type: 'cleanup'}
```

## 6. Implementation Plan

### 6.1 Phase A: fetch() Transport

**Goal:** Replace `node:http2` with `fetch()` in `client.ts`. All existing Node.js tests pass.

1. Rewrite `connectXFTP()` to use fetch() for handshake
2. Rewrite `sendXFTPCommand()` to use fetch()
3. Update `createXFTPChunk`, `uploadXFTPChunk`, `downloadXFTPChunk`, etc.
4. Remove `node:http2` import
5. Run existing Haskell integration tests — must pass

**Files:** `client.ts`

### 6.2 Phase B: Environment Abstraction + Web Worker

**Goal:** Add `CryptoBackend` abstraction (§3) so the same code works in Node (direct) and browser (Worker).

1. Create `env.ts` with `CryptoBackend` interface and `createCryptoBackend()` factory (as specified in §3)
2. Implement `DirectMemoryBackend` for Node.js
3. Create `crypto.worker.ts` that imports and calls existing crypto functions
4. Implement `WorkerMemoryBackend` for browser
5. Update `agent.ts` to use `createCryptoBackend()` instead of direct crypto calls
6. Existing tests pass (now using `DirectMemoryBackend`)

**Files:** `env.ts`, `crypto.worker.ts`, `agent.ts`

### 6.3 Phase C: OPFS Backend

**Goal:** Large files (>50 MB) use OPFS for temp storage in browser.

1. Implement `WorkerOPFSBackend` — uses OPFS sync API in worker
2. Add OPFS helpers in worker: read/write to temp file
3. Factory function now returns `WorkerOPFSBackend` for large files
4. Same `agent.ts` code works — only backend implementation differs

**Files:** `env.ts`, `crypto.worker.ts`

### 6.4 Phase D: Browser Testing

**Goal:** Verify everything works in real browsers.

1. Create minimal test HTML page
2. Test upload flow in Chrome, Firefox, Safari
3. Test download flow
4. Test progress reporting
5. Test cancellation
6. Test error handling (network failure, invalid file)

## 7. Testing Strategy

### 7.1 Test Layers

The `CryptoBackend` abstraction (§3) enables testing at multiple levels without code duplication:

```
┌─────────────────────────────────────────────────────────────────┐
│ Layer 3: Browser Integration (Playwright)                        │
│ - Web Worker message passing                                     │
│ - OPFS read/write                                                │
│ - Progress UI updates                                            │
│ - Real browser fetch() with CORS                                 │
├─────────────────────────────────────────────────────────────────┤
│ Layer 2: Full Flow (Haskell-driven, Node.js)                     │
│ - fetch() transport against real xftp-server                     │
│ - Upload: encrypt → chunk → upload → build description           │
│ - Download: parse → download → verify → decrypt                  │
│ - Cross-language: TS upload ↔ Haskell download (and vice versa)  │
├─────────────────────────────────────────────────────────────────┤
│ Layer 1: Per-Function (Haskell-driven, Node.js)                  │
│ - 172 existing tests                                             │
│ - Byte-identical output vs Haskell functions                     │
└─────────────────────────────────────────────────────────────────┘
```

### 7.2 Layer 1: Per-Function Tests (Existing)

Existing Haskell-driven tests in `XFTPWebTests.hs`. Each test calls a TypeScript function via Node and compares output with Haskell.

```bash
cabal test --ghc-options -O0 --test-option='--match=/XFTP Web Client/'
```

All 172 tests must pass. No changes needed for browser transport work.

### 7.3 Layer 2: Full Flow Tests (Node.js + fetch)

Haskell-driven integration tests using Node.js native fetch(). These test the complete upload/download flow without Worker/OPFS.

```haskell
-- XFTPWebTests.hs (extends existing test file)
it "fetch transport: upload and download round-trip" $ do
  withXFTPServer testXFTPServerConfigSNI $ \server -> do
    -- TypeScript uploads via fetch(), returns URI
    uri <- jsOut $ callTS "src/agent" "uploadFileTest" serverAddrHex <> testFileHex
    -- TypeScript downloads via fetch()
    content <- jsOut $ callTS "src/agent" "downloadFileTest" uriHex
    content `shouldBe` testFileContent

it "fetch transport: TS upload, Haskell download" $ do
  withXFTPServer testXFTPServerConfigSNI $ \server -> do
    uri <- jsOut $ callTS "src/agent" "uploadFileTest" serverAddrHex <> testFileHex
    -- Haskell agent downloads using existing xftp CLI pattern
    outPath <- withAgent 1 agentCfg initAgentServers testDB $ \a -> do
      rfId <- xftpReceiveFile' a 1 uri Nothing
      waitRfDone a
    content <- B.readFile outPath
    content `shouldBe` testFileContent
```

**What this tests:**
- fetch() handshake (challenge-response, TLS session binding)
- fetch() command execution (FNEW, FPUT, FGET, FACK)
- Streaming request/response bodies
- Full encrypt → upload → download → decrypt flow

**What this doesn't test:**
- Web Worker message passing
- OPFS storage
- Browser-specific fetch() behavior (CORS preflight, etc.)

### 7.4 Layer 3: Browser Integration Tests (Playwright)

Playwright tests run in real browsers, testing browser-specific functionality.

**Test infrastructure:**

```
xftp-web/
├── test/
│   ├── browser.test.ts      # Playwright test file
│   └── test-server.ts       # Spawns xftp-server for tests
└── test-page/
    ├── index.html           # Minimal test UI
    └── test-harness.ts      # Exposes test functions to window
```

**Running browser tests:**

```bash
cd xftp-web
npm run test:browser  # Spawns xftp-server, runs Playwright
```

**Test cases:**

```typescript
// test/browser.test.ts
import { test, expect } from '@playwright/test'
import { spawn } from 'child_process'

let serverProcess: ChildProcess

test.beforeAll(async () => {
  // Spawn xftp-server with SNI cert for browser TLS
  serverProcess = spawn('xftp-server', ['start', '-c', 'test-config.ini'])
  await waitForServer()
})

test.afterAll(async () => {
  serverProcess.kill()
})

test('small file upload/download (in-memory)', async ({ page }) => {
  await page.goto('/test-page/')

  const result = await page.evaluate(async () => {
    const data = new Uint8Array(1024 * 1024)  // 1 MB
    crypto.getRandomValues(data)
    const file = new File([data], 'small.bin')

    const uri = await window.xftp.uploadFile(file)
    const downloaded = await window.xftp.downloadFile(uri)

    return {
      uploadedSize: data.length,
      downloadedSize: downloaded.length,
      match: arraysEqual(data, downloaded),
      usedOPFS: window.xftp.lastUploadUsedOPFS
    }
  })

  expect(result.match).toBe(true)
  expect(result.usedOPFS).toBe(false)  // Small file, no OPFS
})

test('large file upload/download (OPFS)', async ({ page }) => {
  await page.goto('/test-page/')

  const result = await page.evaluate(async () => {
    const data = new Uint8Array(60 * 1024 * 1024)  // 60 MB
    crypto.getRandomValues(data)
    const file = new File([data], 'large.bin')

    const uri = await window.xftp.uploadFile(file)
    const downloaded = await window.xftp.downloadFile(uri)

    return {
      match: arraysEqual(data, downloaded),
      usedOPFS: window.xftp.lastUploadUsedOPFS
    }
  })

  expect(result.match).toBe(true)
  expect(result.usedOPFS).toBe(true)  // Large file, used OPFS
})

test('progress events fire during upload', async ({ page }) => {
  await page.goto('/test-page/')

  const progressEvents = await page.evaluate(async () => {
    const events: number[] = []
    const data = new Uint8Array(10 * 1024 * 1024)  // 10 MB
    const file = new File([data], 'progress.bin')

    await window.xftp.uploadFile(file, (done, total) => {
      events.push(done / total)
    })

    return events
  })

  expect(progressEvents.length).toBeGreaterThan(1)
  expect(progressEvents[progressEvents.length - 1]).toBe(1)  // 100% at end
})

test('Web Worker keeps UI responsive', async ({ page }) => {
  await page.goto('/test-page/')

  // Start upload and measure main thread responsiveness
  const result = await page.evaluate(async () => {
    const data = new Uint8Array(50 * 1024 * 1024)  // 50 MB
    const file = new File([data], 'responsive.bin')

    let frameCount = 0
    let uploadDone = false

    // Count animation frames during upload
    function countFrames() {
      frameCount++
      if (!uploadDone) requestAnimationFrame(countFrames)
    }
    requestAnimationFrame(countFrames)

    const start = performance.now()
    await window.xftp.uploadFile(file)
    uploadDone = true
    const elapsed = performance.now() - start

    // If main thread was blocked, frameCount would be very low
    const expectedFrames = (elapsed / 1000) * 30  // ~30 fps minimum
    return { frameCount, expectedFrames, elapsed }
  })

  // Should maintain reasonable frame rate (Worker offloaded crypto)
  expect(result.frameCount).toBeGreaterThan(result.expectedFrames * 0.5)
})
```

### 7.5 Cross-Browser Matrix

| Browser | fetch streaming | Web Worker | OPFS sync | Status |
|---------|----------------|------------|-----------|--------|
| Chrome 105+ | ✓ | ✓ | ✓ | Primary target |
| Firefox 111+ | ✓ | ✓ | ✓ | Supported |
| Safari 16.4+ | ✓ | ✓ | ✓ | Supported |
| Edge 105+ | ✓ | ✓ | ✓ | Supported (Chromium) |

Playwright tests run against Chrome by default. CI can run against all browsers.

### 7.6 Test Execution Summary

| Phase | Test Layer | Command | What's Verified |
|-------|-----------|---------|-----------------|
| A | Layer 1 + 2 | `cabal test --test-option='--match=/XFTP Web Client/'` | fetch() transport, full flow |
| B | Layer 3 | `npm run test:browser` | Worker message passing, progress |
| C | Layer 3 | `npm run test:browser` | OPFS storage for large files |
| D | Layer 3 | `npm run test:browser -- --project=firefox,webkit` | Cross-browser |
