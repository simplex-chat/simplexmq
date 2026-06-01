# Simplex.Messaging.Server.QueueStore.STM

> In-memory STM queue store: queue CRUD with store log journaling and service tracking.

**Source**: [`STM.hs`](../../../../../../src/Simplex/Messaging/Server/QueueStore/STM.hs)

## addQueue_ — atomic multi-ID DUPLICATE check

`addQueue_` checks ALL entity IDs (recipient, sender, notifier, link) for existence in a single STM transaction. If ANY already exist, returns `DUPLICATE_` without inserting anything. This prevents partial state where some IDs were inserted before the duplicate was detected on another. The `mkQ` callback runs outside STM before the check — the queue object is created optimistically and discarded if the check fails.

## getCreateService — outside-STM with role validation

`getCreateService` uses the outside-STM lookup pattern (`TM.lookupIO` then STM fallback). When a service cert already exists, `checkService` validates the role matches — a cert attempting to register with a different `SMPServiceRole` gets `SERVICE` error. A new service is only created if the ID is not already in `services` (prevents DUPLICATE). The `(serviceId, True/False)` return indicates whether the log should be written (only for new services).

## IdsHash XOR in setServiceQueues_

Both `addServiceQueue` and `removeServiceQueue` use `setServiceQueues_`, which unconditionally XORs `queueIdHash qId` into `idsHash`. Since XOR is self-inverse, removal cancels addition. However, the XOR is applied blindly — there is no `S.member` guard. If `addServiceQueue` were called twice for the same `qId`, the XOR would self-cancel while the `Set` (via `S.insert` idempotency) retains the element, making hash and Set inconsistent. Similarly, `removeServiceQueue` on a non-member XORs a phantom ID into the hash. Correctness relies on callers maintaining the invariant: each `qId` is added exactly once and removed at most once per service.

## withLog — uninterruptibleMask_ for log integrity

Store log writes are wrapped in `E.uninterruptibleMask_` — cannot be interrupted by async exceptions during the write. This prevents partial log records that would corrupt the store log file during replay. Synchronous exceptions are caught by `E.try` and converted to `STORE` error (logged, not crashed).

## secureQueue — idempotent replay

If `senderKey` already matches the provided key, returns `Right ()`. A different key returns `Left AUTH`. This idempotency is essential for store log replay where the same `SecureQueue` record may be applied multiple times.

## getQueues_ — map snapshot for batch consistency

Batch queue lookups (`getQueues_`) read the entire TVar map once with `readTVarIO`, then look up each queue ID in the pure `Map`. This provides a consistent snapshot (all lookups see the same map state) and is more efficient than per-queue IO lookups for large batches.

## closeQueueStore — non-atomic shutdown

`closeQueueStore` clears TMaps in separate `atomically` calls, not one transaction. Concurrent operations during shutdown could see partially cleared state. This is acceptable because the store log is closed first, and the router should not be processing new requests during shutdown.

## addQueueLinkData — conditional idempotency

Re-adding link data with the same `lnkId` and matching first component of `QueueLinkData` succeeds (idempotent replay). Different `lnkId` or mismatched data returns `AUTH`. This handles store log replay where the same `CreateLink` may be applied multiple times.
