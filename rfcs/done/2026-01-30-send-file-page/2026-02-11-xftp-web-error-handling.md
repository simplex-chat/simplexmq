# XFTP Web Error Handling and Connection Resilience

## 1. Problem Statement

The XFTP web client is fundamentally fragile: any transient error (browser opening a new HTTP/2 connection, network hiccup, server restart) causes an unrecoverable failure with a cryptic error message. There is no retry logic, no fetch timeout, no error categorization, and the upload uses a single server instead of distributing chunks across preset servers. This makes the app frustrating — it works most of the time but fails unpredictably, which is worse than being completely broken.

### Confirmed root cause (from diagnostic logs)

When the browser opens a new HTTP/2 connection mid-operation, the new connection has a different TLS SessionId with no handshake state in the server's `TMap SessionId Handshake`. The server's `Nothing` branch in `xftpServerHandshakeV1` (Server.hs:169) unconditionally calls `processHello`, which tries to decode the command body as `XFTPClientHello`, fails, and sends a raw padded "HANDSHAKE" error string. The client cannot parse this as a proper transmission (first byte 'H' = 72 is read as batch count), producing `"expected batch count 1, got 72"`.

Server log confirming the SessionId change:
```
DEBUG dispatch: Accepted+command sessId="ZSo1GGETgIvjbB7CWHbvGPpbMjx_b2IlC1eTI6aKfqc="
...20 successful commands...
DEBUG dispatch: Nothing sessId="mJC7Sck9xxW5UsXoPGoUWduuHghSVgf6CnD6ZC6SBhU=" webHello=False
```

### Why re-handshake is required (cannot be made optional)

1. **SessionId is baked into signed command data.** `encodeAuthTransmission` signs `concat(encode(sessionId), tInner)` with Ed25519. Server's `tDecodeServer` (Protocol.hs:2242) verifies `sessId == sessionId`. New connection = different sessionId = signature mismatch.
2. **Server generates per-session DH keys.** `processHello` creates fresh X25519 keypair stored in `HandshakeSent`. For SMP browser clients (future), `verifyCmdAuth` (Protocol.hs:1322) requires the matching `serverPrivKey` from `thAuth`.
3. **This applies to both XFTP and future SMP browser clients** — the session management approach is the same.

### Why multiple preset servers cannot work

Upload (`agent.ts:105-157`) takes a single `server: XFTPServer` parameter and uploads ALL chunks to it. `web/upload.ts:133` calls `pickRandomServer(servers)` which selects ONE random server from all presets. The multi-server preset configuration is pointless — only one server is ever used per upload. The design intent (RFC section 11.6: "upload in parallel to 8 randomly selected servers") is not implemented. This must be fixed in Phase 2 (section 3.7).

## 2. Solution Summary

### Phase 1: Error handling and connection resilience

1. **Server: strict dispatch for allowed protocol combinations** — reject all invalid combinations
2. **Client: automatic retry with re-handshake** on SESSION/HANDSHAKE errors
3. **Client: fetch timeout** with configurable duration
4. **UI: error categorization and retry** — auto-retry temporary, human-readable permanent
5. **Client: connection state with Promise-based lock and per-server queues** — `ServerConnection` with `client: Promise<XFTPClient>` + `queue: Promise<void>`
6. **Client: fix cache key** — include keyHash

### Phase 2: Multi-server upload (after Phase 1)

7. **Multi-server upload with server selection and failover** — distribute chunks across servers, retry FNEW on different server if one fails

## 3. Detailed Technical Design

### 3.1 Server: strict dispatch for allowed protocol combinations

**Principle:** Everything not explicitly done by existing Haskell/TS clients is prohibited. It is better to fail on impossible combinations than to be permissive — permissiveness complicates debugging and creates attack vectors via unexpected behaviors.

**Allowed behaviors by client type:**

| Client | SNI | webHello header | Hello body | When |
|--------|-----|----------------|------------|------|
| Haskell | No | No | Empty | New connection only |
| Web | Yes | Yes | Non-empty (XFTPClientHello) | New OR existing connection |

**Minimal surgical change.** The existing dispatch (Server.hs:169-189) already correctly handles `HandshakeSent` and `HandshakeAccepted` — their guards cover all valid and invalid combinations. The ONLY missing case is `Nothing` + web client sending a command on a stale session.

`processHello` (Server.hs:194-217) already internally routes: `B.null bodyHead` → Haskell hello, `sniUsed` → web hello decode, else → HANDSHAKE. For stale web sessions, it currently tries to decode a command body as `XFTPClientHello`, fails, and throws HANDSHAKE. The fix: detect this case BEFORE calling processHello and throw SESSION instead, so the client knows to re-handshake (not that its hello was malformed).

**Change: add one guard to `Nothing` branch, remove debug logging.**

```haskell
-- Before (1 line):
Nothing -> processHello Nothing

-- After (3 lines):
Nothing
  | sniUsed && not webHello -> throwE SESSION  -- web command on stale session
  | otherwise -> processHello Nothing          -- normal hello (web or Haskell)
```

`throwE SESSION` is caught by `either sendError pure r` (line 190). `sendError` pads `smpEncode SESSION` = `"SESSION"` (Transport.hs:298) to `xftpBlockSize`. The client's padded error detection (section 3.2) catches this as a retriable error and triggers re-handshake. SESSION is a valid `XFTPErrorType` constructor (Transport.hs:225) — no new helpers needed.

**All other branches remain unchanged.** `HandshakeSent` guards (`webHello` → processHello, `otherwise` → processClientHandshake with body size check inside) are correct. `HandshakeAccepted` guards (`webHello`, `webHandshake`, `otherwise` → command) are correct.

### 3.2 Client: automatic retry with re-handshake

**Location:** `sendXFTPCommand` in `client.ts`

**Design:** Retry loop inside `sendXFTPCommand`. Maximum 3 attempts. On retriable error, close old client, re-handshake, retry.

**Error classification:**

