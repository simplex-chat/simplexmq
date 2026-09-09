# SMP server: memory leaks and CPU/RAM exhaustion paths

Date: 2026-09-08
Scope: server-side code at HEAD 200129af. Defensive review for the operator. All file:line references verified against the current tree.

## Summary

Scope is the PostgreSQL backend only (`store_queues: database`, `store_messages: database`), which selects `SSCDatabase` -> `PostgresMsgStore`. In that backend the queue store is created with `useCache = False` (`MsgStore/Postgres.hs:100`) and `getMsgQueue` is a no-op (`:172`), so there is no in-memory queue cache and no journal message files.

Consequence: the queue-cache and journal issues below do not occur on this backend. Specifically, memory-leaks 1 and 2 (queue cache) require `useCache = True`, which only the journal-with-Postgres-queues mode (`store_messages: journal`) uses; and the SUBS journal-FD spike requires journal files. On PostgreSQL, SUBS is a single streaming DB query (`MsgStore/Postgres.hs:122`), with no FD/RAM spike.

Real CPU/RAM issues on the PostgreSQL backend (all store-independent): unauthenticated RSLV outbound fan-out, the proxy session never torn down on forward timeout, the absence of any global connection/thread cap, and the service `subscriptions` map not pruned on ACK. Reproduction tests: `testRslvFanOut` and `testProxyForwardTimeoutStuckSession`. No fixes are applied. Verified against a local PostgreSQL (`server_postgres` build).

## Memory leaks

### 1. Queue cache retains deleted queues (not the PostgreSQL backend)

Only with `useCache = True` (journal-with-Postgres-queues mode). The pure PostgreSQL backend uses `useCache = False`, so the `queues` cache is never populated and nothing leaks. Documented for completeness.

`deleteStoreQueue` nulls the queue's `queueRec` TVar and cleans the `senders`, service, and notifier maps, but never removes the entry from the `queues` map.

- STM: `QueueStore/STM.hs` (no `TM.delete rId queues`).
- Postgres: `QueueStore/Postgres.hs:451-464` (sets `deleted_at`, nulls `queueRec`, never removed from the cache; `compactQueues` at `:148-152` deletes DB rows only).
- Add sites: STM `QueueStore/STM.hs:126`; Postgres `:182` and `:245` (any load caches).

Effect: each create+delete cycle leaves a permanent `STMQueue`/`JournalQueue` object with its TVars. A client looping NEW then DEL grows RAM without bound; freed only by restart. `getEntityCounts` counts `M.size queues` (`QueueStore/STM.hs:101`), so the reported `queueCount` also drifts up. Reproduced on STM, Journal, and Postgres+journal: 200 create+delete cycles retain 200 cache entries.

Fix direction: drop the entry from the cache on delete in both stores. Safe because `loadQueue` filters `AND deleted_at IS NULL` (`QueueStore/Postgres.hs:231,286,309`), so a deleted queue is never reloaded.

```haskell
delete q = do
  writeTVar qr Nothing
  TM.delete rId $ queues st   -- add: drop deleted queue from the cache
  TM.delete senderId $ senders st
  ...
```

### 2. Postgres queue cache has no eviction (not the pure PostgreSQL backend)

Only with `useCache = True` (journal-with-Postgres-queues mode). The pure PostgreSQL backend (`store_messages: database`) uses `useCache = False`, so there is no cache to grow. Documented for completeness.

Every distinct queue touched by SUB/SEND/NSUB/GET is cached in `queues` via `cacheQueue` (`QueueStore/Postgres.hs:245`) and removed only on delete. There is no idle or size-based eviction, so the working set trends toward every queue accessed since boot, defeating the purpose of the database backing store. `idleQueueInterval` (`Env/STM.hs:233`, 4h) closes journal message-queue handles, not this cache. Requires the Postgres backend.

### 3. Service subscriptions map not pruned on ACK

A receiving-service client's `subscriptions` map gains a `Sub` per delivered queue at `Server.hs:1896` (initial scan) and `Server.hs:2073` (`newServiceDeliverySub` on each SEND to an associated queue). `acknowledgeMsg` (`Server.hs:1929-1951`) clears delivery state but never deletes the map entry. Entries are removed only on queue delete, unassociation, or disconnect. A long-lived service session grows toward the number of associated queues regardless of ACKs.

