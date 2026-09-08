# Notification delivery: performance and scaling analysis (NTF <-> SMP)

## TL;DR

The NTF server's notification path from "SMP relay pushes NMSG" to "APNS delivery" is
bottlenecked by a single ingestion thread that performs a synchronous multi-statement
Postgres transaction per message, and that thread is blocked by downstream backpressure.
Any slowdown in the database, in APNS, or a resubscription burst propagates back up the
pipeline, fills the shared 2048-slot ingestion queue, and stalls message intake for every
relay at once. This is the mechanism behind the queue spikes and latency.

All findings were read directly in source. Full paths and line numbers are verified.

## Verified pipeline

```
N SMP relays (one SMPClient each, own TCP; per-conn sndQ/rcvQ bound 64, Client.hs:492)
   |  each conn's process thread: blocking writeTBQueue          Client.hs:693
   v
msgQ  - one shared TBQueue, bound 2048, all relays               Client/Agent.hs:127,166
   |
   v  one consumer thread: receiveSMP                            Notifications/Server.hs:533
   |     per message, inline and synchronous:
   |       addTokenLastNtf -> Postgres txn (SELECT ... FOR UPDATE OF t,s + CTE upsert/delete)   Notifications/Server.hs:551 ; Store/Postgres.hs:654
   |       pushNotification -> blocking writeTBQueue into a push shard                          Notifications/Server.hs:553,647
   v
push workerQ - 8 shards per (relay,provider), bound 32768 each   Notifications/Server.hs:650 ; Main.hs:177
   |
   v  runPushWorker: 1 thread/shard, awaits each APNS round-trip Notifications/Server.hs:676
   v
one shared HTTP/2 connection per provider                        Env.hs:180 ; Push/APNS.hs:224,349
```

Paths are relative to `src/Simplex/Messaging/`.

Verified constants:

- `msgQSize = Just 2048` — src/Simplex/Messaging/Client/Agent.hs:127
- `agentQSize = 2048` — src/Simplex/Messaging/Client/Agent.hs:128
- `agentSubsBatchSize = 1360` — src/Simplex/Messaging/Client/Agent.hs:129
- SMP connection `qSize = 64` (sndQ/rcvQ) — src/Simplex/Messaging/Client.hs:492,587-588
- `pushQSize = 32768` — src/Simplex/Messaging/Notifications/Server/Main.hs:177
- `pushWorkersPerServer = 8` — src/Simplex/Messaging/Notifications/Server.hs:650
- `poolSize = 10` per pool, two pools per store — src/Simplex/Messaging/Notifications/Server/Main.hs:254 ; src/Simplex/Messaging/Agent/Store/Postgres/Common.hs:34-49
- `subsBatchSize = 900` — src/Simplex/Messaging/Notifications/Server/Main.hs:197
- `periodicNtfsInterval = 5 min` — src/Simplex/Messaging/Notifications/Server/Main.hs:212

## Findings

