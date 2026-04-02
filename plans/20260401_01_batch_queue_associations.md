# Server: batch queue service associations

When a batch of SUB or NSUB commands arrives from a service client, each command that needs a new or removed service association calls `setQueueService` individually - one DB write per command. For 135 commands per batch, that's 135 individual `UPDATE msg_queues` queries.

## Goal

Reduce to 1 DB query per batch, using `UPDATE ... RETURNING recipient_id` to identify which queues were actually updated.

`clntServiceId` is per-client (not per-queue), so all queues in a batch that need association changes share the same target value. The per-queue decision is binary: update or not.

```haskell
type NeedsAssocUpdate = Bool
```

## Current code

### `sharedSubscribeQueue` (Server.hs:1757-1805)

Called per SUB/NSUB command. Based on `clntServiceId` and `queueServiceId` from `QueueRec`:

- `clntServiceId == Just sId`, `queueServiceId == Just sId` (line 1763): Already associated. No DB write. STM + stats only.

- `clntServiceId == Just sId`, `queueServiceId /= Just sId` (line 1772): New/updated association. Calls `setQueueService q party (Just sId)` - **DB WRITE**. Then STM + stats.

- `clntServiceId == Nothing`, `queueServiceId == Just _` (line 1787): Removing association. Calls `setQueueService q party Nothing` - **DB WRITE**. Then STM + stats.

- `clntServiceId == Nothing`, `queueServiceId == Nothing` (line 1795): No service. No DB write. STM only.

### Where `sharedSubscribeQueue` is called from

Only from the `client` function's `foldrM` loop in `Server.hs` (via `processCommand` -> `subscribeQueueAndDeliver` or `subscribeNotifications`). The forwarded command handler (line 2094) only processes sender commands, never SUB/NSUB. So `prepareBatch` always runs before `sharedSubscribeQueue`.

### `setQueueService` for Postgres (QueueStore/Postgres.hs:484-505)

Per queue:
1. `withQueueRec sq` - reads QueueRec TVar under queue lock, fails if deleted
2. Checks if already set to target value - returns immediately if so
3. `assertUpdated $ withDB' ... DB.execute "UPDATE ..."` - one DB query, asserts 1 row affected
4. `atomically $ writeTVar (queueRec sq) $ Just q'` - updates in-memory QueueRec
5. `withLog ... logQueueService` - writes store log entry

### `setQueueService` for STM (QueueStore/STM.hs:312-338)

Per queue:
1. `atomically (readQueueRec qr $>>= setService)` - reads QueueRec, updates TVar, updates per-service queue sets
2. `$>> withLog ... logQueueService` - writes store log entry

## Implementation (top-down)

### Step 1: Extend batch preparation in the `client` function (Server.hs)

Currently (Server.hs:1372-1381):
```haskell
forever $ do
  batch <- atomically (readTBQueue rcvQ)
  msgMap <- prefetchMsgs batch
  foldrM (process msgMap) ([], []) batch
    >>= ...
```

Rename `prefetchMsgs` to `prepareBatch`. It returns an additional `Map RecipientId (Either ErrorType ())` for association results.

```haskell
forever $ do
  batch <- atomically (readTBQueue rcvQ)
  (msgMap, assocResults) <- prepareBatch batch
  foldrM (process msgMap assocResults) ([], []) batch
    >>= ...
```

`assocResults` contains entries only for queues that needed an association update. Keyed by `RecipientId`. `Right ()` means the update succeeded. `Left e` means it failed.

### Step 2: Implement `prepareBatch` (Server.hs)

Replaces current `prefetchMsgs`. Does three things:

1. Collects SUB queues for message pre-fetch (existing `tryPeekMsgs` logic, unchanged).

2. Classifies each SUB/NSUB queue's association need by reading `queueServiceId` from the already-loaded `QueueRec` in `VerifiedTransmission` and comparing with `clntServiceId`. Produces `NonEmpty (Either ErrorType NeedsAssocUpdate)` aligned with the batch. Error if `q_ = Nothing` for a SUB/NSUB command. `True` if the queue needs its association updated. `False` if no change needed.

3. Collects `StoreQueue`s where classification produced `Right True`. If non-empty, calls `setQueueServices` with `clntServiceId` as target and this list. Gets back `Set RecipientId` of queues that were actually updated.

4. Builds `assocResults :: Map RecipientId (Either ErrorType ())`: for each queue that needed an update (`Right True`), if its `recipientId` is in the returned set then `Right ()`, otherwise `Left AUTH`.

### Step 3: Thread `assocResults` through `processCommand` (Server.hs:1463)

Add parameter:
```haskell
processCommand :: Maybe ServiceId -> VersionSMP -> Either ErrorType (Map RecipientId Message) -> Map RecipientId (Either ErrorType ()) -> VerifiedTransmission s -> M s (Maybe ResponseAndMessage)
```

