## Root Cause Analysis: SMP Server Memory Growth (23.5GB)

### Log Summary

- **Duration**: ~22 hours (Mar 16 12:12 → Mar 17 10:20)
- **92,277 proxy connection errors** out of 92,656 total log lines (99.6%)
- **292 unique failing destination servers**, top offender: `nowhere.moe` (12,875 errors)
- Only **145 successful proxy connections**

---

### Root Cause #1 (PRIMARY): PostgreSQL Queue Cache Never Evicts

**Files**: `src/Simplex/Messaging/Server/QueueStore/Postgres.hs`

The Postgres queue store has `useCache = True` hard-coded (via `Journal.hs:429`). Every queue accessed or created gets inserted into `queues :: TMap RecipientId q` and **is never removed**, even after deletion.

**Evidence** — `deleteStoreQueue` at Postgres.hs:448-465:
```haskell
deleteStoreQueue st sq = ... do
    atomically $ writeTVar qr Nothing     -- QueueRec set to Nothing...
    when (useCache st) $ do
      atomically $ TM.delete (senderId q) $ senders st      -- ✅ cleaned
      forM_ (notifier q) $ \NtfCreds {notifierId} -> do
        atomically $ TM.delete notifierId $ notifiers st     -- ✅ cleaned
        atomically $ TM.delete notifierId $ notifierLocks st -- ✅ cleaned
    -- ❌ NO TM.delete rId $ queues st  — zombie entry stays forever!
```

Similarly, `links :: TMap LinkId RecipientId` is never cleaned on queue deletion.

**Impact**: Every queue created and then deleted leaves a zombie in the `queues` map (~200 bytes minimum per entry). On a busy server like smp19 running for days/weeks:
- Millions of queues created/deleted → millions of zombie cache entries
- Active queues also stay cached forever once loaded from Postgres
- **This is the primary unbounded growth mechanism**

The `loadedQueueCount` Prometheus metric would confirm this — it shows the size of this cache (Prometheus.hs:500).

---

### Root Cause #2 (AMPLIFIER): GHC Heap Sizing with `-A16m -N`

**RTS flags**: `+RTS -N -A16m -I0.01 -Iw15 -s -RTS`

With 16 cores:
- **Nursery**: 16 × 16MB = **256MB baseline**
- GHC's default major GC threshold = **2× live data** — if live data is 10GB, GHC allows the heap to grow to **~20GB before triggering major GC**
- VIRT = 1031GB is normal for GHC (address space reservation, not actual memory)

The `-I0.01` setting is aggressive for idle GC (10ms), but with 22K clients the server is rarely idle, so major GC is deferred.

---

### Root Cause #3 (CONTRIBUTOR): No Cache Eviction by Design

Looking at `getQueue_` in Postgres.hs:193-244:
- When `useCache = True`, queues are loaded from Postgres on first access
- They are cached in the `queues` TMap **forever**
- There is no LRU eviction, no TTL, no max cache size
- The comment at line 233 acknowledges interaction with `withAllMsgQueues` but no eviction mechanism exists

---

### What is NOT the Main Cause

1. **Proxy connection state (`smpClients`)**: Properly managed — one entry per destination server, cleaned after 30-second `persistErrorInterval`. Max 292 entries. Code at `Client/Agent.hs:196-242` and `Session.hs:24-39` is correct.

2. **SubscribedClients**: Despite the misleading comment at `Env/STM.hs:376` saying "subscriptions are never removed," they ARE cleaned up on both client disconnect (`Server.hs:1112`) and queue deletion (`Server.hs:308` via `lookupDeleteSubscribedClient`).

3. **Client structures**: 22K × ~3KB = ~66MB — negligible.

4. **TBQueues**: Bounded (`TBQueue` with `tbqSize = 128`), properly sized.

5. **Thread management**: `forkClient` uses weak references, `finally` blocks ensure cleanup. Well-managed.

---

### Memory Budget Estimate

| Component | Estimated Size |
|-----------|---------------|
| Postgres queue cache (growing) | **5-15+ GB** |
| TLS connection state (22K × ~30KB) | ~660 MB |
| GHC nursery (16 × 16MB) | 256 MB |
| Client structures | ~66 MB |
| Proxy agent state | ~50 KB |
| **GHC old gen headroom (2× live)** | **doubles effective usage** |

---

### Recommended Fixes (Priority Order)

**1. Remove zombie queue entries from cache on deletion** (immediate fix)

In `deleteStoreQueue` in `Postgres.hs`, add `TM.delete rId $ queues st` and `forM_ (queueData q) $ \(lnkId, _) -> TM.delete lnkId $ links st`:

```haskell
-- After the existing cleanup:
when (useCache st) $ do
  atomically $ TM.delete rId $ queues st          -- ADD THIS
  atomically $ TM.delete (senderId q) $ senders st
  forM_ (queueData q) $ \(lnkId, _) ->
    atomically $ TM.delete lnkId $ links st        -- ADD THIS
  forM_ (notifier q) $ \NtfCreds {notifierId} -> do
    atomically $ TM.delete notifierId $ notifiers st
    atomically $ TM.delete notifierId $ notifierLocks st
```

**2. Add configuration option to disable cache** — allow `useCache = False` via INI config for Postgres deployments where the DB is fast enough.

**3. Add cache eviction** — periodically evict queues not accessed recently (LRU or TTL-based).

**4. Tune GHC RTS**:
- Add `-F1.5` (or lower) to reduce the major GC threshold multiplier from default 2.0
- Consider `-M<limit>` to set a hard heap cap
- Consider `-N8` instead of `-N` to halve the nursery size and reduce per-capability overhead

**5. Add observability** — log `loadedQueueCount` periodically to track cache growth. This metric exists in Prometheus but should also appear in regular stats logs.