| Error | Type | Retriable? | Human-readable message |
|-------|------|-----------|----------------------|
| Padded "HANDSHAKE" | Temporary | Yes (auto) | "Connection interrupted, reconnecting..." |
| Padded "SESSION" | Temporary | Yes (auto) | "Session expired, reconnecting..." |
| `FRErr SESSION` | Temporary | Yes (auto) | "Session expired, reconnecting..." |
| `FRErr HANDSHAKE` | Temporary | Yes (auto) | "Connection interrupted, reconnecting..." |
| `fetch()` TypeError | Temporary | Yes (auto) | "Network error, retrying..." |
| AbortError (timeout) | Temporary | Yes (auto) | "Server timeout, retrying..." |
| `FRErr AUTH` | Permanent | No | "File is invalid, expired, or has been removed" |
| `FRErr NO_FILE` | Permanent | No | "File not found — it may have expired" |
| `FRErr SIZE` | Permanent | No | "File size exceeds server limit" |
| `FRErr QUOTA` | Permanent | No | "Server storage quota exceeded" |
| `FRErr BLOCKED` | Permanent | No | "File has been blocked by server" |
| `FRErr DIGEST` | Permanent | No | "File integrity check failed" |
| `FRErr INTERNAL` | Permanent | No | "Server internal error" |
| `CMD *` | Permanent | No | "Protocol error" |

**Retry behavior:**
- Auto-retry up to 3 times for temporary errors, transparent to user
- After 3 failures: show human-readable error with diagnosis, offer manual retry button
- Permanent errors: show human-readable error immediately, NO manual retry button (user can reload page)

**Implementation:**

```typescript
async function sendXFTPCommand(
  agent: XFTPClientAgent,
  server: XFTPServer,
  privateKey: Uint8Array,
  entityId: Uint8Array,
  cmdBytes: Uint8Array,
  chunkData?: Uint8Array,
  maxRetries: number = 3
): Promise<{response: FileResponse, body: Uint8Array}> {
  let clientP = getXFTPServerClient(agent, server)
  let client = await clientP
  for (let attempt = 1; attempt <= maxRetries; attempt++) {
    try {
      return await sendXFTPCommandOnce(client, privateKey, entityId, cmdBytes, chunkData)
    } catch (e) {
      if (!isRetriable(e)) {
        // Permanent error (AUTH, NO_FILE, etc.) — connection is fine, don't touch it
        throw categorizeError(e)
      }
      if (attempt === maxRetries) {
        // Retriable error exhausted — connection is bad, remove stale promise
        removeStaleConnection(agent, server, clientP)
        throw categorizeError(e)
      }
      clientP = reconnectClient(agent, server)
      client = await clientP
    }
  }
  throw new Error("unreachable")
}
```

**`sendXFTPCommandOnce`** — renamed from current `sendXFTPCommand`. Two changes:

1. **Padded error detection** (before `decodeTransmission`):

```typescript
// After getting respBlock, before decodeTransmission:
const raw = blockUnpad(respBlock)
if (raw.length < 20) {
  const text = new TextDecoder().decode(raw)
  if (/^[A-Z_]+$/.test(text)) {
    throw new XFTPRetriableError(text)  // "HANDSHAKE" or "SESSION"
  }
}
```

2. **FRErr classification** (replaces current unconditional throw):

```typescript
// After decodeResponse, instead of throw new Error("Server error: " + err.type):
if (response.type === "FRErr") {
  const err = response.err
  if (err.type === "SESSION" || err.type === "HANDSHAKE") {
    throw new XFTPRetriableError(err.type)
  }
  throw new XFTPPermanentError(err.type, humanReadableMessage(err))
}
```

### 3.3 Client: fetch timeout

**Location:** `createBrowserTransport` and `createNodeTransport` in `client.ts`

**Design:** `AbortController` with configurable timeout on every `fetch()`.

```typescript
interface TransportConfig {
  timeoutMs: number  // default 30000, lower for tests
}

function createBrowserTransport(baseUrl: string, config: TransportConfig): Transport {
  return {
    async post(body: Uint8Array, headers?: Record<string, string>): Promise<Uint8Array> {
      const controller = new AbortController()
      const timer = setTimeout(() => controller.abort(), config.timeoutMs)
      try {
        const resp = await fetch(effectiveUrl, {
          method: "POST", headers, body,
          signal: controller.signal
        })
        if (!resp.ok) throw new Error(`Server request failed: ${resp.status}`)
        return new Uint8Array(await resp.arrayBuffer())
      } finally {
        clearTimeout(timer)
      }
    },
    close() {}
  }
}
```

For Node.js transport, use `setTimeout` on the HTTP/2 request stream.

Default: 30s for production, 5s for tests. Threaded through `connectXFTP` → `createTransport`.

### 3.4 UI: error categorization and retry

**Behavior (Option D):**

- **Temporary errors:** Auto-retry loop (3 attempts). After 3 failures, show human-readable diagnosis with manual retry button. Diagnosis examples: "Server timeout — the server may be temporarily unavailable", "Connection interrupted — your network may be unstable".
- **Permanent errors:** Show human-readable error immediately, NO retry button. User can reload page if they want to retry. Examples: "File is invalid, expired, or has been removed" (AUTH), "File not found" (NO_FILE).

**Current UI retry buttons:**
- `upload.ts:73-75` — retry calls `startUpload(pendingFile)` from scratch
- `download.ts:60` — retry calls `startDownload()` from scratch

**Improvement:** Track uploaded/downloaded chunk indices. On manual retry, skip completed chunks:

```typescript
// Upload: track which chunks completed
const completedChunks: Set<number> = new Set()
for (let i = 0; i < specs.length; i++) {
  if (completedChunks.has(i)) continue
  // ... create + upload chunk
  completedChunks.add(i)
}

// Download: already naturally resumable — each chunk is independent
```

### 3.5 Client: connection state with Promise-based lock and per-server queues

**Design:** Each server gets a `ServerConnection` record containing a `Promise<XFTPClient>` (the connection lock) and a `Promise<void>` (the sequential command queue). The `XFTPClientAgent` maps server keys to these records.

The promise IS the lock — every consumer awaits the same promise. When reconnect is needed, the promise is replaced atomically.