| # | Finding | Severity | Evidence (verified) |
|---|---------|----------|---------------------|
| 1 | Single `receiveSMP` thread runs one synchronous DB transaction per message. Server-wide throughput ceiling is `1 / DB-round-trip`, independent of relay count or cores. The 10-connection pool cannot help a single caller. | High | src/Simplex/Messaging/Notifications/Server.hs:533,551 ; src/Simplex/Messaging/Notifications/Server/Store/Postgres.hs:654-711 |
| 2 | Push enqueue runs on the ingestion thread. A full push shard (or APNS/DB latency) blocks `receiveSMP`, back-propagating to fill `msgQ` and stall all relays. | High | src/Simplex/Messaging/Notifications/Server.hs:553,647 |
| 3 | One shared HTTP/2 connection per provider. A single device's 503 closes it for all workers, and `retryDeliver` evicts the shared client via `removeSessVar`. 429 is unhandled and drops the push. | High | src/Simplex/Messaging/Notifications/Server/Env.hs:180 ; src/Simplex/Messaging/Notifications/Server/Push/APNS.hs:224,349,379-381 ; src/Simplex/Messaging/Notifications/Server.hs:714-726 |
| 4 | `SELECT ... FOR UPDATE OF t,s` serializes all notifications for one token. Token metadata (status, DH secret, subscription id) is re-read from Postgres on every message; the STM cache in `Store.hs` is not wired into the Postgres store. | High | src/Simplex/Messaging/Notifications/Server/Store/Postgres.hs:659-670 |
| 5 | Subscription status triggers are `FOR EACH ROW`. Each row change runs `UPDATE smp_servers ... xor_combine(...)`, taking a row lock on the parent server row; `xor_combine` is a per-byte plpgsql loop. A batch of N status updates fires N triggers, N server-row updates, N byte-loops in one transaction. | High | src/Simplex/Messaging/Notifications/Server/Store/ntf_server_schema.sql:72-124,283-291 |
| 6 | Priority pool default `poolSize = 10` caps hot-path DB concurrency; checkout is serialized behind an MVar. Only relevant once finding 1 is parallelized. | High (latent) | src/Simplex/Messaging/Notifications/Server/Main.hs:254 ; src/Simplex/Messaging/Agent/Store/Postgres/Common.hs:34-66 |
| 7 | Reconnect resubscribes a relay's full filtered set in chunks of 1360; startup fans out over all relays with `mapConcurrently` and no concurrency cap or pacing; `nextRetryDelay` is deterministic with no jitter. A shared network event resubscribes many relays in lockstep. | Med-High | src/Simplex/Messaging/Client/Agent.hs:352-365 ; src/Simplex/Messaging/Notifications/Server.hs:463 ; src/Simplex/Messaging/Agent/RetryInterval.hs:114-118 |
| 8 | `sendBatch` forks one thread per in-flight request via `mapConcurrently`. `nonBlockingWriteTBQueue` forks an unbounded blocked writer thread when the 64-deep `sndQ` is full. | Med | src/Simplex/Messaging/Client.hs:1335,1367-1370,492 |
| 9 | Periodic cron (`withPeriodicNtfTokens`) streams due tokens with `DB.fold` inside a transaction and enqueues each push inside that transaction, holding one pool connection open for the whole scan. A full push queue extends the held transaction. | Med | src/Simplex/Messaging/Notifications/Server/Store/Postgres.hs:467-471 ; src/Simplex/Messaging/Notifications/Server.hs:748-757 |
| 10 | `agentQ` status updates are also single-consumer with inline DB writes; per-relay `subscriberSubQ` is unbounded; live subscriptions are sent one at a time. | Med | src/Simplex/Messaging/Notifications/Server.hs:503,521-527,569-607 |
| 11 | `getEntityCounts` runs `count(1)` full scans on `tokens` and `last_notifications` every Prometheus interval. `subscriptions` already uses the cheap `reltuples` estimate; these two do not. | Med | src/Simplex/Messaging/Notifications/Server/Store/Postgres.hs:723-729 |
| 12 | No metric for `msgQ` depth. The leading indicator of ingestion stall is not observable; only push-queue depth is exported. | Med | src/Simplex/Messaging/Notifications/Server.hs:276,737-745 |
| 13 | APNS uses `sendRequestDirect` with no per-request timeout (falls back to the 25s connect timeout), and it is documented as unsafe until HTTP/2 is thread-safe, yet 8 shards call it concurrently on the shared connection. | Med | src/Simplex/Messaging/Notifications/Server/Push/APNS.hs:349 ; src/Simplex/Messaging/Transport/HTTP2/Client.hs:196 |

## Recommended fixes, in priority order

1. Break the single-consumer plus synchronous-DB cap (findings 1, 4). Either shard `receiveSMP`
   by token hash across workers, or route into per-shard queues and run `addTokenLastNtf` on a
   worker pool. Add a batched `addTokenLastNtf` that consumes the whole `NonEmpty` already
   delivered per `msgQ` read in one transaction. Reconsider `FOR UPDATE OF t`: the token row is
   only read here.
2. Decouple ingestion from delivery (finding 2). Do not let a push enqueue block `receiveSMP`;
   use a non-blocking write with a drop-or-coalesce path. The payload already carries the last
   notifications, so dropping a stale enqueue is safe.
3. Fix the shared APNS connection (finding 3). Use a connection pool per provider, stop tearing
   down the connection on a per-device 503, handle 429 with jittered backoff and sender-side rate
   limiting, and pass an explicit short per-request timeout.
4. Make the subscription-aggregate trigger statement-level (finding 5) so a batch of N status
   updates does not fire N row-locking server-row updates.
5. Pace resubscription (finding 7): cap relay-level concurrency at startup and reconnect, and add
   jitter to `nextRetryDelay`.
6. Add a `lengthTBQueue msgQ` metric (finding 12) so the spike is diagnosable, then measure before
   the larger redesign.

## Confidence and limits

The structure of every finding is verified in source at the cited lines. Magnitudes are not
measured. The throughput ceiling in finding 1 is a round-trip estimate; actual numbers depend on
DB latency and message locality and should be confirmed with the `msgQ`-depth metric and DB timing
under load before committing to a redesign. Findings 4 and 6 only pay off after finding 1 is
parallelized; raising pool size alone changes nothing while the consumer is single-threaded.
