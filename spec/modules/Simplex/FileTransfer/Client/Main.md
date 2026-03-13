# Simplex.FileTransfer.Client.Main

> XFTP CLI client: send, receive, delete files with parallel chunk operations and web URI encoding.

**Source**: [`FileTransfer/Client/Main.hs`](../../../../../src/Simplex/FileTransfer/Client/Main.hs)

## Non-obvious behavior

### 1. Web URI encoding: base64url(deflate(YAML))

`encodeWebURI` compresses the YAML-encoded file description with raw DEFLATE, then base64url-encodes the result. `decodeWebURI` reverses this. The compressed description goes in the URL fragment (after `#`), which is never sent to the router — the file description stays client-side.

### 2. CLI receive accepts both file paths and URLs

`getInputFileDescription` checks if the input starts with `http://` or `https://`. If so, it extracts the URL fragment, decodes it via `decodeWebURI`, and uses the resulting file description. Otherwise, it reads a YAML file from disk. This allows receiving files via web links without a browser.

### 3. Redirect chain depth limited to 1

`receive` tracks a `depth` parameter starting at 1. After following one redirect, `depth` becomes 0. A second redirect throws "Redirect chain too long". This prevents infinite redirect loops from malicious file descriptions.

### 4. Parallel chunk uploads with router grouping

`uploadFile` groups chunks by router via `groupAllOn`, then uses `pooledForConcurrentlyN 16` to process up to 16 router-groups concurrently. Within each group, chunks are uploaded sequentially (`mapM`). Errors from any chunk are collected and the first one is thrown.

### 5. Random router selection

`getXFTPServer` selects a random router from the provided list for each chunk. With a single router, it's deterministic. With multiple routers, it uses `StdGen` in a TVar for thread-safe random selection via `stateTVar`.

### 6. withReconnect nests retry with reconnection

`withReconnect` wraps `withRetry` twice: the outer retry reconnects to the router, and the inner operation runs against the connection. On failure, the router connection is explicitly closed before retrying, forcing a fresh connection on the next attempt.

### 7. withRetry rejects zero retries

`withRetry' 0` returns an "internal: no retry attempts" error. `withRetry' 1` executes the action once without retry. This off-by-one convention means `retryCount = 3` (the default) gives 3 total attempts (1 initial + 2 retries).

### 8. File description auto-deletion prompt

After successful receive or delete, `removeFD` either auto-deletes the file description (if `--yes` flag) or prompts the user. This prevents accidental reuse of one-time file descriptions — each receive consumes the description by ACKing chunks on the router.

### 9. Sender description uses first replica's router

`createSndFileDescription` takes the router from the first replica of each chunk for the sender's `FileChunkReplica`. This reflects the current limitation that each chunk is uploaded to exactly one router — the sender description records that single router.