```typescript
interface ServerConnection {
  client: Promise<XFTPClient>   // resolves to connected client; replaced on reconnect
  queue: Promise<void>          // tail of sequential command chain
}

interface XFTPClientAgent {
  connections: Map<string, ServerConnection>
}

function newXFTPAgent(): XFTPClientAgent {
  return {connections: new Map()}
}
```

**Connection lifecycle — `getXFTPServerClient` and `reconnectClient`:**

```typescript
function getXFTPServerClient(agent: XFTPClientAgent, server: XFTPServer): Promise<XFTPClient> {
  const key = formatXFTPServer(server)
  let conn = agent.connections.get(key)
  if (!conn) {
    const p = connectXFTP(server)
    conn = {client: p, queue: Promise.resolve()}
    agent.connections.set(key, conn)
    // On connection failure, remove from map so next call retries
    p.catch(() => {
      const cur = agent.connections.get(key)
      if (cur && cur.client === p) agent.connections.delete(key)
    })
  }
  return conn.client
}

function reconnectClient(agent: XFTPClientAgent, server: XFTPServer): Promise<XFTPClient> {
  const key = formatXFTPServer(server)
  const old = agent.connections.get(key)
  // Close old client (fire-and-forget)
  old?.client.then(c => c.transport.close(), () => {})
  // Replace with new connection promise — all concurrent callers will await this
  // Queue survives reconnect — pending operations stay ordered
  const p = connectXFTP(server)
  const conn: ServerConnection = {client: p, queue: old?.queue ?? Promise.resolve()}
  agent.connections.set(key, conn)
  p.catch(() => {
    const cur = agent.connections.get(key)
    if (cur && cur.client === p) agent.connections.delete(key)
  })
  return p
}

function closeXFTPServerClient(agent: XFTPClientAgent, server: XFTPServer): void {
  const key = formatXFTPServer(server)
  const conn = agent.connections.get(key)
  if (conn) {
    agent.connections.delete(key)
    conn.client.then(c => c.transport.close(), () => {})
  }
}

function closeXFTPAgent(agent: XFTPClientAgent): void {
  for (const conn of agent.connections.values()) {
    conn.client.then(c => c.transport.close(), () => {})
  }
  agent.connections.clear()
}
```

**Precise semantics:**

1. `getXFTPServerClient(agent, server)` — returns existing `conn.client` promise if present, otherwise creates a new `ServerConnection` with fresh connection and empty queue
2. When error detected, first caller calls `reconnectClient` which replaces `conn.client` with a new connection promise. The queue is preserved across reconnect.
3. All concurrent callers awaiting the OLD promise receive the error
4. They then call `getXFTPServerClient` which returns the NEW promise
5. If reconnection fails, auto-cleanup (`p.catch(() => delete)`) removes the entry so the next caller starts fresh

**Stale error cleanup rule:** When a caller exhausts retries for a retriable error, it removes the failed entry from the map (only if no concurrent caller has already replaced it via `reconnectClient`). This prevents the next caller from receiving a stale rejected promise. Permanent errors (AUTH, NO_FILE, etc.) do NOT remove the connection — the transport is fine, only the command failed.

```typescript
function removeStaleConnection(
  agent: XFTPClientAgent, server: XFTPServer, failedP: Promise<XFTPClient>
): void {
  const key = formatXFTPServer(server)
  const conn = agent.connections.get(key)
  // Only remove if current promise is the one that failed — not if already replaced by reconnect
  if (conn && conn.client === failedP) {
    agent.connections.delete(key)
    failedP.then(c => c.transport.close(), () => {})
  }
}
```

**Per-server sequential queue:** `queue` is a `Promise<void>` — the tail of the sequential operation chain. Each new operation `.then()`s onto it. It's `void` because callers hold their own typed promises; the queue only tracks completion order:

```typescript
async function enqueueCommand<T>(
  agent: XFTPClientAgent,
  server: XFTPServer,
  fn: () => Promise<T>   // no client param — fn uses command wrappers (agent+server)
): Promise<T> {
  const key = formatXFTPServer(server)
  // Ensure connection exists (with auto-cleanup on failure)
  await getXFTPServerClient(agent, server)
  const conn = agent.connections.get(key)!  // guaranteed to exist after getXFTPServerClient
  // Chain onto the queue — fn runs after previous operation completes
  let resolve_: (v: T) => void, reject_: (e: any) => void
  const result = new Promise<T>((res, rej) => { resolve_ = res; reject_ = rej })
  conn.queue = conn.queue.then(
    () => fn().then(resolve_!, reject_!),
    () => fn().then(resolve_!, reject_!)
  ).then(() => {}, () => {})  // swallow errors in the chain
  return result
}
```

Commands to the same server execute one at a time via the queue. Commands to different servers execute concurrently because each has its own queue. `enqueueCommand` provides sequencing; `sendXFTPCommand` (called inside `fn` via command wrappers) provides retry. They compose as: `enqueueCommand` sequences calls to wrappers that internally use `sendXFTPCommand`.

**Download change:** Group chunks by server, process each server's chunks sequentially, servers in parallel. Uses `for` loop for per-server sequencing (same pattern as Stage 2 upload). `enqueueCommand` is available for cases where different callers target the same server.

```typescript
const byServer = new Map<string, FileChunk[]>()
for (const chunk of resolvedFd.chunks) {
  const srv = chunk.replicas[0]?.server ?? ""
  if (!byServer.has(srv)) byServer.set(srv, [])
  byServer.get(srv)!.push(chunk)
}
await Promise.all([...byServer.entries()].map(async ([srv, chunks]) => {
  const server = parseXFTPServer(srv)
  for (const chunk of chunks) {
    const seed = decodePrivKeyEd25519(chunk.replicas[0].replicaKey)
    const kp = ed25519KeyPairFromSeed(seed)
    const raw = await downloadXFTPChunkRaw(agent, server, kp.privateKey, chunk.replicas[0].replicaId)
    await onRawChunk({chunkNo: chunk.chunkNo, dhSecret: raw.dhSecret, nonce: raw.nonce, body: raw.body, digest: chunk.digest})
    downloaded += chunk.chunkSize
    onProgress?.(downloaded, resolvedFd.size)
  }
}))
```

