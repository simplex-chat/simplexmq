## Root Cause Analysis: SMP Server Memory Growth (23.5GB)

### Environment

- **Server**: smp19.simplex.im, ~21,927 connected clients
- **Storage**: PostgreSQL backend with `useCache = False`
- **RTS flags**: `+RTS -N -A16m -I0.01 -Iw15 -s -RTS` (16 cores)
- **Memory**: 23.5GB RES / 1031GB VIRT (75% of available RAM)

### Log Summary

- **Duration**: ~22 hours (Mar 16 12:12 → Mar 17 10:20)
- **92,277 proxy connection errors** out of 92,656 total log lines (99.6%)
- **292 unique failing destination servers**, top offender: `nowhere.moe` (12,875 errors)
- Only **145 successful proxy connections**

---

### Known Factor: GHC Heap Sizing

With 16 cores and `-A16m`:
- **Nursery**: 16 × 16MB = **256MB baseline**
- GHC default major GC threshold = **2× live data** — if live data is 10GB, heap grows to ~20GB before major GC
- The server is rarely idle with 22K clients, so major GC is deferred despite `-I0.01`
- This is an amplifier — whatever the actual live data size is, GHC roughly doubles it

---

### Candidate Structures That Could Grow Unboundedly

Analysis of the full codebase identified these structures that either grow without bound or have uncertain cleanup:

#### 1. `SubscribedClients` maps — `Env/STM.hs:378`

Both `subscribers.queueSubscribers` and `ntfSubscribers.queueSubscribers` (and their `serviceSubscribers`) use `SubscribedClients (TMap EntityId (TVar (Maybe (Client s))))`.

Comment at line 376: *"The subscriptions that were made at any point are not removed"*

`deleteSubcribedClient` IS called on disconnect (Server.hs:1112) and DOES call `TM.delete`. But it only deletes if the current stored client matches — if another client already re-subscribed, the old client's disconnect won't remove the entry. This is by design for mobile client continuity, but the net effect on map size over time is unclear without measurement.

#### 2. ProxyAgent's subscription TMaps — `Client/Agent.hs:145-151`

The `SMPClientAgent` has 4 TMaps that accumulate one top-level entry per unique destination server and **never remove** them:

- `activeServiceSubs :: TMap SMPServer (TVar ...)` (line 145)
- `activeQueueSubs :: TMap SMPServer (TMap QueueId ...)` (line 146)
- `pendingServiceSubs :: TMap SMPServer (TVar ...)` (line 149)
- `pendingQueueSubs :: TMap SMPServer (TMap QueueId ...)` (line 150)

Comment at line 262: *"these vars are never removed, they are only added"*

