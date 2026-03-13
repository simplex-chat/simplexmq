# Simplex.FileTransfer.Client.Agent

> XFTP client connection management with TMVar-based sharing, async retry, and connection lifecycle.

**Source**: [`FileTransfer/Client/Agent.hs`](../../../../../src/Simplex/FileTransfer/Client/Agent.hs)

## Non-obvious behavior

### 1. TMVar-based connection sharing

`getXFTPServerClient` first checks the `TMap XFTPServer (TMVar (Either XFTPClientAgentError XFTPClient))`. If no entry exists, it atomically inserts an empty `TMVar` and initiates connection. Other threads requesting the same router block on `readTMVar` until the connection is established or fails. This prevents duplicate connections to the same router.

### 2. Async retry on temporary errors

When `newXFTPClient` encounters a temporary error, it launches an async retry loop that attempts reconnection with backoff. The `TMVar` remains in the map but is empty until the retry succeeds. Other threads waiting on `readTMVar` block until either the retry succeeds or a permanent error occurs.

### 3. Permanent error cleanup

On permanent error, `newXFTPClient` puts the `Left error` into the `TMVar` (unblocking waiters) AND deletes the entry from the `TMap`. This means the next caller will see no entry and create a fresh connection attempt, rather than reading a stale error. Waiters that already read the `Left` receive the error.

### 4. Connection timeout

`waitForXFTPClient` wraps `readTMVar` in a timeout. If the connection establishment takes too long (e.g., router unreachable and retry loop is slow), the caller gets a timeout error rather than blocking indefinitely. The underlying connection attempt continues in the background.

### 5. closeXFTPServerClient removes from TMap

Closing a router client deletes its entry from the TMap, so the next request will establish a fresh connection. This is called on connection errors during file operations to force reconnection.