### 3.6 Fix cache key

**Bug:** `getXFTPServerClient` (client.ts:110) uses `"https://" + server.host + ":" + server.port` as cache key, ignoring `keyHash`. Two servers with same host:port but different keyHash share a cached connection, bypassing identity verification.

**Fix:** Use `formatXFTPServer(server)` as cache key (includes keyHash). Already available in `protocol/address.ts:52-54`.

```typescript
// Before:
const key = "https://" + server.host + ":" + server.port

// After:
const key = formatXFTPServer(server)
```

Note: With the redesign in 3.5, the cache key fix is inherent — the `connections` Map uses `formatXFTPServer(server)` everywhere.

### 3.7 Phase 2: Multi-server upload with server selection and failover

**Problem:** Current upload (`agent.ts:105-157`) takes a single `server: XFTPServer` and uploads ALL chunks to it. The 12 preset servers (6 SimpleX + 6 Flux) are pointless — only one is ever used.

**Design goal:** Distribute chunks across servers. Retry FNEW on a different server if one fails. Once working servers are found, prefer them (heuristic: server unlikely to fail mid-process, more likely to be broken initially due to maintenance/downtime).

**Reference implementation:** Haskell `Agent.hs:457-486` (`createChunk` / `createWithNextSrv`) + `Client.hs:2335-2385` (`getNextServer_` / `withNextSrv`).

#### Haskell algorithm summary

Two-stage architecture:

1. **Allocate stage (serial per file in Haskell):** For each chunk, call FNEW on a randomly-selected server. If FNEW fails, pick a different server and retry. Track tried hosts to avoid retrying the same server. After all chunks are assigned to servers, spawn one upload worker per server.

2. **Upload stage (parallel per server):** Each server worker uploads its assigned chunks sequentially (FPUT). On FPUT failure, retry on the same server with backoff (because the chunk replica already exists on that server). No server failover for FPUT.

Server selection constraints (hierarchical, `getNextServer_` Client.hs:2335-2350):
1. Prefer servers from unused operators (operator diversity)
2. Prefer servers with unused hosts (host diversity)
3. Random pick from the most-constrained candidate set
4. If all exhausted, reset tried set and start over

#### Web client adaptation

The web client doesn't have operators or a database. Simplified algorithm with two stages:

**Stage 1 — Allocate:** Create chunk records on servers (FNEW). Unlike Haskell which is serial here, web FNEW runs concurrently within a concurrency limit. FNEW is a small command — concurrent FNEW on the same connection is not a problem, and concurrent FNEW across servers improves upload startup time.

**Stage 2 — Upload:** Upload chunk data (FPUT). Parallel across servers, sequential per server (reuses per-server queues from 3.5). FPUT retries on the same server with backoff — no server rotation because the chunk replica already exists on that server. Stage 2 reads chunk data by offset (via `readChunk`), so `SentChunk` must be extended with `chunkOffset: number` (from ChunkSpec).

```typescript
interface UploadState {
  untriedServers: XFTPServer[]    // servers not yet attempted — initially all servers
  workingServers: XFTPServer[]    // servers that succeeded FNEW
}

const MAX_FNEW_ATTEMPTS = 5  // per chunk: try up to 5 different servers

async function uploadFile(
  agent: XFTPClientAgent,
  allServers: XFTPServer[],
  encrypted: EncryptedFileMetadata,
  options?: UploadOptions
): Promise<UploadResult> {
  const state: UploadState = {untriedServers: [...allServers], workingServers: []}
  const specs = prepareChunkSpecs(encrypted.chunkSizes)
  const concurrency = options?.concurrency ?? 4

  // Stage 1: Allocate — concurrent FNEW within concurrency limit
  const sentChunks: SentChunk[] = new Array(specs.length)
  const queue = specs.map((spec, i) => ({spec, chunkNo: i + 1, index: i}))
  let idx = 0
  async function allocateWorker() {
    while (idx < queue.length) {
      const item = queue[idx++]
      const {server, chunk} = await createChunkWithFailover(
        agent, allServers, state, concurrency, item.spec, item.chunkNo
      )
      sentChunks[item.index] = chunk
    }
  }
  const allocateWorkers = Array.from(
    {length: Math.min(concurrency, queue.length)},
    () => allocateWorker()
  )
  await Promise.all(allocateWorkers)

  // Stage 2: Upload — parallel across servers, sequential per server
  // readChunk reads from the encrypted file by offset (same as Phase 1 uploadFile)
  let uploaded = 0
  const total = encrypted.chunkSizes.reduce((a, b) => a + b, 0)
  const byServer = groupBy(sentChunks, c => formatXFTPServer(c.server))
  await Promise.all([...byServer.entries()].map(async ([srvKey, chunks]) => {
    for (const chunk of chunks) {
      const chunkData = await readChunk(chunk.chunkOffset, chunk.chunkSize)
      await uploadXFTPChunk(agent, chunk.server, chunk.senderKey, chunk.senderId, chunkData)
      uploaded += chunk.chunkSize
      options?.onProgress?.(uploaded, total)
    }
  }))

  return buildDescriptions(encrypted, sentChunks)
}
```

**`createChunkWithFailover`** — server selection with per-chunk retry limit:

```typescript
async function createChunkWithFailover(
  agent: XFTPClientAgent,
  allServers: XFTPServer[],
  state: UploadState,
  concurrency: number,
  spec: ChunkSpec,
  chunkNo: number
): Promise<{server: XFTPServer, chunk: SentChunk}> {
  const maxAttempts = Math.min(allServers.length, MAX_FNEW_ATTEMPTS)

  for (let attempt = 0; attempt < maxAttempts; attempt++) {
    const server = pickServer(allServers, state, concurrency)
    try {
      const chunk = await createAndPrepareChunk(agent, server, spec, chunkNo)
      // Success — add to working set (if not already there)
      if (!state.workingServers.some(s => formatXFTPServer(s) === formatXFTPServer(server))) {
        state.workingServers.push(server)
      }
      return {server, chunk}
    } catch (e) {
      // Remove from working if it was there
      state.workingServers = state.workingServers.filter(
        s => formatXFTPServer(s) !== formatXFTPServer(server)
      )
      if (attempt === maxAttempts - 1) throw e
    }
  }
  throw new Error("unreachable")
}
```

