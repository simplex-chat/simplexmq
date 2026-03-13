# Simplex.FileTransfer.Server

> XFTP server: HTTP/2 request handling, handshake state machine, file operations, and statistics.

**Source**: [`FileTransfer/Server.hs`](../../../../src/Simplex/FileTransfer/Server.hs)

## Architecture

The XFTP server runs several concurrent threads via `raceAny_`:

| Thread | Purpose |
|--------|---------|
| `runServer` | HTTP/2 server accepting file transfer requests |
| `expireFiles` | Periodic file expiration with throttling |
| `logServerStats` | Periodic stats flush to CSV |
| `savePrometheusMetrics` | Periodic Prometheus metrics dump |
| `runCPServer` | Control port for admin commands |

## Non-obvious behavior

### 1. Three-state handshake with session caching

The server maintains a `TMap SessionId Handshake` with three states:
- **No entry**: first request — for non-SNI or `xftp-web-hello` requests, `processHello` generates DH key pair and sends server handshake; for SNI requests without `xftp-web-hello`, returns `SESSION` error
- **`HandshakeSent pk`**: server hello sent, waiting for client handshake with version negotiation
- **`HandshakeAccepted thParams`**: handshake complete, subsequent requests use cached params

Web clients can re-send hello (`xftp-web-hello` header) even in `HandshakeSent` or `HandshakeAccepted` states — the server reuses the existing private key rather than generating a new one.

### 2. Web identity proof via challenge-response

When a web client sends a hello with a non-empty body, the server parses an `XFTPClientHello` containing a `webChallenge`. The server signs `challenge <> sessionId` with its long-term key and includes the signature in the handshake response. This proves server identity to web clients that cannot verify TLS certificates directly.

### 3. skipCommitted drains request body on re-upload

If `receiveServerFile` detects the file is already uploaded (`filePath` TVar is `Just`), it cannot simply ignore the request body — the HTTP/2 client would block waiting for the server to consume it. Instead, `skipCommitted` reads and discards the entire body in `fileBlockSize` increments, returning `FROk` when complete. This makes FPUT idempotent from the client's perspective.

### 4. Atomic quota reservation with rollback

`receiveServerFile` uses `stateTVar` to atomically check and reserve storage quota before receiving the file. If the upload fails (timeout, size mismatch, IO error), the reserved size is subtracted from `usedStorage` and the partial file is deleted. This prevents failed uploads from permanently consuming quota.

### 5. retryAdd generates new IDs on collision

`createFile` and `addRecipient` use `retryAdd` which generates a random ID and makes up to 3 total attempts (initial + 2 retries) on `DUPLICATE_` errors. This handles the astronomically unlikely case of random ID collision without requiring uniqueness checking before insertion.

### 6. Timing attack mitigation on entity lookup

`verifyXFTPTransmission` calls `dummyVerifyCmd` (imported from SMP server) when a file entity is not found. This equalizes response timing to prevent attackers from distinguishing "entity doesn't exist" from "signature invalid" based on latency.

### 7. BLOCKED vs EntityOff distinction

When `verifyXFTPTransmission` reads `fileStatus`:
- `EntityActive` → proceed with command
- `EntityBlocked info` → return `BLOCKED` with blocking reason
- `EntityOff` → return `AUTH` (same as entity-not-found)

`EntityOff` is treated identically to missing entities for information-hiding purposes.

### 8. blockServerFile deletes the physical file

Despite the name suggesting it only marks a file as blocked, `blockServerFile` also deletes the physical file from disk via `deleteOrBlockServerFile_`. The `deleted = True` parameter to `blockFile` in the store adjusts `usedStorage`. A blocked file returns `BLOCKED` errors on access but has no data on disk.

### 9. Stats restore overrides counts from live store

`restoreServerStats` loads stats from the backup file but overrides `_filesCount` and `_filesSize` with values computed from the live file store (TMap size and `usedStorage` TVar). If the backup values differ, warnings are logged. This handles cases where files were expired or deleted while the server was down.

### 10. File expiration with configurable throttling

`expireServerFiles` accepts an optional `itemDelay` (100ms when called from the periodic thread, `Nothing` at startup). Between each file check, `threadDelay itemDelay` prevents expiration from monopolizing IO. At startup, files are expired without delay to clean up quickly.

### 11. Stats log aligns to wall-clock midnight

`logServerStats` computes an `initialDelay` to align the first stats flush to `logStatsStartTime` (default 0 = midnight UTC). If the target time already passed today, it adds 86400 seconds for the next day. Subsequent flushes use exact `logInterval` cadence.

### 12. Physical file deleted before store cleanup

`deleteOrBlockServerFile_` removes the physical file first, then runs the STM store action. If the process crashes between these two operations, the store will reference a file that no longer exists on disk. The next access would return `AUTH` (file not found on disk), and eventual expiration would clean the store entry.

### 13. SNI-dependent CORS and web serving

CORS headers require both `sniUsed = True` and `addCORSHeaders = True` in the transport config. Static web page serving is enabled when `sniUsed = True`. Non-SNI connections (direct TLS without hostname) skip both CORS and web serving. This separates the web-facing and protocol-facing behaviors of the same port.

### 14. Control port file operations use recipient index

`CPDelete` and `CPBlock` commands look up files via `getFile fs SFRecipient fileId`, meaning the control port takes a recipient ID, not a sender ID. This is the ID visible to recipients and contained in file descriptions.
