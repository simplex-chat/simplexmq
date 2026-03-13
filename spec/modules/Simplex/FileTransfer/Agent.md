# Simplex.FileTransfer.Agent

> XFTP agent: worker-based file send/receive/delete with retry, encryption, redirect chains, and file description generation.

**Source**: [`FileTransfer/Agent.hs`](../../../../src/Simplex/FileTransfer/Agent.hs)

## Architecture

The XFTP agent uses five worker types organized in three categories:

| Worker | Key (router) | Purpose |
|--------|-------------|---------|
| `xftpRcvWorker` | `Just server` | Download chunks from a specific XFTP router |
| `xftpRcvLocalWorker` | `Nothing` | Decrypt completed downloads locally |
| `xftpSndPrepareWorker` | `Nothing` | Encrypt files and create chunks on routers |
| `xftpSndWorker` | `Just server` | Upload chunks to a specific XFTP router |
| `xftpDelWorker` | `Just server` | Delete chunks from a specific XFTP router |

Workers are created on-demand via `getAgentWorker` and keyed by router address. The local workers (keyed by `Nothing`) handle CPU-bound operations that don't require network access.

## Non-obvious behavior

### 1. startXFTPWorkers vs startXFTPSndWorkers

`startXFTPWorkers` starts all three worker categories (rcv, snd, del). `startXFTPSndWorkers` starts only snd workers. This distinction exists because receiving and deleting require a full agent context, while sending can operate with a partial setup (used when the agent is in send-only mode).

### 2. Download completion triggers local worker

When `downloadFileChunk` determines that all chunks are received (`all chunkReceived chunks`), it calls `getXFTPRcvWorker True c Nothing` to wake the local decryption worker. The `True` parameter signals that work is available. Without this, the local worker would sleep until the next `waitForWork` check.

### 3. Decryption verifies both digest and size before decrypting

`decryptFile` first computes the total size of all encrypted chunk files, then their SHA-512 digest. If either mismatches the expected values, it throws an error *before* starting decryption. This prevents wasting CPU on corrupted or tampered downloads.

### 4. Redirect chain with depth limit

When a received file has a `redirect`, the local worker:
1. Decrypts the redirect file (a YAML file description)
2. Validates the inner description's size and digest against `RedirectFileInfo`
3. Registers the inner file's chunks and starts downloading them

The redirect chain is implicitly limited to depth 1: `createRcvFileRedirect` creates the destination file entry with `redirect = Nothing`, and `updateRcvFileRedirect` does not update the redirect column. So even if the decoded inner description contains a redirect field, the database record for the destination file has no redirect, preventing further chaining.

### 5. Decrypting worker resumes from RFSDecrypting

If the agent restarts while a file is in `RFSDecrypting` status, the local worker detects this and deletes the partially-decrypted output file before restarting decryption. This prevents corrupted output from a previous incomplete decryption attempt.

### 6. Encryption worker resumes from SFSEncrypting

Similarly, `prepareFile` checks `status /= SFSEncrypted` and deletes the partial encrypted file if status is `SFSEncrypting`. This allows clean restart of interrupted encryption.

### 7. Redirect files must be single-chunk

`encryptFileForUpload` for redirect files calls `singleChunkSize` instead of `prepareChunkSizes`. If the redirect file description doesn't fit in a single chunk, it throws `FILE SIZE`. This ensures redirect files are atomic — they either download completely or not at all.

### 8. addRecipients recursive batching

During upload, `addRecipients` recursively calls itself if a chunk needs more recipients than `xftpMaxRecipientsPerRequest`. Each iteration sends an FADD command for up to `maxRecipients` new recipients, accumulates the results, and recurses until all recipients are registered.

### 9. File description generation cross-product

`createRcvFileDescriptions` (in both `Agent.hs` and `Client/Main.hs`) performs a cross-product transformation: M chunks × R replicas × N recipients → N file descriptions, each containing M chunks with R replicas. The `addRcvChunk` accumulator builds a `Map rcvNo (Map chunkNo FileChunk)` to correctly distribute replicas across recipient descriptions.

### 10. withRetryIntervalLimit caps consecutive retries

`withRetryIntervalLimit maxN` allows at most `maxN` total attempts (initial attempt at `n=0` plus `maxN-1` retries). When all attempts are exhausted for temporary errors, the operation is silently abandoned for this work cycle — the chunk remains in pending state and may be retried on the next cycle. Only permanent errors (handled by `retryDone`) mark the file as errored.

### 11. Retry distinguishes temporary from permanent errors

`retryOnError` checks `temporaryOrHostError`: temporary/host errors trigger retry with exponential backoff; permanent errors (AUTH, SIZE, etc.) immediately mark the file as failed. On host errors during retry, a warning notification is sent to the client.

### 12. Delete workers skip files older than rcvFilesTTL

`runXFTPDelWorker` uses `rcvFilesTTL` (not a dedicated delete TTL) to filter pending deletions. Files older than this TTL would already be expired on the router, so attempting deletion is pointless. This reuses the receive TTL as a proxy for router-side expiration.

### 13. closeXFTPAgent atomically swaps worker maps

`closeXFTPAgent` uses `swapTVar workers M.empty` to atomically replace each worker map with an empty map, then cancels all retrieved workers. This prevents races where a new worker could be inserted between reading and clearing the map.

### 14. assertAgentForeground dual check

`assertAgentForeground` both throws if the agent is inactive (`throwWhenInactive`) and blocks until it's in the foreground (`waitUntilForeground`). This is called before every chunk operation to ensure the agent isn't suspended or backgrounded during file transfers.

### 15. Per-router stats tracking

Every chunk download, upload, and delete operation increments per-router statistics (`downloads`, `uploads`, `deletions`, `downloadAttempts`, `uploadAttempts`, `deleteAttempts`, and error variants). Size-based stats (`downloadsSize`, `uploadsSize`) track throughput in kilobytes.
