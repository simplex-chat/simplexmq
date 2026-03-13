# Simplex.FileTransfer.Server.StoreLog

> Append-only store log for XFTP file operations with error-resilient replay and compaction.

**Source**: [`FileTransfer/Server/StoreLog.hs`](../../../../../src/Simplex/FileTransfer/Server/StoreLog.hs)

## Non-obvious behavior

### 1. Error-resilient replay

`readFileStore` parses the store log line-by-line. Lines that fail to parse or fail to process (e.g., referencing a nonexistent sender ID) are logged as errors but do not halt replay. The store is reconstructed from whatever valid entries exist. This allows the server to recover from partial log corruption.

### 2. Sender ID validation on recipient writes

`writeFileStore` during compaction validates that each recipient's sender ID in the `recipients` TMap matches the `senderId` of the corresponding `FileRec`. This guards against in-memory state corruption (e.g., if a bug caused the `recipients` TMap and `FileRec.recipientIds` to get out of sync), not log corruption — the validation happens before writing the compacted log.

### 3. Backward-compatible status parsing

`AddFile` log entries include an `EntityStatus` field. The parser uses `<|> pure EntityActive` as a fallback, defaulting to `EntityActive` when the status field is missing. This allows reading store logs from older server versions that didn't record entity status.

### 4. Compaction on restart

`readFileStore` replays the full log to rebuild the in-memory store. The caller (in `Server/Env.hs`) then writes a fresh, compacted store log containing only the current state. This eliminates deleted entries and redundant operations, keeping the log size proportional to active state rather than total history.

### 5. Log entry types track operation lifecycle

Six log entry types capture the complete file lifecycle:
- `AddFile`: file creation with sender ID, file info, timestamp, and status
- `AddRecipients`: recipient registration (batched as `NonEmpty FileRecipient`) with sender ID association
- `PutFile`: upload completion with file path
- `DeleteFile`: file deletion by sender ID
- `AckFile`: single recipient acknowledgment
- `BlockFile`: file blocking with blocking info
