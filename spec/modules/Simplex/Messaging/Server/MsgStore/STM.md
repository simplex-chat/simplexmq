# Simplex.Messaging.Server.MsgStore.STM

> In-memory STM message store: TQueue-based message queues with quota enforcement.

**Source**: [`STM.hs`](../../../../../../src/Simplex/Messaging/Server/MsgStore/STM.hs)

## withQueueLock is identity

`withQueueLock _ _ = id` — STM queues need no locking since STM provides atomicity. Journal.hs overrides this with a `TMVar`-based in-memory lock (via `withLockWaitShared`). Any code calling `withQueueLock` transparently gets the right concurrency control for the backend.

## writeMsg — quota with empty-queue override

When `canWrite` is `False` (over quota) but the queue is empty, writing is still allowed. This handles the case where all messages were deleted or expired but the `canWrite` flag was not reset. When the quota is exceeded, the actual message content is replaced with a `MessageQuota` (preserving only `msgId` and `msgTs`) — the client receives a quota notification instead of the message.

## getMsgQueue — lazy initialization

The message queue TVar (`msgQueue'`) starts as `Nothing`. The queue is created on first `getMsgQueue` call (lazy initialization). This means queues that are created but never receive messages don't allocate a TQueue. `getPeekMsgQueue` returns `Nothing` if no message queue exists — callers handle this as "queue is empty."

## deleteQueue_ — atomic swap prevents post-delete operations

`swapTVar (msgQueue' q) Nothing` atomically retrieves the old message queue and sets to `Nothing`. Any subsequent `getMsgQueue` call would create a fresh empty queue, but the deleted queue's `queueRec` TVar is also set to `Nothing` by `deleteStoreQueue`, so all operations would fail with `AUTH` first.

## tryDeleteMsg_ — blind dequeue, no msgId check

`tryDeleteMsg_` does `tryReadTQueue` — removes whatever is at the head without verifying the message ID. The msgId check lives in the default `tryDelMsg` / `tryDelPeekMsg` implementations in `Types.hs`, which always call `tryPeekMsg_` first to verify. Calling `tryDeleteMsg_` directly would silently delete the wrong message if the head changed between peek and delete. Safe only because `isolateQueue` serializes all operations on the same queue.

## getQueueMessages_ snapshot — invisible gap

`getQueueMessages_ False` implements non-destructive read by flushing TQueue then writing back. This runs inside `atomically` (via `isolateQueue`), so the temporarily-empty state is never visible to other transactions.