These are only used for the proxy agent (SParty 'Sender), so they grow with each unique destination SMP server proxied to. With 292 unique servers in this log period, these are likely small — but long-running servers may accumulate thousands.

`closeSMPClientAgent` (line 369) does NOT clear these 4 maps.

#### 3. `NtfStore` — `NtfStore.hs:26`

`NtfStore (TMap NotifierId (TVar [MsgNtf]))` — one entry per NotifierId.

`deleteExpiredNtfs` (line 47) filters expired notifications from lists but does **not remove entries with empty lists** from the TMap. Over time, NotifierIds that no longer receive notifications leave zombie `TVar []` entries.

`deleteNtfs` (line 44) does remove the full entry via `TM.lookupDelete` — but only called when a notifier is explicitly deleted.

#### 4. `serviceLocks` in PostgresQueueStore — `Postgres.hs:112,469`

`serviceLocks :: TMap CertFingerprint Lock` — one Lock per unique certificate fingerprint.

`getCreateService` (line 469) calls `withLockMap (serviceLocks st) fp` which calls `getMapLock` (Agent/Client.hs:1029-1032) — this **unconditionally inserts** a Lock into the TMap. There is **no cleanup code** for serviceLocks anywhere. This is NOT guarded by `useCache`.

#### 5. `sentCommands` per proxy client connection — `Client.hs:580`

Each `PClient` has `sentCommands :: TMap CorrId (Request err msg)`. Entries are added per command sent (line 1369) and only removed when a response arrives (line 698). If a connection drops before all responses arrive, entries remain until the `PClient` is GC'd. Since `PClient` is captured by the connection thread which terminates on error, the `PClient` should become GC-eligible — but GC timing depends on heap pressure.

#### 6. `subQ :: TQueue (ClientSub, ClientId)` — `Env/STM.hs:363`

Unbounded `TQueue` for subscription changes. If the subscriber thread (`serverThread`) can't process changes fast enough, this queue grows without backpressure. With 22K clients subscribing/unsubscribing, sustained bursts could cause this queue to bloat.

---

### Ruled Out

1. **PostgreSQL queue cache**: `useCache = False` — `queues`, `senders`, `links`, `notifiers` TMaps are empty.
2. **`notifierLocks`**: Guarded by `useCache` (Postgres.hs:377,405) — not used with `useCache = False`.
3. **Client structures**: 22K × ~3KB = ~66MB — negligible.
4. **TBQueues**: Bounded (`tbqSize = 128`).
5. **Thread management**: `forkClient` uses weak refs + `finally` blocks. `endThreads` cleared on disconnect.
6. **Proxy `smpClients`/`smpSessions`**: Properly cleaned on disconnect/expiry.
7. **`smpSubWorkers`**: Properly cleaned on worker completion; also cleared in `closeSMPClientAgent`.
8. **`pendingEvents`**: Atomically swapped empty every `pendingENDInterval`.
9. **Stats IORef counters**: Fixed number, bounded.
10. **DB connection pool**: Bounded `TBQueue` with bracket-based return.

---

### Insufficient Data to Determine Root Cause

Without measuring the actual sizes of these structures at runtime, we cannot determine which (if any) is the primary contributor. The following exact logging changes will identify the root cause.

---

### EXACT LOGS TO ADD

Add a new periodic logging thread in `src/Simplex/Messaging/Server.hs`.

Insert at `Server.hs:197` (after `prometheusMetricsThread_`):

```haskell
        <> memoryDiagThread_ cfg
```

Then define:

```haskell
    memoryDiagThread_ :: ServerConfig s -> [M s ()]
    memoryDiagThread_ ServerConfig {prometheusInterval = Just _} =
      [memoryDiagThread]
    memoryDiagThread_ _ = []

    memoryDiagThread :: M s ()
    memoryDiagThread = do
      labelMyThread "memoryDiag"
      Env { ntfStore = NtfStore ntfMap
          , server = srv@Server {subscribers, ntfSubscribers}
          , proxyAgent = ProxyAgent {smpAgent = pa}
          , msgStore_ = ms
          } <- ask
      let interval = 300_000_000 -- 5 minutes
      liftIO $ forever $ do
        threadDelay interval
        -- GHC RTS stats
        rts <- getRTSStats
        let liveBytes = gcdetails_live_bytes $ gc rts
            heapSize = gcdetails_mem_in_use_bytes $ gc rts
            gcCount = gcs rts
        -- Server structures
        clientCount <- IM.size <$> getServerClients srv
        -- SubscribedClients (queue and service subscribers for both SMP and NTF)
        smpQSubs <- M.size <$> getSubscribedClients (queueSubscribers subscribers)
        smpSSubs <- M.size <$> getSubscribedClients (serviceSubscribers subscribers)
        ntfQSubs <- M.size <$> getSubscribedClients (queueSubscribers ntfSubscribers)
        ntfSSubs <- M.size <$> getSubscribedClients (serviceSubscribers ntfSubscribers)
        -- Pending events
        smpPending <- IM.size <$> readTVarIO (pendingEvents subscribers)
        ntfPending <- IM.size <$> readTVarIO (pendingEvents ntfSubscribers)
        -- NtfStore
        ntfStoreSize <- M.size <$> readTVarIO ntfMap
        -- ProxyAgent maps
        let SMPClientAgent {smpClients, smpSessions, activeServiceSubs, activeQueueSubs, pendingServiceSubs, pendingQueueSubs, smpSubWorkers} = pa
        paClients <- M.size <$> readTVarIO smpClients
        paSessions <- M.size <$> readTVarIO smpSessions
        paActSvc <- M.size <$> readTVarIO activeServiceSubs
        paActQ <- M.size <$> readTVarIO activeQueueSubs
        paPndSvc <- M.size <$> readTVarIO pendingServiceSubs
        paPndQ <- M.size <$> readTVarIO pendingQueueSubs
        paWorkers <- M.size <$> readTVarIO smpSubWorkers
        -- Loaded queue counts
        lc <- loadedQueueCounts $ fromMsgStore ms
        -- Log everything
        logInfo $
          "MEMORY "
            <> "rts_live=" <> tshow liveBytes
            <> " rts_heap=" <> tshow heapSize
            <> " rts_gc=" <> tshow gcCount
            <> " clients=" <> tshow clientCount
            <> " smpQSubs=" <> tshow smpQSubs
            <> " smpSSubs=" <> tshow smpSSubs
            <> " ntfQSubs=" <> tshow ntfQSubs
            <> " ntfSSubs=" <> tshow ntfSSubs
            <> " smpPending=" <> tshow smpPending
            <> " ntfPending=" <> tshow ntfPending
            <> " ntfStore=" <> tshow ntfStoreSize
            <> " paClients=" <> tshow paClients
            <> " paSessions=" <> tshow paSessions
            <> " paActSvc=" <> tshow paActSvc
            <> " paActQ=" <> tshow paActQ
            <> " paPndSvc=" <> tshow paPndSvc
            <> " paPndQ=" <> tshow paPndQ
            <> " paWorkers=" <> tshow paWorkers
            <> " loadedQ=" <> tshow (loadedQueueCount lc)
            <> " loadedNtf=" <> tshow (loadedNotifierCount lc)
            <> " ntfLocks=" <> tshow (notifierLockCount lc)
```

Note: `smpSubs.subsCount` (queueSubscribers size) and `smpSubs.subServicesCount` (serviceSubscribers size) are **already logged** in Prometheus (lines 475-496). The log above adds all other candidate structures plus GHC RTS memory stats.

This produces a single log line every 5 minutes:

```
[INFO] MEMORY rts_live=10737418240 rts_heap=23488102400 rts_gc=4521 clients=21927 smpQSubs=1847233 smpSSubs=42 ntfQSubs=982112 ntfSSubs=31 smpPending=0 ntfPending=0 ntfStore=512844 paClients=12 paSessions=12 paActSvc=0 paActQ=0 paPndSvc=0 paPndQ=0 paWorkers=3 loadedQ=0 loadedNtf=0 ntfLocks=0
```

### What Each Metric Tells Us

| Metric | What it reveals | If growing = suspect |
|--------|----------------|---------------------|
| `rts_live` | Actual live data after last major GC | Baseline — everything else should add up to this |
| `rts_heap` | Total heap (should be ~2× rts_live) | If >> 2× live, fragmentation issue |
| `clients` | Connected client count | Known: ~22K |
| `smpQSubs` | SubscribedClients map size (queue subs) | If >> clients × avg_subs, entries not cleaned |
| `smpSSubs` | SubscribedClients map size (service subs) | Should be small |
| `ntfQSubs` | NTF SubscribedClients map (queue subs) | Same concern as smpQSubs |
| `ntfSSubs` | NTF SubscribedClients map (service subs) | Should be small |
| `smpPending` / `ntfPending` | Pending END/DELD events per client | If large, subscriber thread lagging |
| `ntfStore` | NotifierId count in NtfStore | If growing monotonically, zombie entries |
| `paClients` | Proxy connections to other servers | Should be <= unique dest servers |
| `paSessions` | Active proxy sessions | Should match paClients |
| `paActSvc` / `paActQ` | Proxy active subscriptions | If growing, entries never removed |
| `paPndSvc` / `paPndQ` | Proxy pending subscriptions | If growing, resubscription stuck |
| `paWorkers` | Active reconnect workers | If growing, workers stuck in retry |
| `loadedQ` | Cached queues in store (0 with useCache=False) | Should be 0 |
| `ntfLocks` | Notifier locks in store | Should be 0 with useCache=False |

### Interpretation Guide

**If `smpQSubs` is in the millions**: SubscribedClients is the primary leak. Entries accumulate for every queue ever subscribed to.

**If `ntfStore` grows monotonically**: Zombie notification entries (empty lists after expiration). Fix: `deleteExpiredNtfs` should remove entries with empty lists.

**If `paActSvc` + `paActQ` grow**: Proxy agent subscription maps are the leak. Fix: add cleanup when no active/pending subs exist for a server.

**If `rts_live` is much smaller than `rts_heap`**: GHC heap fragmentation. Fix: tune `-F` flag (GC trigger factor) or use `-c` (compacting GC).

**If `rts_live` ~ 10-12GB**: The live data is genuinely large. Look at which metric is the largest contributor.

**If nothing above is large but `rts_live` is large**: The leak is in a structure not measured here — likely TLS connection buffers, ByteString retention from Postgres queries, or GHC runtime overhead. Next step would be heap profiling with `-hT`.