**`pickServer`** — two-list selection:

```typescript
function pickServer(
  allServers: XFTPServer[],
  state: UploadState,
  concurrency: number
): XFTPServer {
  // Once enough working servers found, only use those
  if (state.workingServers.length >= concurrency) {
    return randomPick(state.workingServers)
  }
  // Still exploring — pick from untried
  if (state.untriedServers.length > 0) {
    const idx = Math.floor(Math.random() * state.untriedServers.length)
    return state.untriedServers.splice(idx, 1)[0]  // remove from untried
  }
  // All tried — reset untried to non-working servers and retry
  state.untriedServers = allServers.filter(
    s => !state.workingServers.some(w => formatXFTPServer(w) === formatXFTPServer(s))
  )
  if (state.untriedServers.length > 0) {
    const idx = Math.floor(Math.random() * state.untriedServers.length)
    return state.untriedServers.splice(idx, 1)[0]
  }
  // Every server is working — pick any working
  return randomPick(state.workingServers)
}
```

**Algorithm:** Two lists — `untriedServers` (initially all) and `workingServers` (initially empty). When `workingServers.length < concurrency`, pick from `untriedServers` (removing on pick). On FNEW success, add to `workingServers`. On FNEW failure, server is already removed from `untriedServers`; remove from `workingServers` if present. When `untriedServers` is empty, reset it to all non-working servers. Once `workingServers.length >= concurrency`, pick randomly only from `workingServers`.

**Termination condition:** Each chunk tries at most `min(serverCount, 5)` different servers. If all attempts fail, the chunk fails and the upload fails with the last error. Rationale: if 5 out of 12 servers are down, something systemic is wrong and continuing is unlikely to help. Timeouts count as failures — the timed-out server is removed from working and a different server is picked next.

**Key differences from Haskell:**
- No operator concept — just host diversity via random selection
- No database — state tracked in-memory during upload
- FNEW runs concurrently (Haskell is serial) — improves startup time
- FNEW is cheap and retried with server rotation; FPUT retries on same server

**Download changes (also Phase 2):** Default concurrency should be 4 (matching Haskell). Download already groups by server in 3.5. If `replicas[0]` download fails, try `replicas[1]`, `replicas[2]`, etc. (fallback across replicas).

## 4. Implementation Plan

### Phase 1: Error handling and connection resilience

Steps are ordered by dependency and should be implemented one by one.

#### Step 1: Fix cache key (3.6)
- Change cache key to `formatXFTPServer(server)` in `getXFTPServerClient` and `closeXFTPServerClient`
- Add import for `formatXFTPServer`
- Run existing tests to verify no regression

#### Step 2: Typed error detection for padded server errors (3.2 client-side)
- Add `XFTPRetriableError` class
- In `sendXFTPCommand`, detect padded error strings before `decodeTransmission`
- Classify `FRErr` responses as retriable or permanent with human-readable messages
- Run existing tests

#### Step 3: Fetch timeout (3.3)
- Add `TransportConfig` with `timeoutMs`
- Thread config through `createTransport` → `connectXFTP` → command wrappers
- Add `AbortController` to browser `fetch()` and `setTimeout` to Node.js HTTP/2
- Add vitest test: timeout triggers after configured duration
- Run existing tests

#### Step 4: Connection state with Promise-based lock and per-server queues (3.5)
- Introduce `ServerConnection` record: `{client: Promise<XFTPClient>, queue: Promise<void>}`
- Replace `XFTPClientAgent.clients: Map<string, XFTPClient>` with `connections: Map<string, ServerConnection>`
- Implement `reconnectClient` — replaces `conn.client` with new promise, preserves queue
- Implement `enqueueCommand` — chains operation onto server's queue
- Implement `removeStaleConnection` — removes entry only if current promise is the failed one
- Auto-cleanup: `p.catch(() => delete)` removes failed connections so next caller starts fresh
- Adapt `closeXFTPServerClient` and `closeXFTPAgent`
- Add vitest tests:
  - Concurrent calls to same server produce single connection
  - Failed promise is cleaned up, next caller gets fresh connection

#### Step 5: Automatic retry in sendXFTPCommand (3.2)
- Add retry loop with reconnect
- Change `sendXFTPCommand` signature: takes `agent + server` instead of `client`; export it (needed by tests and by agent.ts callers)
- Rename current `sendXFTPCommand` → `sendXFTPCommandOnce` (private); add padded error detection + FRErr classification (throw `XFTPRetriableError` for SESSION/HANDSHAKE, `XFTPPermanentError` for AUTH/NO_FILE/etc.)
- All command wrappers (`createXFTPChunk`, `uploadXFTPChunk`, etc.) pass agent + server
- Update agent.ts call sites: remove `getXFTPServerClient` calls before command wrappers (in `uploadFile`, `uploadRedirectDescription`, `downloadFileRaw`, `resolveRedirect`, `deleteFile`)
- Max 3 retries for retriable errors, immediate throw for permanent
- On retriable error: call `reconnectClient` and retry. On retriable error exhausted: call `removeStaleConnection` to clean up. On permanent error: throw immediately without touching connection
- Add vitest tests:
  - Server started with delay → first attempt fails, retry succeeds
  - 3 retries exhausted → error propagates with human-readable message
  - Non-retriable error (AUTH) → no retry, immediate failure

#### Step 6: Server-side stale session handling (3.1)
- Add one guard to `Nothing` branch: `sniUsed && not webHello -> throwE SESSION`
- Remove debug `hPutStrLn stderr` lines (all 6 occurrences in dispatch)
- All other branches unchanged
- Run Haskell tests + Playwright tests

