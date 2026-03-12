# Simplex.Messaging.Server.MsgStore.Types

> Type class for message stores with injective type families and polymorphic isolation.

**Source**: [`Types.hs`](../../../../../../src/Simplex/Messaging/Server/MsgStore/Types.hs)

## Injective type families

All associated types (`StoreMonad`, `MsgQueue`, `StoreQueue`, `QueueStore`, `MsgStoreConfig`) use injective type families (`| m -> s`). This means each associated type uniquely determines the store type, avoiding ambiguity at call sites. Without injectivity, most call sites would need explicit type applications.

## isolateQueue — polymorphic isolation

`isolateQueue` abstracts the concurrency model: STM store implements it as `liftIO . atomically` (single STM transaction), while Journal store acquires a TMVar-based in-memory lock (not a filesystem lock). All message operations go through `isolateQueue` or `withPeekMsgQueue` (which calls `isolateQueue`). This means the atomicity guarantee varies by backend — STM gives true atomicity, Journal gives mutual exclusion via lock.

## tryDelPeekMsg — atomic delete-and-peek

Deletes the current message AND peeks the next one in a single `isolateQueue` call. This atomicity is critical for the ACK flow: the router needs to know if there's a next message to deliver immediately after acknowledging the current one, without a window where a concurrent SEND could interleave.

## withIdleMsgQueue — journal-specific lifecycle

For Journal store, the message queue file handle is closed after the action if it was initially closed or idle longer than the configured interval. For STM store, this is effectively a no-op (always open, never "idle"). The return tuple `(Maybe a, Int)` provides both the action result and the queue size — the `Maybe` is `Nothing` when no message queue exists (no messages ever written).

## unsafeWithAllMsgQueues — CLI-only

Explicitly unsafe: iterates all queues including those not in active memory. Only safe before router start or in CLI commands. During normal operation, Journal store may have queues on disk but not loaded — this function would load them, interfering with the lazy-loading lifecycle.

## snapshotTQueue visibility gap

`getQueueMessages_ False` (non-destructive read) flushes the TQueue then writes all messages back. Between flush and rewrite, concurrent STM transactions would see an empty queue. Since this runs inside `atomically` for STM store, the gap is invisible to other transactions. For Journal store (where `StoreMonad` is IO-based), this is not used.