In the SUB case, pass `M.lookup entId assocResults` to `subscribeQueueAndDeliver`.
In the NSUB case, pass `M.lookup entId assocResults` to `subscribeNotifications`.
In the forwarded command call (line 2094), pass `M.empty`.
All other commands ignore it.

### Step 4: Thread through `subscribeQueueAndDeliver` (Server.hs:1631) and `subscribeNotifications` (Server.hs:1737)

Both gain `assocResult :: Maybe (Either ErrorType ())` and pass it to `sharedSubscribeQueue`.

`subscribeQueueAndDeliver` signature becomes:
```haskell
subscribeQueueAndDeliver :: Maybe Message -> Maybe (Either ErrorType ()) -> StoreQueue s -> QueueRec -> M s ResponseAndMessage
```

### Step 5: Modify `sharedSubscribeQueue` (Server.hs:1757)

Gains `assocResult :: Maybe (Either ErrorType ())`.

Where the queue needs a new or changed association (line 1772), currently:
```haskell
| otherwise -> runExceptT $ do
    ExceptT $ setQueueService (queueStore ms) q party (Just serviceId)
    hasSub <- ...
```

Becomes:
```haskell
| otherwise -> case assocResult of
    Just (Left e) -> pure $ Left e
    _ -> runExceptT $ do
      hasSub <- ...
```

`Just (Left e)` means the batch update failed for this queue - return the error.
`Just (Right ())` means the batch update succeeded - skip `setQueueService`, proceed with STM work.
`Nothing` cannot happen here because `prepareBatch` always runs before this code and classifies every SUB/NSUB queue.

Same change where removing association (line 1787):
```haskell
Just _ -> case assocResult of
  Just (Left e) -> pure $ Left e
  _ -> runExceptT $ do
    liftIO $ incSrvStat srvAssocRemoved
    ...
```

Queues that are already associated correctly or have no service involvement have `assocResult = Nothing` (not in the map). These paths don't call `setQueueService` today, so nothing changes for them.

### Step 6: Add `setQueueServices` to `QueueStoreClass` (QueueStore/Types.hs:53)

```haskell
setQueueServices :: (PartyI p, ServiceParty p) => s -> SParty p -> Maybe ServiceId -> [q] -> IO (Set RecipientId)
```

Takes target `serviceId` and list of queues. Returns set of `RecipientId`s that were actually updated in the DB.

### Step 7: Postgres implementation (QueueStore/Postgres.hs)

For `SRecipientService`:
```sql
UPDATE msg_queues SET rcv_service_id = ?
WHERE recipient_id IN ? AND deleted_at IS NULL
RETURNING recipient_id
```

For `SNotifierService`:
```sql
UPDATE msg_queues SET ntf_service_id = ?
WHERE recipient_id IN ? AND notifier_id IS NOT NULL AND deleted_at IS NULL
RETURNING recipient_id
```

Build `Set RecipientId` from RETURNING rows.

After the batch query, for each queue whose `recipientId` is in the returned set:
1. Read `QueueRec` from TVar, update with new `serviceId` (same as `updateQueueRec` at line 502-504)
2. Write store log entry (same as `withLog` at line 505)

Queues not in the returned set are not updated (deleted between verification and UPDATE). The caller sees them absent from the set and produces `Left AUTH`.

No per-queue lock needed: the batch UPDATE is a single SQL statement (Postgres handles row-level locking internally), and SUB/NSUB processing is single-threaded per connected client.

### Step 8: STM implementation (QueueStore/STM.hs)

Loop over queues. For each:
1. Run existing `setService` STM logic from `setQueueService` (line 319-334): read QueueRec, update TVar, update per-service queue sets
2. If succeeded, add `recipientId` to result set
3. Write store log entry

Return accumulated `Set RecipientId`.

## Files changed

| File | Change |
|---|---|
| `src/Simplex/Messaging/Server.hs` | Rename `prefetchMsgs` to `prepareBatch` adding classification and `setQueueServices` call. Thread `assocResults` through `processCommand` -> `subscribeQueueAndDeliver` / `subscribeNotifications` -> `sharedSubscribeQueue`. Replace `setQueueService` calls with `assocResult` check. |
| `src/Simplex/Messaging/Server/QueueStore/Types.hs` | Add `setQueueServices` to `QueueStoreClass` |
| `src/Simplex/Messaging/Server/QueueStore/Postgres.hs` | Implement `setQueueServices` with batch `UPDATE ... RETURNING` + per-item TVar and store log updates |
| `src/Simplex/Messaging/Server/QueueStore/STM.hs` | Implement `setQueueServices` as loop over existing STM logic |