### 4. Notification store grows without a subscriber (not fixed)

`storeNtf` prepends to a per-notifier list with no bound (`NtfStore.hs:37-42`). The list is drained only by an active notifier subscription or the notification TTL (default 24h, `Env/STM.hs:238-243`). With no notifier subscribed, one entry accumulates per notification-flagged SEND. `deleteExpiredNtfs` also leaves the emptied notifier key in the outer map (`NtfStore.hs:57-61`).

Not fixed here: the per-notifier list is TTL-bounded, and the empty-key retention is bounded by the number of active notifiers (freed on queue/notifier delete), so it is not truly unbounded. Removing the emptied key in `deleteExpiredNtfs` races with `storeNtf`, which reads the outer map outside a transaction; a safe fix requires making `storeNtf` fully transactional, which changes a hot path. Deferred as not worth that trade.

### 5. Proxy client maps grow with distinct PRXY targets

`smpClients` (keyed by `SMPServer`) and `smpSessions` grow per distinct proxied relay. On connect failure with `persistErrorInterval /= 0` (default 30s), the error var is kept in `smpClients` (`Client/Agent.hs:245-247`) and removed only lazily on re-query. Client-controlled `PRXY srv` targets make the target set attacker-chosen.

### 6. Blocked writer threads on a stuck relay

When a relay stops draining, the proxy client's `sndQ` fills and each further command forks a thread parked in `writeTBQueue` (`Client.hs:1367-1370`), each retaining a `Request`. This is the memory amplifier of the proxy stuck-session issue.

### 7. sentCommands entries leak for unanswered commands

`getResponse` sets `pending = False` on timeout but does not delete the `sentCommands` entry (`Client.hs:1372-1383`); removal happens only on a matching response (`Client.hs:704`). Commands a relay never answers stay for the connection lifetime.

## CPU/RAM exhaustion paths

Ranked by ease of trigger times impact.

1. No global connection cap plus a 120s handshake hold. Sockets are accepted and handlers forked with no admission control (`Transport/Server.hs:176-184`); the SMP handshake may hang for `smpHandshakeTimeout` (`Main.hs:535`, 120s). Unauthenticated thread, FD, and buffer exhaustion.
2. `PRXY` establishes an outbound TLS connection to an arbitrary client-named host and port (`Server.hs:1417-1429`), which is server-side request forgery plus unbounded cached outbound sessions. Gated by `allowSMPProxy` and optional `newQueueBasicAuth`; open on public relays.
3. `NEW` creates a persistent queue with keys, a store-log record, and disk state (`Server.hs:1569-1628`), with no maximum queue count. On public or no-password servers this is unauthenticated and compounds leak 1.
4. `RSLV` forks up to `serverResolverConcurrency` (1000) outbound HTTP requests per connection through a per-client counter with no global cap (`Server.hs:1279,1522`, `Env/STM.hs:256`). Only when `[NAMES]` is enabled. No result cache (`Names.hs:61-74`).
5. `SUBS` on a recipient service folds over every queue of the service and reruns on every reconnect since `hasSub` is false on a fresh connection. On the PostgreSQL backend this is one streaming DB query joining each service queue with its head message (`MsgStore/Postgres.hs:122`): O(N) DB work, but no journal opens and no FD/RAM spike (the journal-open spike, `Journal.hs:449-467`, is journal-mode only). The store-independent cost that remains is the service `subscriptions` map growing (leak 3).
6. `RFWD` runs one X25519 DH per request inline on the connection thread before validating the inner ciphertext (`Server.hs:2129`), unauthenticated (`Server.hs:1278`).
7. Batch multiplier: one 16 KB block carries up to 255 transmissions (`Protocol.hs:2292`), multiplying every per-command cost. Unknown-queue transmissions still run a full signature verify via the dummy-verify path (`Server.hs:1345-1350`).

Interaction: `RSLV` (limit 1000) and `PRXY`/`PFWD` (limit 32) share one `procThreads` counter (`Server.hs:1476-1489`), so an RSLV flood also starves proxying on the same connection.

## Config-gated exposure to confirm

- `newQueueBasicAuth`: gates NEW and PRXY. Absent on public servers by design.
- `allowSMPProxy`: enables PRXY (hardcoded true in the default config path, `Main.hs:610`).
- `[NAMES] enable`: gates RSLV.

## Reproduction tests