#### Step 7: Download with per-server grouping
- Modify `downloadFileRaw` to group chunks by server, sequential within each server (`for` loop), parallel across servers (`Promise.all`)
- Add vitest test: concurrent downloads from different servers run in parallel

#### Step 8: UI error improvements (3.4)
- Temporary errors: auto-retry loop (3 attempts), then show human-readable diagnosis + manual retry button
- Permanent errors: show human-readable error, NO retry button
- Manual retry resumes from last successful chunk (not full restart)

#### Step 9: Remove debug logging
- Remove all `console.log('[DEBUG ...]')` and `hPutStrLn stderr "DEBUG ..."` lines
- Keep `console.error('[XFTP] ...')` error logging

### Phase 2: Multi-server upload

Implement after Phase 1 is complete and tested.

#### Step 10: Multi-server upload with failover (3.7)
- Extend `SentChunk` with `chunkOffset: number` (from ChunkSpec) and `server: XFTPServer` (assigned during allocate) — Stage 2 reads data by offset and groups chunks by server
- Change `uploadFile` signature: takes `allServers: XFTPServer[]` instead of single `server`
- Implement `UploadState` with `untriedServers` and `workingServers`
- Implement `createChunkWithFailover` and `pickServer`: two-list selection (untried → working once enough found), max `min(serverCount, 5)` attempts per chunk
- Allocate stage: concurrent FNEW within concurrency limit (default 4)
- Upload stage: parallel across servers, sequential per server (reuse queue from Step 7)
- Update `web/upload.ts`: pass `getServers()` instead of `pickRandomServer(getServers())`
- Update description building: each chunk references its actual server
- Add vitest tests:
  - File split across N servers (verify different servers in description)
  - One server down → chunks redistributed to others
  - All servers down → error after exhausting 5 attempts per chunk

#### Step 11: Download concurrency and replica fallback
- Change default download concurrency from 1 to 4
- If `replicas[0]` download fails, try `replicas[1]`, `replicas[2]`, etc.
- Uses per-server queues from Step 7

## 5. Testing Plan

### Principle

Prefer low-level vitest tests over Playwright E2E. Each new function gets one focused test. Pure functions tested without mocks; connection management tested with mock `connectXFTP`; server behavior tested with real server. Total: 13 tests across 4 files.

Tests A-C run in browser context (`@vitest/browser` with Chromium headless), configured in `vitest.config.ts`. Test D (integration) requires a separate Node.js vitest config since it uses `node:http2`. Existing `globalSetup.ts` provides a real XFTP server for integration tests.

### Test file A: `test/errors.test.ts` — pure, no server

Tests error classification and padded error detection (Steps 2, 5).

**T1. `isRetriable` classifies errors correctly**
```typescript
// Retriable:
expect(isRetriable(new XFTPRetriableError("SESSION"))).toBe(true)
expect(isRetriable(new XFTPRetriableError("HANDSHAKE"))).toBe(true)
expect(isRetriable(new TypeError("fetch failed"))).toBe(true)          // network error
expect(isRetriable(Object.assign(new Error(), {name: "AbortError"}))).toBe(true)  // timeout
// Not retriable:
expect(isRetriable(new XFTPPermanentError("AUTH", "..."))).toBe(false)
expect(isRetriable(new XFTPPermanentError("NO_FILE", "..."))).toBe(false)
expect(isRetriable(new XFTPPermanentError("INTERNAL", "..."))).toBe(false)
```

**T2. `categorizeError` produces human-readable messages**
```typescript
// categorizeError receives thrown errors (from sendXFTPCommandOnce or transport)
const e = categorizeError(new XFTPPermanentError("AUTH", "File is invalid, expired, or has been removed"))
expect(e.message).toContain("expired")
// Verify every permanent error type maps to a non-empty human-readable message
for (const errType of ["AUTH", "NO_FILE", "SIZE", "QUOTA", "BLOCKED", "DIGEST", "INTERNAL"]) {
  expect(humanReadableMessage({type: errType}).length).toBeGreaterThan(0)
}
// Retriable errors also get human-readable messages after exhaustion
const re = categorizeError(new XFTPRetriableError("SESSION"))
expect(re.message).toContain("expired")  // "Session expired, reconnecting..."
```

**T3. Padded error detection extracts error string from padded block**
```typescript
import {blockPad, blockUnpad} from '../src/protocol/transmission.js'
// Simulate server sending padded "SESSION"
const padded = blockPad(new TextEncoder().encode("SESSION"))
const raw = blockUnpad(padded)
expect(raw.length).toBeLessThan(20)
expect(new TextDecoder().decode(raw)).toBe("SESSION")
// Normal transmission block (batch count + large-encoded data) is NOT a short string
const sessionId = new Uint8Array(32)  // dummy
const normalBlock = encodeTransmission(sessionId, new Uint8Array(0), new Uint8Array(0), encodePING())
const normalRaw = blockUnpad(normalBlock)
expect(normalRaw.length).toBeGreaterThan(20)  // not mistaken for padded error
```

### Test file B: `test/connection.test.ts` — mock connectXFTP, no server

Tests connection management functions (Steps 4, 5). Uses `vi.mock` to replace `connectXFTP` with a controllable promise factory.

**T4. `getXFTPServerClient` coalesces concurrent calls**
```typescript
// Mock connectXFTP to return a deferred promise
const {promise, resolve} = promiseWithResolvers<XFTPClient>()
vi.mocked(connectXFTP).mockReturnValueOnce(promise)
const agent = newXFTPAgent()
const p1 = getXFTPServerClient(agent, server)
const p2 = getXFTPServerClient(agent, server)
expect(p1).toBe(p2)  // same promise, single connection
resolve(mockClient)
expect(await p1).toBe(mockClient)
```

