# Simplex.Messaging.Server.StoreLog

> Append-only log for queue state changes: write, read/replay, compaction, crash recovery, backup retention.

**Source**: [`StoreLog.hs`](../../../../../src/Simplex/Messaging/Server/StoreLog.hs)

## writeStoreLogRecord — atomicity via manual write

See comment in `writeStoreLogRecord`. `hPutStrLn` breaks writes larger than 1024 bytes into multiple system calls on `LineBuffered` handles, which could interleave with concurrent writes. The solution is manual `B.hPut` (single call for the complete record + newline) plus `hFlush`. `E.uninterruptibleMask_` prevents async exceptions between write and flush — ensures a complete record is always written.

## readWriteStoreLog — crash recovery state machine

The `.start` temp backup file provides crash recovery during compaction. The sequence:

1. Read existing log, replay into memory
2. Rename log to `.start` (atomic rename = backup point)
3. Write compacted state to new file
4. Rename `.start` to timestamped backup, remove old backups

If the router crashes during step 3, the next startup detects `.start` and restores from it instead of the incomplete new file. Any partially-written current file is preserved as `.bak`. The comment says "do not terminate" during compaction — there is no safe interrupt point between steps 2 and 4.

## removeStoreLogBackups — layered retention policy

Backup retention is layered: (1) keep all backups newer than 24 hours, (2) of the rest, keep at least 3, (3) of those eligible for deletion, only delete backups older than 21 days. This means a router with infrequent restarts accumulates many backups (only cleaned on startup), while a frequently-restarting router keeps a rolling window. Backup timestamps come from ISO 8601 suffixes parsed from filenames.

## QueueRec StrEncoding — backward-compatible parsing

The `strP` parser handles two field name generations: old format `sndSecure=` (boolean, mapping `True` → `QMMessaging`, `False` → `QMContact`) and new format `queue_mode=`. Missing queue mode defaults to `Nothing` with the comment "unknown queue mode, we cannot imply that it is contact address." `EntityActive` status is implicit — not written to the log, and parsed as default when `status=` is absent.

## openReadStoreLog — creates file if missing

`openReadStoreLog` creates an empty file if it doesn't exist. Callers never need to handle "file not found."

## foldLogLines — EOF flag for batching

The `action` callback receives a `Bool` indicating whether the current line is the last one. This allows consumers (like `readQueueStore`) to batch operations and flush only on the final line.
