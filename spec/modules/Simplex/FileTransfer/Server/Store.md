# Simplex.FileTransfer.Server.Store

> STM-based in-memory file store with dual indices, storage accounting, and privacy-preserving expiration.

**Source**: [`FileTransfer/Server/Store.hs`](../../../../../src/Simplex/FileTransfer/Server/Store.hs)

## Non-obvious behavior

### 1. Dual-index lookup by sender and recipient

The file store maintains two indices: `files :: TMap SenderId FileRec` (by sender ID) and `recipients :: TMap RecipientId (SenderId, RcvPublicAuthKey)` (by recipient ID, storing the sender ID and the recipient's public auth key). `getFile` dispatches on `SFileParty`: sender lookups use `files` directly, recipient lookups use `recipients` to find the `SenderId` then look up the `FileRec` in `files`. This means recipient operations require two TMap lookups.

### 2. addRecipient checks both inner Set and global TMap

`addRecipient` first checks the per-file `recipientIds` Set for duplicates, then inserts into the global `recipients` TMap. If either has a collision, it returns `DUPLICATE_`. The dual check is necessary because the Set tracks per-file membership while the TMap enforces global uniqueness of recipient IDs.

### 3. Storage accounting on upload completion

`setFilePath` adds the file size to `usedStorage` and records the file path in the `filePath` TVar. However, during normal FPUT handling, `Server.hs` does NOT call `setFilePath` — it directly writes `filePath` via `writeTVar`. The quota reservation in `Server.hs` (`stateTVar` on `usedStorage`) is the sole `usedStorage` increment during upload. `setFilePath` IS called during store log replay (`StoreLog.hs`), where it increments `usedStorage`; `newXFTPServerEnv` then overwrites with the correct value computed from the live store.

### 4. deleteFile removes all recipients atomically

`deleteFile` atomically removes the sender entry from `files`, all recipient entries from the global `recipients` TMap, and unconditionally subtracts the file size from `usedStorage` (regardless of whether the file was actually uploaded). The entire operation runs in a single STM transaction.

### 5. RoundedSystemTime for privacy-preserving expiration

File timestamps use `RoundedFileTime` which is `RoundedSystemTime 3600` — system time rounded to 1-hour precision. This means files created within the same hour have identical timestamps. An observer with access to the store cannot determine exact file creation times, only the hour.

### 6. expiredFilePath returns path only if expired

`expiredFilePath` returns `STM (Maybe (Maybe FilePath))`. The outer `Maybe` is `Nothing` when the file doesn't exist or isn't expired; the inner `Maybe` is the file path (present only if the file was uploaded). The expiration check adds `fileTimePrecision` (one hour) to the creation timestamp before comparing, providing a grace period. The caller uses the inner path to decide whether to also delete the physical file.

### 7. ackFile removes single recipient

`ackFile` removes a specific recipient from both the global `recipients` TMap and the per-file `recipientIds` Set. Unlike `deleteFile` which removes the entire file, `ackFile` only removes one recipient's access. The file and other recipients remain intact.

### 8. blockFile conditional storage adjustment

`blockFile` takes a `deleted :: Bool` parameter. When `True` (file blocked with physical deletion), it subtracts the file size from `usedStorage`. When `False` (block without deletion), storage is unchanged. This allows blocking without physical deletion for audit purposes. Currently, both the server's `blockServerFile` and the store log replay path pass `True`.