**T5. `getXFTPServerClient` auto-cleans failed connections**
```typescript
vi.mocked(connectXFTP).mockReturnValueOnce(Promise.reject(new Error("down")))
const agent = newXFTPAgent()
const p1 = getXFTPServerClient(agent, server)
await expect(p1).rejects.toThrow("down")
// After microtask, entry is removed
await new Promise(r => setTimeout(r, 0))
expect(agent.connections.has(formatXFTPServer(server))).toBe(false)
// Next call creates fresh connection
vi.mocked(connectXFTP).mockReturnValueOnce(Promise.resolve(mockClient))
const p2 = getXFTPServerClient(agent, server)
expect(p2).not.toBe(p1)
```

**T6. `removeStaleConnection` respects promise identity**
```typescript
const agent = newXFTPAgent()
const p1 = Promise.resolve(mockClient)
agent.connections.set(key, {client: p1, queue: Promise.resolve()})
// Replace with reconnect
const p2 = Promise.resolve(mockClient2)
agent.connections.set(key, {client: p2, queue: Promise.resolve()})
// removeStaleConnection with old promise does NOT remove new entry
removeStaleConnection(agent, server, p1)
expect(agent.connections.has(key)).toBe(true)
expect(agent.connections.get(key)!.client).toBe(p2)
// removeStaleConnection with current promise removes it
removeStaleConnection(agent, server, p2)
expect(agent.connections.has(key)).toBe(false)
```

**T7. `reconnectClient` replaces promise but preserves queue**
```typescript
const agent = newXFTPAgent()
const origQueue = Promise.resolve()
agent.connections.set(key, {client: Promise.resolve(mockClient), queue: origQueue})
vi.mocked(connectXFTP).mockReturnValueOnce(Promise.resolve(mockClient2))
reconnectClient(agent, server)
const conn = agent.connections.get(key)!
expect(await conn.client).toBe(mockClient2)  // new client
expect(conn.queue).toBe(origQueue)            // queue preserved
```

**T8. Retry loop: retriable error triggers reconnect, permanent error does not**

Mock approach: `vi.mock('../src/client.js')` to mock `connectXFTP` (exported). `reconnectClient` is not exported — its behavior is controlled indirectly via `connectXFTP` mock (it calls `connectXFTP` internally). Verify retry count via `connectXFTP` call count. Note: vitest module mocking may need adjustment depending on ESM transform behavior — if intra-module calls bypass the mock, extract `connectXFTP` to a separate module or use dependency injection for testing.

```typescript
// Script: first connectXFTP returns client whose post throws retriable,
// second connectXFTP (from reconnect) returns client whose post succeeds
vi.mocked(connectXFTP)
  .mockResolvedValueOnce({
    ...mockClient,
    transport: { post: async () => { throw new XFTPRetriableError("SESSION") }, close: () => {} }
  })
  .mockResolvedValueOnce({
    ...mockClient,
    transport: { post: async () => okResponseBlock, close: () => {} }
  })

const agent = newXFTPAgent()
const result = await sendXFTPCommand(agent, server, dummyKey, dummyId, encodePING())
expect(result.response.type).toBe("FROk")
expect(vi.mocked(connectXFTP)).toHaveBeenCalledTimes(2)  // initial + 1 reconnect

// Reset — all 3 retries exhausted: connectXFTP called 3 times (initial + 2 reconnects)
vi.mocked(connectXFTP).mockClear()
vi.mocked(connectXFTP).mockResolvedValue({
  ...mockClient,
  transport: { post: async () => { throw new XFTPRetriableError("SESSION") }, close: () => {} }
})
const agent2 = newXFTPAgent()
await expect(sendXFTPCommand(agent2, server, dummyKey, dummyId, encodePING()))
  .rejects.toThrow(/reconnecting|expired/)
expect(vi.mocked(connectXFTP)).toHaveBeenCalledTimes(3)  // initial + 2 reconnects

// Reset — permanent error: connectXFTP called once (initial only, no reconnect)
vi.mocked(connectXFTP).mockClear()
vi.mocked(connectXFTP).mockResolvedValue({
  ...mockClient,
  transport: { post: async () => authErrorBlock, close: () => {} }
})
const agent3 = newXFTPAgent()
await expect(sendXFTPCommand(agent3, server, dummyKey, dummyId, encodePING()))
  .rejects.toThrow(/expired/)
expect(vi.mocked(connectXFTP)).toHaveBeenCalledTimes(1)  // initial only, no reconnect
```

### Test file C: `test/server-selection.test.ts` — pure, no server

Tests `pickServer` state machine (Step 10). Determinism: seed `Math.random` or test invariants not specific picks.

**T9. `pickServer` picks from untried when working < concurrency**
```typescript
const servers = [s1, s2, s3, s4, s5]
const state: UploadState = {untriedServers: [...servers], workingServers: []}
const picked = pickServer(servers, state, 4)
// picked is from untried, and was removed from untried
expect(state.untriedServers.length).toBe(4)
expect(state.untriedServers).not.toContainEqual(picked)
```

**T10. `pickServer` picks only from working when working >= concurrency**
```typescript
const state: UploadState = {
  untriedServers: [s5],  // still has untried
  workingServers: [s1, s2, s3, s4]
}
const picked = pickServer(servers, state, 4)
// Must pick from working, NOT from untried
expect([s1, s2, s3, s4]).toContainEqual(picked)
expect(state.untriedServers.length).toBe(1)  // untried unchanged
```

**T11. `pickServer` resets untried when exhausted**
```typescript
const state: UploadState = {
  untriedServers: [],        // all tried
  workingServers: [s1, s2]   // only 2 working, concurrency=4
}
const picked = pickServer(servers, state, 4)
// Should have reset untried to non-working servers and picked from them
expect([s3, s4, s5]).toContainEqual(picked)
expect(state.untriedServers.length).toBe(2)  // 3 non-working minus 1 picked
```

### Test file D: `test/integration.test.ts` — real server, Node.js mode

Requires separate vitest config with `browser: {enabled: false}` since these tests use `node:http2` directly. Alternatively, add `test/vitest.node.config.ts` that includes only `test/integration.test.ts` and runs in Node.js.