Two store-independent issues have sound reproductions on the PostgreSQL backend. Both are pending (`xit`) specs asserting the correct behavior, each verified to fail (reproduce) when activated (`it`).

- `tests/RSLVTests.hs`
  - `testRslvFanOut`: one connection must not fan out to many concurrent resolver requests. Verified: 64 concurrent from one connection.
- `tests/SMPProxyTests.hs`
  - `testProxyForwardTimeoutStuckSession`: after repeated forward timeouts the session must be dropped, so a later forward returns `NO_SESSION`. Verified: all 10 forwards return `BROKER TIMEOUT` (session never torn down; the operator-reported `pMsgFwdsOwn_pErrorsOther`).

Running the Postgres tests requires a local PostgreSQL with roles `test_server_user` and `postgres` and database `test_server_db`, reachable via the default Unix socket (set `PGHOST`) and `localhost:5432`, plus a `-fserver_postgres` build.

## Sanity of the reproductions

Verified by tracing the exercised code path.

- `testRslvFanOut`: sound, store-independent, timing-based. Full E2E: real RSLV commands to a real names-enabled server; a 3s resolver delay vs a 0.8s sample separates concurrent from sequential; 64 outbound requests are in flight from one connection. `managerConnCount = 10` does not serialize them (64 confirmed). Couples to a resolver-limit the fix must add and the test set.
- `testProxyForwardTimeoutStuckSession`: sound, store-independent. Real PFWD path; 10 forwards on one session all return `BROKER TIMEOUT`, none `NO_SESSION`, so the session is never torn down. Asserts the desired behavior, so it fails now and passes once a teardown/circuit-breaker fix lands.

Issues without a sound reproduction on the PostgreSQL backend:

- Queue cache leak / no eviction (memory-leaks 1, 2): do not occur, `useCache = False`. The earlier `testDeleteQueueNoLeak`/`testPostgresCacheBounded` only reproduced in journal/cache modes and were removed.
- SUBS journal-FD spike: journal-mode only; `getMsgQueue` is a no-op on PostgreSQL. The earlier `testSubsServiceScanBounded` was removed.
- Global admission control: not testable black-box. `connect()` succeeds regardless of an app-level cap (kernel backlog), and an admission fix accepts-then-closes rather than refusing the connect, so a black-box client cannot distinguish fixed from unfixed. Needs a configurable connection cap the test can set or a server-exposed active-connection metric.
- Service `subscriptions` map not pruned on ACK (memory-leaks 3): real and store-independent, but not reproduced here; needs a messaging-service (service-cert) client that SUBS then receives and ACKs, asserting the map does not grow.

Note on issue 6: task 6 is "bound proxy writer threads to a stuck relay" (`nonBlockingWriteTBQueue` forking when the relay stops reading). The shipped test does not reproduce that; it reproduces the related, higher-impact and operator-observed "session not torn down on forward timeout". The writer-thread fork bomb needs a relay that accepts TCP but stops reading, and `nonBlockingWriteTBQueue` is not exported, so it is not reproduced here.

## Fix directions (general)

Sketches only, one per high-impact issue. Not applied.

Issue 1, drop deleted queues from the cache (both stores):

```haskell
delete q = do
  writeTVar qr Nothing
  TM.delete rId $ queues st   -- add
  ...
```

Issue 2, evict the Postgres queue cache working set (idle or bounded LRU):

```haskell
-- periodic sweep, or on insert past a size bound:
evictIdleQueues st now = atomically $
  modifyTVar' (queues st) (M.filter (not . idleSince now))   -- keep only recently used
```

Issue 3, bound the SUBS scan: close each queue after peek and paginate; do not rerun the full scan on every reconnect:

```haskell
f' a (q, qr) =
  (runExceptT (tryPeekMsg ms q) >>= f a (recipientId q) . ...) `finally` closeMsgQueue ms q
```

Issue 4, global RSLV concurrency cap (semaphore in NamesEnv, acquired around the outbound call):

```haskell
data NamesEnv = NamesEnv { ..., resolverSem :: TVar Int, resolverLimit :: Int }

withResolverSlot NamesEnv {resolverSem, resolverLimit} =
  bracket_ (atomically $ readTVar resolverSem >>= \n -> if n >= resolverLimit then retry else writeTVar resolverSem (n + 1))
           (atomically $ modifyTVar' resolverSem (subtract 1))
```

