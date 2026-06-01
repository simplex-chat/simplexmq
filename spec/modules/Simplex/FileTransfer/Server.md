# Simplex.FileTransfer.Server

> XFTP router: HTTP/2 request handling, handshake state machine, data packet operations, and statistics.

**Source**: [`FileTransfer/Server.hs`](../../../../src/Simplex/FileTransfer/Server.hs)

## Architecture

The XFTP router runs several concurrent threads via `raceAny_`:

| Thread | Purpose |
|--------|---------|
| `runServer` | HTTP/2 router accepting data packet transfer requests |
| `expireFiles` | Periodic data packet expiration with throttling |
| `logServerStats` | Periodic stats flush to CSV |
| `savePrometheusMetrics` | Periodic Prometheus metrics dump |
| `runCPServer` | Control port for admin commands |

See [spec/routers.md](../../routers.md) for component and sequence diagrams.

## Non-obvious behavior

### 1. Three-state handshake with session caching

The router maintains a `TMap SessionId Handshake` with three states:
- **No entry**: first request — for non-SNI or `xftp-web-hello` requests, `processHello` generates DH key pair and sends router handshake; for SNI requests without `xftp-web-hello`, returns `SESSION` error
- **`HandshakeSent pk`**: router hello sent, waiting for client handshake with version negotiation
- **`HandshakeAccepted thParams`**: handshake complete, subsequent requests use cached params

Web clients can re-send hello (`xftp-web-hello` header) even in `HandshakeSent` or `HandshakeAccepted` states — the router reuses the existing private key rather than generating a new one.

### 2. Web identity proof via challenge-response

When a web client sends a hello with a non-empty body, the router parses an `XFTPClientHello` containing a `webChallenge`. The router signs `challenge <> sessionId` with its long-term key and includes the signature in the handshake result. This proves router identity to web clients that cannot verify TLS certificates directly.

### 3. skipCommitted drains request body on re-upload

If `receiveServerFile` detects the data packet is already uploaded (`filePath` TVar is `Just`), it cannot simply ignore the request body — the HTTP/2 client would block waiting for the router to consume it. Instead, `skipCommitted` reads and discards the entire body in `fileBlockSize` increments, returning `FROk` when complete. This makes FPUT idempotent from the client's perspective.

### 4. Atomic quota reservation with rollback

`receiveServerFile` uses `stateTVar` to atomically check and reserve storage quota before receiving the data packet. If the upload fails (timeout, size mismatch, IO error), the reserved size is subtracted from `usedStorage` and the partial data packet is deleted on the router. This prevents failed uploads from permanently consuming quota.

### 5. retryAdd generates new IDs on collision

`createFile` and `addRecipient` use `retryAdd` which generates a random ID and makes up to 3 total attempts (initial + 2 retries) on `DUPLICATE_` errors. This handles the astronomically unlikely case of random ID collision without requiring uniqueness checking before insertion.

### 6. Timing attack mitigation on entity lookup

`verifyXFTPTransmission` calls `dummyVerifyCmd` (imported from SMP router) when a data packet entity is not found. This equalizes result timing to prevent attackers from distinguishing "entity doesn't exist" from "signature invalid" based on latency.

### 7. BLOCKED vs EntityOff distinction

When `verifyXFTPTransmission` reads `fileStatus`:
- `EntityActive` → proceed with command
- `EntityBlocked info` → return `BLOCKED` with blocking reason
- `EntityOff` → return `AUTH` (same as entity-not-found)

`EntityOff` is treated identically to missing entities for information-hiding purposes.

### 8. blockServerFile deletes the stored data packet

Despite the name suggesting it only marks a data packet as blocked, `blockServerFile` also deletes the stored data packet from disk via `deleteOrBlockServerFile_`. The `deleted = True` parameter to `blockFile` in the store adjusts `usedStorage`. A blocked data packet returns `BLOCKED` errors on access but has no data on disk.

### 9. Stats restore overrides counts from live store

`restoreServerStats` loads stats from the backup file but overrides `_filesCount` and `_filesSize` with values computed from the live file store (TMap size and `usedStorage` TVar). If the backup values differ, warnings are logged. This handles cases where data packets were expired or deleted while the router was down.

### 10. Data packet expiration with configurable throttling

`expireServerFiles` accepts an optional `itemDelay` (100ms when called from the periodic thread, `Nothing` at router startup). Between each data packet check, `threadDelay itemDelay` prevents expiration from monopolizing IO. At startup, data packets are expired without delay to clean up quickly.

### 11. Stats log aligns to wall-clock midnight

`logServerStats` computes an `initialDelay` to align the first stats flush to `logStatsStartTime` (default 0 = midnight UTC). If the target time already passed today, it adds 86400 seconds for the next day. Subsequent flushes use exact `logInterval` cadence.

### 12. Stored data packet deleted before store cleanup

`deleteOrBlockServerFile_` removes the stored data packet first, then runs the STM store action. If the process crashes between these two operations, the store will reference a data packet that no longer exists on disk. The next access would return `AUTH` (data packet not found on disk), and eventual expiration would clean the store entry.

### 13. SNI-dependent CORS and web serving

CORS headers require both `sniUsed = True` and `addCORSHeaders = True` in the transport config. Static web page serving is enabled when `sniUsed = True`. Non-SNI connections (direct TLS without hostname) skip both CORS and web serving. This separates the web-facing and protocol-facing behaviors of the same router port.

### 14. Control port data packet operations use recipient index

`CPDelete` and `CPBlock` commands look up data packets via `getFile fs SFRecipient fileId`, meaning the control port takes a recipient ID, not a sender ID. This is the ID visible to recipients and contained in data packet descriptions.
