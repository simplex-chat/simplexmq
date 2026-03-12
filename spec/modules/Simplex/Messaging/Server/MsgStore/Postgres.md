# Simplex.Messaging.Server.MsgStore.Postgres

> PostgreSQL message store: server-side stored procedures for message operations, COPY protocol for bulk import.

**Source**: [`Postgres.hs`](../../../../../../src/Simplex/Messaging/Server/MsgStore/Postgres.hs)

## MsgQueue is unit type

`type MsgQueue PostgresMsgStore = ()`. There is no message queue object for Postgres — all message operations go directly to the database via stored procedures. Functions like `getMsgQueue` return `pure ()`.

## Partial interface — error stubs

Multiple `MsgStoreClass` methods are `error "X not used"`: `withActiveMsgQueues`, `unsafeWithAllMsgQueues`, `logQueueStates`, `withIdleMsgQueue`, `getQueueMessages_`, `tryDeleteMsg_`, `setOverQuota_`, `getQueueSize_`, `unsafeRunStore`. These are required by the type class but not applicable to Postgres. Calling any at runtime crashes. Postgres overrides the default implementations of `tryPeekMsg`, `tryDelMsg`, `tryDelPeekMsg`, `deleteExpiredMsgs`, and `getQueueSize` with direct database calls.

## writeMsg — quota logic in stored procedure

`write_message(?,?,?,?,?,?,?)` is a PostgreSQL stored procedure that returns `(quota_written, was_empty)`. Quota enforcement happens in SQL, not in Haskell. This means quota logic is duplicated: STM store checks `canWrite` flag in Haskell, Postgres store checks in the database function. The two implementations must agree on quota semantics.

## tryDelPeekMsg — variable row count

The stored procedure `try_del_peek_msg` returns 0, 1, or 2 rows. For the 1-row case, the code checks whether the returned message's `messageId` matches the requested `msgId` to distinguish "deleted, no next message" from "delete failed, current message returned." This disambiguation is possible because the stored procedure always returns available messages even when deletion doesn't match.

## uninterruptibleMask_ on all database operations

All write operations (`writeMsg`, `tryDelMsg`, `tryDelPeekMsg`, `deleteExpiredMsgs`) and `isolateQueue` are wrapped in `E.uninterruptibleMask_`. This prevents async exceptions (e.g., client disconnect) from interrupting mid-transaction, which could leave database connections in an inconsistent state.

## batchInsertMessages — COPY protocol

Uses PostgreSQL's COPY FROM STDIN protocol (`DB.copy_` + `DB.putCopyData` + `DB.putCopyEnd`) for bulk message import, which is much faster than individual INSERTs. Messages are encoded to CSV format. Parse errors on individual records are logged and skipped — the import is error-tolerant. The entire operation runs in a single transaction (`withTransaction`).

## exportDbMessages — batched I/O

Accumulates rows in an `IORef` list (prepended for O(1) insert), flushing every 1000 records with `reverse` to restore order. Uses `DB.foldWithOptions_` with `fetchQuantity = Fixed 1000` to avoid loading all messages into memory.

## updateQueueCounts — two-step reset

Creates a temp table with aggregated message stats, then updates `msg_queues` in two steps: first zeros all queue counts, then applies actual stats from the temp table. The two-step approach handles queues with zero messages: they're reset by the first UPDATE but not touched by the second (no matching row in temp table).

## toMessage — nanosecond precision lost

`MkSystemTime ts 0` constructs timestamps with zero nanoseconds. Only whole seconds are stored in the database. Messages read from Postgres have coarser timestamps than messages in STM/Journal stores.

## isolateQueue IS the transaction boundary

`isolateQueue` for Postgres does `uninterruptibleMask_ $ withDB' op ... $ runReaderT a . DBTransaction`. Each `isolateQueue` call creates a fresh `DBTransaction` carrying the DB connection. This is how `tryPeekMsg_` (which uses `asks dbConn`) gets its connection. The `withQueueLock` is identity for Postgres, so `isolateQueue` provides no mutual exclusion — only the DB transaction provides isolation.

## newMsgStore hardcodes useCache = False

`newQueueStore @PostgresQueue (queueStoreCfg config, False)` — the Postgres message store always disables queue caching. All lookups go directly to the database. Contrast with the Journal+Postgres combination where caching is enabled.

## deleteQueueSize — size before delete

`deleteQueueSize` calls `getQueueSize` BEFORE `deleteStoreQueue`. The returned size is the count at query time — a concurrent `writeMsg` between the size query and the delete means the reported size is stale. This is acceptable because the size is used for statistics, not for correctness.

## unsafeMaxLenBS

`toMessage` uses `C.unsafeMaxLenBS` to bypass the `MaxLen` length check on message bodies read from the database. A TODO comment questions this choice. If the database contains oversized data, the length invariant is silently violated.