Issue 5, global connection admission at accept (refuse beyond a cap):

```haskell
-- in the accept loop: gate on a shared counter before forking the handler
n <- atomically $ stateTVar activeConns (\n -> (n, n + 1))
if n >= maxConns then close sock else forkHandler sock `finally` atomically (modifyTVar' activeConns (subtract 1))
```

Issue 6, bound proxy writers and add a forward-timeout circuit breaker:

```haskell
-- fail fast instead of forking an unbounded blocked writer:
nonBlockingWriteTBQueue q x = atomically (tryWriteTBQueue q x)
  >>= (`unless` throwIO PCEResponseTimeout)   -- or count and drop
-- and drop the relay session after N consecutive forward timeouts (independent of received bytes)
```

Also: prune the service `subscriptions` entry on ACK (leak 3, `acknowledgeMsg`); the ntf empty-key (leak 4) needs a transactional `storeNtf` first.

## Additional findings (verified 2026-09-09)

Found by a subagent sweep of the PostgreSQL backend and store-independent hot paths, then each confirmed by reading the cited code. Not yet fixed or tested (except where noted).

Attacker-triggerable (DoS):

1. Batched crypto + per-transmission DB SELECT amplification (HIGH). `dummyVerifyCmd` runs a real Ed25519/Ed448 verify or attacker-chosen X25519 DH per transmission on an unknown queue (`Server.hs:1345-1350`). SEND is a non-batch party (`batchParty` = Recipient/Notifier only, `Protocol.hs:420-423`), so it uses the per-transmission path `mapM (verifyTransmission ...)` (`Server.hs:1167`): one crypto op plus one `getQueueRec` DB SELECT (no cache) per transmission. A 16 KB block holds ~130-250 transmissions (`Protocol.hs:2292`), so one write by any handshake-completing peer causes ~130-250 asymmetric verifications and ~130-250 individual SELECTs. Testable.
2. `clientService` handshake grows the `services` table without bound (MED-HIGH). `getClientService` accepts a self-signed chain (`CCSelf`, `Transport.hs:755-768`) and verifies an attacker cert per connection; `getCreateService` inserts a `services` row on any new cert fingerprint (`QueueStore/Postgres.hs:469-482`). A fresh self-signed cert per handshake yields an unbounded persistent row per connection, pre-auth. Testable (count rows across N handshakes).
3. Unbounded delivery threads to a slow consumer (MED). When a subscribed recipient's `sndQ` is full, `tryDeliverMessage` forks a bare `forkIO` parked on `writeTBQueue` (`Server.hs:2068-2072,2085-2105`), not gated by `procThreads`. One blocked thread per queue for a slow consumer subscribed to many queues.

Operational / scale:

4. DB pool is the throughput ceiling (HIGH for scale). Default `poolSize=10` (`Main/Init.hs:44`), one MVar-gated pool shared by all clients. Each SEND is 3 transactions: `getQueueRec` + `deleteExpiredMsgs` + `writeMsg`, and `expireMessagesOnSend=True` by default (`Main.hs:563`, `Server.hs:2004`) forces the middle one on every SEND to a non-empty queue. A second pool (`dbPriorityPool`, another `poolSize` backends) is opened but never used by the SMP server (no `withTransactionPriority _ True` in server code) -> 2xpoolSize backends, half idle.
5. Prometheus scrape cost (MED-HIGH, if enabled). Every `prometheus_interval` (default 60s), `getDeliveredMetrics` folds over all clients x all subscriptions in memory (`Server.hs:723-734`) and `getEntityCounts` runs 6 `COUNT(1)` scans over `msg_queues`/`services` (`QueueStore/Postgres.hs:154-170`, `Server.hs:699`).
6. Subscription serialization bottleneck (MED). All subscription churn funnels through one `subQ` + one `serverThread` mutating the single `queueSubscribers` Map-in-a-TVar (`Server.hs:263-360`, `Env/STM.hs:375-391`); a batched SUB of N queues is N separate STM writes to one contended TVar.

Lower / noted (chain verified, not deep-dived): `expire_old_messages` does a full `COUNT(1) FROM messages` every 2h; legacy non-service `deliverNtfsThread` is O(ntf-clients x pending) every 1.5s; `PeriodStats` week/month `IntSet`s grow with distinct active queues; no server-side prepared statements; full-row queue decode per command.
