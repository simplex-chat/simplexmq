# Server: batch queue service associations

When a batch of SUB or NSUB commands arrives from a service client, each command that needs a new or removed service association calls `setQueueService` individually - one DB write per command. For 135 commands per batch, that's 135 individual `UPDATE msg_queues` queries.

## Goal

Reduce to at most 2 DB queries per batch (one for rcv associations, one for ntf associations), using `UPDATE ... RETURNING recipient_id` to identify which queues were actually updated.

Also fuse message pre-fetch and association batching into a single batch preparation step with a clean contract.

## Contract

```haskell
prepareBatch :: Maybe ServiceId -> NonEmpty (VerifiedTransmission s) -> M s (Either ErrorType (Map RecipientId (Maybe Message, Maybe (Either ErrorType ()))))
```

`Left e` = batch-level failure (message pre-fetch or association query failed entirely). All SUBs/NSUBs in the batch get this error.

`Right map` = per-queue results as a tuple:
- `Maybe Message` - pre-fetched message for SUB queues, `Nothing` for NSUB or no message
- `Maybe (Either ErrorType ())` - association result. `Nothing` = no update needed. `Just (Right ())` = update succeeded. `Just (Left e)` = update failed for this queue.

One map, one lookup per queue. `processCommand` passes both values to `subscribeQueueAndDeliver` / `subscribeNotifications` -> `sharedSubscribeQueue`.

Queues not in the map (non-SUB/NSUB commands, failed verification) are not affected.

## prepareBatch implementation

One accumulating fold over the batch, collecting three lists:
- `subMsgQs :: [StoreQueue s]` - SUB queues for message pre-fetch
- `rcvAssocQs :: [StoreQueue s]` - SUB queues needing `rcv_service_id` update (`clntServiceId /= rcvServiceId qr`)
- `ntfAssocQs :: [StoreQueue s]` - NSUB queues needing `ntf_service_id` update (`clntServiceId /= ntfServiceId` from `NtfCreds`)

Classification reads from the already-loaded `QueueRec` in `VerifiedTransmission` - no extra DB query.

Then three store calls (each skipped if its list is empty):
1. `tryPeekMsgs ms subMsgQs` -> `Map RecipientId Message`
2. `setRcvQueueServices (queueStore ms) clntServiceId rcvAssocQs` -> `Set RecipientId`
3. `setNtfQueueServices (queueStore ms) clntServiceId ntfAssocQs` -> `Set RecipientId`

Then one pass to merge results into `Map RecipientId (Maybe Message, Maybe (Either ErrorType ()))`:
- For each SUB queue: `(M.lookup rId msgMap, assocResult rId rcvUpdated rcvAssocQs)`
- For each NSUB queue: `(Nothing, assocResult rId ntfUpdated ntfAssocQs)`

Where `assocResult rId updated assocQs` = if the queue was in `assocQs` (needed update), then `Just (Right ())` if `rId` is in `updated`, else `Just (Left AUTH)`. If not in `assocQs` (no update needed), `Nothing`.

If any of the three calls fails entirely, return `Left e`.

## Store interface

Replace the polymorphic `setQueueServices` with two plain functions in `QueueStoreClass`:

```haskell
setRcvQueueServices :: s -> Maybe ServiceId -> [q] -> IO (Set RecipientId)
setNtfQueueServices :: s -> Maybe ServiceId -> [q] -> IO (Set RecipientId)
```

No `SParty p` polymorphism. Each function knows its column.

### Postgres implementation

`setRcvQueueServices`:
```sql
UPDATE msg_queues SET rcv_service_id = ?
WHERE recipient_id IN ? AND deleted_at IS NULL
RETURNING recipient_id
```

`setNtfQueueServices`:
```sql
UPDATE msg_queues SET ntf_service_id = ?
WHERE recipient_id IN ? AND notifier_id IS NOT NULL AND deleted_at IS NULL
RETURNING recipient_id
```

After each batch query, for each queue in the returned set:
1. Read QueueRec TVar, update with new serviceId
2. Write store log entry

### STM implementation

Loop over queues, call existing per-item logic, collect succeeded `RecipientId`s into a Set.

## Downstream changes in Server.hs

### processCommand

Gains one parameter: `Map RecipientId (Maybe Message, Maybe (Either ErrorType ()))`.

SUB case: `M.lookup entId prepared` gives `Just (msg_, assocResult)` or `Nothing`. Pass both to `subscribeQueueAndDeliver`.

NSUB case: `M.lookup entId prepared` gives `Just (Nothing, assocResult)` or `Nothing`. Pass `assocResult` to `subscribeNotifications`.

Forwarded commands: pass `M.empty`.

### subscribeQueueAndDeliver

Takes `Maybe Message` and `Maybe (Either ErrorType ())` as before. No change in how it uses them.

### sharedSubscribeQueue

Takes `Maybe (Either ErrorType ())`. On paths needing association update:
- `Just (Left e)` -> return error
- `Just (Right ())` -> skip `setQueueService`, proceed with STM work
- `Nothing` -> no update needed, proceed with existing logic

## Implementation order (top-down)

1. Define the `prepareBatch` contract and thread one map through `processCommand` -> `subscribeQueueAndDeliver` / `subscribeNotifications` -> `sharedSubscribeQueue` (Server.hs)
2. Implement `prepareBatch` with the fold, three calls, and merge (Server.hs)
3. Add `setRcvQueueServices` and `setNtfQueueServices` to `QueueStoreClass` (Types.hs)
4. Implement for Postgres with batch `UPDATE ... RETURNING` (Postgres.hs)
5. Implement for STM as loop (STM.hs)
6. Implement for Journal as delegation (Journal.hs)

At step 2, store functions can initially be stubs returning empty sets. Steps 3-6 fill in the real implementations.

## Files changed

| File | Change |
|---|---|
| `src/Simplex/Messaging/Server.hs` | `prepareBatch` with fold + merge; one map parameter through `processCommand` -> `subscribeQueueAndDeliver` / `subscribeNotifications` -> `sharedSubscribeQueue` |
| `src/Simplex/Messaging/Server/QueueStore/Types.hs` | Add `setRcvQueueServices`, `setNtfQueueServices` to `QueueStoreClass` |
| `src/Simplex/Messaging/Server/QueueStore/Postgres.hs` | Implement with batch `UPDATE ... RETURNING` + per-item TVar/log updates |
| `src/Simplex/Messaging/Server/QueueStore/STM.hs` | Implement as loop |
| `src/Simplex/Messaging/Server/MsgStore/Journal.hs` | Delegate to underlying store |