**T12. Stale session returns padded SESSION error (requires Step 6)**
```typescript
import http2 from 'node:http2'
// Connect and handshake normally via the client
const client = await connectXFTP(server)
// Create a raw HTTP/2 session (new TLS SessionId, no handshake state on server)
const session = http2.connect(client.baseUrl, {rejectUnauthorized: false})
// Build a dummy command block using the old client's sessionId.
// Content doesn't matter — server detects stale session before parsing command.
const dummyKey = new Uint8Array(64)  // Ed25519 private key (dummy)
const dummyId = new Uint8Array(24)   // entity ID (dummy)
const cmdBlock = encodeAuthTransmission(client.sessionId, new Uint8Array(0), dummyId, encodePING(), dummyKey)
const resp = await new Promise<Uint8Array>((resolve, reject) => {
  const req = session.request({":method": "POST", ":path": "/"})
  const chunks: Buffer[] = []
  req.on("data", (c: Buffer) => chunks.push(c))
  req.on("end", () => resolve(new Uint8Array(Buffer.concat(chunks))))
  req.on("error", reject)
  req.end(Buffer.from(cmdBlock))
})
// Server should return padded "SESSION" (not crash, not "HANDSHAKE")
const raw = blockUnpad(resp.subarray(0, XFTP_BLOCK_SIZE))
expect(new TextDecoder().decode(raw)).toBe("SESSION")
session.close()
closeXFTP(client)
```

**T13. Fetch timeout fires within configured duration**
```typescript
// connectXFTP with 1ms timeout — handshake requires multiple round trips,
// so even on localhost it will exceed 1ms and trigger abort
await expect(
  connectXFTP(server, {timeoutMs: 1})
).rejects.toThrow(/abort|timeout/i)
```

### What existing tests already cover (no new tests needed)

| Behavior | Covered by |
|----------|-----------|
| Cache key fix (Step 1) | Existing round-trip test — uses `formatXFTPServer` after refactor |
| Basic upload/download | 24 Playwright tests + 1 vitest browser test |
| File size limits, unicode filenames | Playwright edge case tests |
| Server startup/teardown | `globalSetup.ts` / `globalTeardown.ts` |
| Handshake + identity verification | `connectXFTP` in existing round-trip test |

### Test ordering

Tests must be added alongside their implementation step:
- **Step 2**: Add T1, T2, T3 (test/errors.test.ts)
- **Step 3**: Add T13 (test/integration.test.ts) — requires Node.js vitest config
- **Step 4**: Add T4, T5, T6, T7 (test/connection.test.ts)
- **Step 5**: Add T8 (test/connection.test.ts)
- **Step 6**: Add T12 (test/integration.test.ts) — requires server change + Node.js vitest config
- **Step 10**: Add T9, T10, T11 (test/server-selection.test.ts)

## 6. Context for Implementation Sessions

### Files to re-read on session start

**TypeScript (xftp-web/src/):**
- `client.ts` — `XFTPClient`, `XFTPClientAgent`, `getXFTPServerClient`, `closeXFTPServerClient`, `connectXFTP`, `sendXFTPCommand`, `createBrowserTransport`, `createNodeTransport`, all command wrappers
- `agent.ts` — `uploadFile`, `downloadFileRaw`, `downloadFile`, `resolveRedirect`, `encryptFileForUpload`
- `protocol/transmission.ts` — `encodeAuthTransmission`, `decodeTransmission`, `blockPad`, `blockUnpad`
- `protocol/commands.ts` — `XFTPErrorType`, `FileResponse`, `decodeResponse`, `decodeXFTPError`
- `protocol/handshake.ts` — `decodeServerHandshake` (padded error detection heuristic)
- `protocol/address.ts` — `XFTPServer`, `parseXFTPServer`, `formatXFTPServer`
- `web/upload.ts` — UI error handling, retry button
- `web/download.ts` — UI error handling, retry button
- `web/servers.ts` — `getServers`, `pickRandomServer`

**TypeScript (xftp-web/test/):**
- `browser.test.ts` — vitest Node.js test template (uses real Haskell server)
- `globalSetup.ts` — server startup, config generation, port file
- `page.spec.ts` — Playwright page tests

**Haskell (reference for multi-server):**
- `src/Simplex/FileTransfer/Agent.hs` — `createChunk` (lines 457-486, allocate stage), `runXFTPSndPrepareWorker` (lines 391-430, serial allocate in Haskell), `runXFTPSndWorker` (lines 494-548, per-server upload worker)
- `src/Simplex/Messaging/Agent/Client.hs` — `getNextServer_` (lines 2335-2350), `withNextSrv` (lines 2366-2385), `pickServer` (lines 2309-2314)

**Haskell (server):**
- `src/Simplex/FileTransfer/Server.hs` — `xftpServerHandshakeV1` (lines 165-244), `processRequest` (lines 403-435)
- `src/Simplex/Messaging/Protocol.hs` — `tDecodeServer` (lines 2239-2265) — sessionId verification at line 2242

### Key design constraints

1. `tDecodeServer` (Protocol.hs:2242) verifies `sessId == sessionId` — commands signed with old sessionId WILL fail on new connection
2. Server generates per-session DH key in `processHello` (Server.hs:207) — cannot be shared across sessions
3. `fetch()` provides zero control over HTTP/2 connection reuse — browser decides
4. `xftp-web-hello` header is only checked in dispatch (Server.hs:192), NOT inside `processHello`
5. Handshake-phase errors are raw padded strings; command-phase errors are proper ERR transmissions
6. Ed25519 signature verification (`TASignature` path, Protocol.hs:1314) does NOT use `thAuth` — but SMP will
7. Reconnect must re-handshake to get new sessionId AND new server DH key
8. The new `throwE SESSION` guard (Step 6) sends a raw padded "SESSION" string — no sessionId framing. Client detects this via padded error heuristic (section 3.2), not via sessionId mismatch
9. FNEW is cheap (creates chunk record on server) — retry with different server on failure
10. FPUT retries on same server (chunk replica already exists there) — close connection + backoff

## 7. Plan Maintenance

This plan must be updated as implementation proceeds:
- Mark completed steps with date
- Record any deviations from the plan with rationale
- Add new issues discovered during implementation
- Update file references if code moves
