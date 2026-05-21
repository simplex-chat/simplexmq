# Server: batched SUB command processing

Implementation plan for Part 1 of [RFC 2026-03-28-subscription-performance](../rfcs/2026-03-28-subscription-performance.md).

## Current state

When a batch of ~135 SUB commands arrives, the server already batches:
- Queue record lookups (`getQueueRecs` in `receive`, Server.hs:1151)
- Command verification (`verifyLoadedQueue`, Server.hs:1152)

But command processing is per-command (`foldrM process` in `client`, Server.hs:1372-1375). Each SUB calls `subscribeQueueAndDeliver` which calls `tryPeekMsg` - one DB query per queue. For Postgres, that's ~135 individual `SELECT ... FROM messages WHERE recipient_id = ? ORDER BY message_id ASC LIMIT 1` queries per batch.

## Goal

Replace ~135 individual message peek queries with 1 batched query per batch. No protocol changes.

## Implementation

### Step 1: Add `tryPeekMsgs` to MsgStoreClass

File: `src/Simplex/Messaging/Server/MsgStore/Types.hs`

Add to `MsgStoreClass`:

```haskell
tryPeekMsgs :: s -> [StoreQueue s] -> ExceptT ErrorType IO (Map RecipientId Message)
```

Returns a map from recipient ID to earliest pending message for each queue that has one. Queues with no messages are absent from the map.

### Step 2: Parameterize `deliver` to accept pre-fetched message

File: `src/Simplex/Messaging/Server.hs`

Currently `deliver` (inside `subscribeQueueAndDeliver`, line 1641) calls `tryPeekMsg ms q`. Add a parameter for an optional pre-fetched message:

```haskell
deliver :: Maybe Message -> (Bool, Maybe Sub) -> M s ResponseAndMessage
deliver prefetchedMsg (hasSub, sub_) = do
  stats <- asks serverStats
  fmap (either ((,Nothing) . err) id) $ liftIO $ runExceptT $ do
    msg_ <- maybe (tryPeekMsg ms q) (pure . Just) prefetchedMsg
    ...
```

When `Nothing` is passed, falls back to individual `tryPeekMsg` (existing behavior). When `Just msg` is passed, uses it directly (batched path).

### Step 3: Pre-fetch messages before the processing loop

File: `src/Simplex/Messaging/Server.hs`

Currently (lines 1372-1375):

```haskell
forever $
  atomically (readTBQueue rcvQ)
    >>= foldrM process ([], [])
    >>= \(rs_, msgs) -> ...
```

Add a pre-fetch step before the existing loop:

```haskell
forever $ do
  batch <- atomically (readTBQueue rcvQ)
  msgMap <- prefetchMsgs batch
  foldrM (process msgMap) ([], []) batch
    >>= \(rs_, msgs) -> ...
```

`prefetchMsgs` scans the batch, collects queues from SUB commands that have a verified queue (`q_ = Just (q, _)`), calls `tryPeekMsgs` once, returns the map. For batches with no SUBs it returns an empty map (no DB call).

`process` passes the looked-up message (or Nothing) through to `processCommand` and down to `deliver`.

The `foldrM process` loop, `processCommand`, `subscribeQueueAndDeliver`, and all other command handlers stay structurally the same. Only `deliver` gains one parameter, and the `client` loop gains one pre-fetch call.

### Step 4: Review

Review the typeclass signature and server usage. Confirm the interface has the right shape before implementing store backends.

### Step 5: Implement for each store backend

#### Postgres

File: `src/Simplex/Messaging/Server/MsgStore/Postgres.hs`

Single query using `DISTINCT ON`:

```sql
SELECT DISTINCT ON (recipient_id)
  recipient_id, msg_id, msg_ts, msg_quota, msg_ntf_flag, msg_body
FROM messages
WHERE recipient_id IN ?
ORDER BY recipient_id, message_id ASC
```

Build `Map RecipientId Message` from results.

#### STM

File: `src/Simplex/Messaging/Server/MsgStore/STM.hs`

Loop over queues, call `tryPeekMsg` for each, collect into map.

#### Journal

File: `src/Simplex/Messaging/Server/MsgStore/Journal.hs`

Loop over queues, call `tryPeekMsg` for each, collect into map.

### Step 6: Handle edge cases

1. **Mixed batches**: `prefetchMsgs` collects only SUB queues. Non-SUB commands get Nothing for the pre-fetched message and process unchanged.

2. **Already-subscribed queues**: Include in pre-fetch - `deliver` is called for re-SUBs too (delivers pending message).

3. **Service subscriptions**: The pre-fetch doesn't care about service state. `sharedSubscribeQueue` handles service association in STM; message peek is the same.

4. **Error queues**: Verification errors from `receive` are Left values in the batch. `prefetchMsgs` only looks at Right values with SUB commands.

5. **Empty pre-fetch**: If batch has no SUBs (e.g., all ACKs), `prefetchMsgs` returns empty map, no DB call made.

### Step 7: Batch other commands (future, not in scope)

The same pattern (pre-fetch before loop, parameterize handler) can extend to:
- `ACK` with `tryDelPeekMsg` - batch delete+peek
- `GET` with `tryPeekMsg` - same map lookup

Lower priority since these don't have the N-at-once pattern of subscriptions.

## File changes summary

| File | Change |
|---|---|
| `src/Simplex/Messaging/Server/MsgStore/Types.hs` | Add `tryPeekMsgs` to typeclass |
| `src/Simplex/Messaging/Server/MsgStore/Postgres.hs` | Implement `tryPeekMsgs` with batch SQL |
| `src/Simplex/Messaging/Server/MsgStore/STM.hs` | Implement `tryPeekMsgs` as loop |
| `src/Simplex/Messaging/Server/MsgStore/Journal.hs` | Implement `tryPeekMsgs` as loop |
| `src/Simplex/Messaging/Server.hs` | Add `prefetchMsgs`, parameterize `deliver` |

## Testing

1. Existing server tests must pass unchanged (correctness preserved).
2. Add a test that subscribes a batch of queues (some with pending messages, some without) and verifies all get correct SOK + MSG responses.
3. Prometheus metrics: existing `qSub` stat should still increment correctly.

## Performance expectation

For 300K queues across ~2200 batches:
- Before: ~300K individual DB queries
- After: ~2200 batched DB queries (one per batch of ~135)
- ~136x reduction in DB round-trips
