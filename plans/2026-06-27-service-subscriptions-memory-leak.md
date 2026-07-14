## Root cause: orphaned `Sub` entries in the service client's `subscriptions` map

**The leak is service-specific and was introduced by PR #1667 "messaging services" (`f0b7a4be`).** A long-lived messaging-service connection accumulates per-queue `Sub` records in its `Client.subscriptions` map that are **never removed** when the associated queues are deleted or unassociated — only the counter is decremented. Over normal queue churn the map grows monotonically for the entire lifetime of the service connection.

### The proof — an asymmetry between two handlers in `serverThread`

Both individual queue subscriptions and service subscriptions store a `Sub` per queue in `Client.subscriptions` (= `clientSubs` for the SMP subscriber thread, wired at `Server.hs:189`). When a queue ends/is deleted, the two paths diverge:

**Individual subscriber — entry IS removed** (`Server.hs:332`, `346`):
```haskell
CSAEndSub qId -> atomically (endSub c qId) >>= a unsub_   -- :332
  ...
endSub c qId = TM.lookupDelete qId (clientSubs c) >>= (removeWhenNoSubs c $>)  -- :346
```

**Service subscriber — entry is NOT removed** (`Server.hs:336-340`):
```haskell
CSAEndServiceSub qId -> atomically $ do
  modifyTVar' (clientServiceSubs c) decrease   -- decrements serviceSubsCount
  modifyTVar' totalServiceSubs decrease        -- decrements global count
  where decrease = subtractServiceSubs (1, queueIdHash qId)
  -- never touches (clientSubs c) — the Sub for qId stays forever
```

### Where the orphaned entries are added (both new in this PR)
- `Server.hs:1860-1862` — on service subscribe (`SSUB`), one `Sub` inserted per queue that has a pending message.
- `Server.hs:2039-2043` (`newServiceDeliverySub`) — on **every** `SEND` to a service-associated queue with no existing sub, a `Sub` is inserted into the service client's `subscriptions`. After delivery the thread state resets to `NoSub` (`:2069`) but the map entry remains as a "already delivering" marker (`:1856-1859`).

### Why they leak
The only places the service client's `subscriptions` map is cleared are:
- `clientDisconnected` — `swapTVar subscriptions M.empty` (`Server.hs:1097`) — only on disconnect.
- `CSADecreaseSubs` — `swapTVar (clientSubs c) M.empty` (`Server.hs:343`) — only on full service takeover by another connection.
- `delQueueAndMsgs` — `TM.lookupDelete entId $ subscriptions clnt` (`Server.hs:2164`) — but `clnt` here is **the recipient deleting its own queue, not the service client**. The service's entry for that queue is reached only via the `CSDeleted → endServiceSub → CSAEndServiceSub` path (`Server.hs:306, 313, 336`), which decrements the counter but leaves the map entry.

**Concrete scenario (fully traced):** Service `S` subscribes (`SSUB`) and stays connected for days. Recipient `R` owns service-associated queue `Q`. A `SEND` to `Q` inserts a `Sub` into `S.subscriptions[Q]` (`:2042`). `R` later deletes `Q` → `delQueueAndMsgs` runs on `R`'s connection, removes `Q` from `R.subscriptions`, decrements counters, enqueues `CSDeleted Q (Just S)` (`:2167`) → `serverThread` runs `CSAEndServiceSub Q` for `S` (`:336`), decrementing `S.serviceSubsCount` but **leaving `S.subscriptions[Q]` in place**. Net: one orphaned `Sub` (record + 2 TVars) per service-associated queue ever deleted/unassociated, never reclaimed until `S` disconnects. The logical counter `serviceSubsCount` correctly drops, so the map size diverges from the counter — making the leak invisible to the existing service-sub metric.

### Verdict
This is a deterministic, static-provable memory leak — no production logging needed to confirm the existence; the asymmetry between `CSAEndSub` (removes) and `CSAEndServiceSub` (doesn't) is the smoking gun. It is specific to messaging-service certificate clients, which is exactly the population added by the services/certificate PR.

### Secondary findings (lower impact, same PR area, not the primary cause)
- **`forkClient` register-after-fork race** (`Server.hs:1356-1359`): if the forked action's `finally` delete (`:1358`) runs before the parent's `IM.insert` (`:1359`), a `Weak ThreadId` of a dead thread is left in `endThreads` until disconnect. Pre-existing, tiny per-entry, but exercised far more by the PR's higher END/DELD volume.
- **Wrong-client counter decrement** (`Server.hs:2166`): `delQueueAndMsgs` decrements `serviceSubsCount` of the *deleting* client, not the service; harmless for non-service deleters (floored at 0) but corrupts accounting if a service deletes its own queue.

---

### Recommended fix (mirror `endSub` in the service path)
Make `CSAEndServiceSub` also delete the per-queue `Sub` and cancel its delivery thread, exactly as `CSAEndSub`/`endSub` do for individual subscribers. Roughly:

```haskell
CSAEndServiceSub qId -> do
  s_ <- atomically $ do
    modifyTVar' (clientServiceSubs c) decrease
    modifyTVar' totalServiceSubs decrease
    TM.lookupDelete qId (clientSubs c) <* removeWhenNoSubs c
  forM_ unsub_ $ \unsub -> mapM_ unsub s_
  where decrease = subtractServiceSubs (1, queueIdHash qId)
```
