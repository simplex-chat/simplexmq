# SMP server leak findings

Found with `bench/MemBench.hs` using a proxy-plus-relay topology and a transport that adds latency
and drops replies. Journal store and PostgreSQL gave the same numbers except where a row says
otherwise.

Eleven findings: three proxy-path memory leaks (Leak 1-3), two `forkClient` bugs (Bug 3-4), an
unauthenticated resolver fan-out (Bug 5), and five PostgreSQL-backend costs (Bug 6-10). The TLS/TCP
stack is clean (last two sections).

## Overview

| # | Issue | Reachable | Backend | Evidence | Status |
| --- | --- | --- | --- | --- | --- |
| Leak 1 | Forwarded commands not removed on timeout | Client, pre-auth (PRXY) | all | measured | present |
| Leak 2 | Failed relay connects not cleared | Client, pre-auth (PRXY) | all | measured | present |
| Leak 3 | Proxy relay queue has no reader | Client, pre-auth (PRXY) | all | measured | fixed, #1839 |
| Bug 3 | Proxy concurrency limit does nothing | Client, pre-auth (PRXY) | all | measured | present |
| Bug 4 | Stale `endThreads` entry on fast finish | Client, limited window | all | isolation only | present |
| Bug 5 | RSLV resolver fan-out | Client, if `[NAMES]` on | all | measured | present |
| Bug 6 | SEND is three DB transactions | authenticated SEND | postgres | code review | present |
| Bug 7 | Per-transmission verify and DB lookup | Client, pre-auth | postgres | code review | present |
| Bug 8 | Service handshake grows `services` table | Client, pre-auth | postgres | code review | present |
| Bug 9 | Prometheus scrape scans everything | internal, periodic | postgres | code review | present |
| Bug 10 | Subscription churn serialized | authenticated SUB | all | code review | present |

Leak 1, Leak 2, Leak 3, and Bug 3 share one entry point. `PRXY` is unauthenticated unless
`newQueueBasicAuth` is set (`Server.hs:1534`) and it names an arbitrary destination, so a client can
point the proxy at a relay it controls.

---

## Leak 1: forwarded commands are never removed on timeout

| | |
| --- | --- |
| Reachable | any client, pre-auth via PRXY |
| Trigger | relay replies to some forwards, drops others |
| Cost | ~20 KiB per stuck forward, unbounded |
| Measured | yes, 64 to 1280 entries over 20 min on one session |
| Status | present |

### How it works

When the agent forwards a command it stores the in-flight command in `sentCommands`, keyed by
correlation id, so the reply can be matched later. The entry is added in `mkTransmission_`
(`Client.hs:1414`) and removed in `processMsg` (`Client.hs:706`) when the reply arrives. Each `RFWD`
entry holds the whole forwarded command, 16226 bytes (`Protocol.hs:319`).

### The bug

The timeout path, `getResponse` (`Client.hs:1378`), does not hold the map, so a forward that times
out is never removed. The session does not die either: `monitor` (`Client.hs:668`) closes the client
only after `timeoutErrorCount >= smpPingCount` with nothing received for 900s, and `receive`
(`Client.hs:663`) resets both counters on any inbound transmission.

### Impact

About 20 KiB per unanswered forward. How long it is held depends on the relay.

| Relay behaviour | Result |
| --- | --- |
| slow but still replies | not a leak here, the late reply deletes the entry (but see Leak 3) |
| goes fully silent | bounded, `monitor` closes the client at ~20 min |
| replies to some, drops others | unbounded |

The third case is the leak. Any arriving reply resets `lastReceived` and `timeoutErrorCount`, so the
drop condition is never met. Measured with 1 in 3 relay writes dropped: `proxy_sentCommands` climbed
64 to 1280 over 20 minutes, linear at 64/min, zero disconnects. That is ~1.3 MiB/min on one session.
Traffic has to be ongoing; stop the flood and it is reclaimed after 20 minutes.

The ntf server runs the same client code and is exposed the same way through unanswered `NSUB`.
Measured with `subtmo 200`: 200 timed-out subscriptions, `sentCommands` 0 to 200, ~1.76 KiB each. At
the ntf batch size of 1360 that is ~2.3 MiB per unanswered batch.

Pings do not help. Subscribe paths call `enablePings` (`Client.hs:953`) and the proxy send path does
not, but in the unbounded case replies are arriving anyway and reset the counters.

### Fix

Deleting on timeout is wrong: the agent still needs late replies. `processMsg` forwards them as
`STResponse` (`Client.hs:713`) and the agent acts on them, so a late `OK`/`SOK` to a `SUB` brings a
connection back up and a late `MSG` is processed. Deleting would turn both into `STUnexpectedError`.

Delete by age instead. Record the insert time on `Request` and remove `pending == False` entries once
a late reply is no longer useful. The cutoff needs the agent's recovery behaviour measured, which is
not done here. Two paths can be deleted immediately because no reply is coming: `sendRecv` returns
early on transport error (`Client.hs:1364`) and on an oversized block (`Client.hs:1366`) without
sending.

---

## Leak 2: failed relay connects are never cleared

| | |
| --- | --- |
| Reachable | any client, pre-auth via PRXY |
| Trigger | forward to distinct dead addresses |
| Cost | ~19 KiB per address, held for the process lifetime |
| Measured | yes, 300 entries from 300 dead addresses |
| Status | present |

### How it works

Relay clients are cached in `smpClients`. A successful connect caches the client; a failed connect
caches the error as `Left (error, expiry)` (`Client/Agent.hs:277`) so repeat lookups fail fast until
the expiry passes.

### The bug

Nothing removes a failed entry on a timer. It is dropped only when the same server is looked up again
and found expired (`:253`, `:414`). The other removals are `clientDisconnected` (`:314`, connected
clients only) and shutdown (`:430`). Conditional on `persistErrorInterval > 0`; at 0 the entry is
removed at once, but production sets 30 (`Server/Main.hs:608`).

### Impact

Host, port and key hash come from the client, so distinct addresses are unlimited. Measured:
`proxy_smpClients = 300` after 300 dead addresses, ~19 KiB each, never freed while the process runs.
1000 entries created in about 1s, so ~19 MiB/s when the address refuses immediately. An address that
accepts nothing and never answers waits out the 45s connect timeout, which slows it down.

### Fix

Scan the map on a timer and remove entries past their expiry. The timestamp is already stored.

---

## Leak 3: the proxy's relay message queue has no reader

> [!TIP]
> Fixed in master by #1839 (`7d0820dd`), which took the approach proposed below. `msgQ` is now
> `Maybe (TBQueue ...)` (`Client/Agent.hs:143`), the proxy agent is built with `msgQSize = Nothing`
> (`Server/Main.hs:607`), and `sendMsg` logs late replies instead of enqueuing them (`Client.hs:722`).
> The analysis below is kept for context.

| | |
| --- | --- |
| Reachable | any client, pre-auth via PRXY |
| Trigger | relay replies land after the 30s RFWD timeout |
| Cost | permanent proxy stall once the queue fills |
| Measured | yes, `msgqfill` phase |
| Status | fixed, #1839 |

### How it works

`newSMPClientAgent` created one `msgQ` and gave that same queue to every relay client. The ntf server
reads its copy (`Notifications/Server.hs`), but the SMP server never read its own: `receiveFromProxyAgent`
reads `agentQ` only.

### The bug

The queue filled from late replies. `processMsg` routes a response to `msgQ` when the request is
still in `sentCommands` but `pending` is already `False` (`Client.hs:713`), so every reply arriving
after the proxy's 30s RFWD timeout left an entry that nothing removed. When full, `processMsgs`
blocked in `writeTBQueue` on the `process` thread, the only reader of `rcvQ`, so the proxy stopped
handling responses entirely.

### Impact

Measured with the `msgqfill` phase: 4 forwards at 40s each way so replies land after the timeout, then
lag cleared and 3 more attempted. Only `msgQSize` differs.

| `msgQSize` | `proxy_msgQ` at end | `sentCommands` at end | recovery forwards |
| --- | --- | --- | --- |
| 2 | 2 (at cap) | 4 and climbing | 0 of 3 |
| 2048 (production) | 4 | 0 | 3 of 3 |

The queue was never emptied, and once full the stall was permanent: the recovery forwards ran with no
latency and got nothing back. One `msgQ` per agent and one `ProxyAgent` per server, so one slow relay
stalled the proxy for every relay it talked to. Someone controlling the destination relay needed only
2048 late replies. This also corrects Leak 1's "slow relay is not a leak" row: those late replies are
what piled up here.

---

## Bug 3: proxy concurrency limit does nothing

| | |
| --- | --- |
| Reachable | any client, pre-auth via PRXY |
| Trigger | concurrent PFWDs on one connection |
| Cost | none directly, uncaps Leak 1's growth rate |
| Measured | yes, `conclimit` phase |
| Status | present |

### How it works

`forkCmd` (`Server.hs:1591`) is meant to cap in-flight forked commands at `serverClientConcurrency`.
`wait` blocks until a slot is free and `signal` releases it.

### The bug

The code is `bracket_ wait signal . forkClient clnt label $ action` (`Server.hs:1592`). `.` binds
tighter than `$`, so it parses as `bracket_ wait signal (forkClient ... action)`. `forkClient`
returns as soon as the thread is spawned, so `signal` runs at spawn time, not at completion. Only
forking is serialized. Measured with `conclimit 8` and `serverClientConcurrency = 1`, all eight PFWDs
ran at once (`first=20.0s last=20.0s spread=0.0s`); enforced, each would hold the slot for the 30s
RFWD timeout. `procThreads` also reads near zero at any load. The counter is per-connection, so even
when fixed the cap is per-client, not global.

### Fix

```haskell
wait >> forkClient clnt label (action `finally` signal)
```

This enables the limit for the first time. Default is 32 and `wait` blocks the client's whole command
loop when hit, so check that value first.

---

## Bug 4: stale endThreads entry when a command finishes fast

| | |
| --- | --- |
| Reachable | client, narrow timing window |
| Trigger | forked child finishes before it is registered |
| Cost | ~320 bytes per stale entry, misleading counter |
| Measured | isolation only, not against a running server |
| Status | present |

### How it works

`forkClient` (`Server.hs:1482`) registers the child in `endThreads` for shutdown tracking. It forks
first (`:1485`), the child deletes its own key on exit (`:1487`), and the parent inserts the weak
thread id afterward (`:1488`).

### The bug

If the child finishes before the parent's insert, the delete finds no key and the later insert is
never undone, leaving a permanent entry. Reproduced over 100k forks: 20% stale at `-N1`, 13% at `-N4`,
~320 bytes each. `deRefWeak` returns `Nothing` for all, so no thread is retained.

What decides the race is whether the child yields the CPU back, not how long it runs:

| Child does | -N1 | -N4 |
| --- | --- | --- |
| nothing | 17.5% | 10.7% |
| spins 1us | 19.2% | 9.7% |
| spins 100us | 17.8% | 9.8% |
| one failing `connect()` | 0% | 0.1% |

A child that spins keeps the CPU; the parent wins only when the child hits a syscall, safe FFI call,
or STM retry. Of the three call sites, `forkCmd` (`PFWD`/`PRXY`/`RSLV`) and `deliverServiceMessages`
all do IO and yield, and the service path runs at most once per connection. Only
`sendPendingEvtsThread.queueEvts` can finish without yielding, and it forks at most twice per client
per 15s (`pendingENDInterval`) and only when the client's `sndQ` was full then emptied.
`clientDisconnected` clears the map, so nothing outlives the session. The real cost is that the
`endThreads` counter mixes stale entries with commands still running.

### Fix

```haskell
atomically $ modifyTVar' endThreads $ IM.insert tId Nothing        -- before forkIO
atomically $ modifyTVar' endThreads $ IM.adjust (const (Just w)) tId
```

`adjust` is a no-op if the action already removed the key.

---

## Bug 5: unauthenticated RSLV resolver fan-out

| | |
| --- | --- |
| Reachable | any client, pre-auth, when `[NAMES]` is enabled |
| Trigger | a block full of RSLV commands |
| Cost | up to 1000 concurrent outbound TLS handshakes per connection |
| Measured | yes, `testRslvFanOut` (64 in flight, asserts <= 8) |
| Status | present |

### How it works

`RSLV` resolves a name over an outbound HTTP/TLS request. It is verified as unauthenticated
(`Server.hs:1393`, `vc SResolver (RSLV _) = VRVerified Nothing`) and each command forks one request
(`Server.hs:1638`). One 16 KB block carries ~255 RSLVs. Off by default, on only with `[NAMES]`.

### The bug

The only bound is `serverResolverConcurrency` (default 1000, `Env/STM.hs:255`), applied through the
per-client `procThreads` counter via the same broken `forkCmd` path as Bug 3, so it is neither global
nor effective. `managerConnCount = 10` (`HttpResolver.hs:88`) sizes the keep-alive pool, not
concurrency, so excess requests open extra connections rather than blocking. `resolveName` has no
cache (`Server/Names.hs:61`). One connection drives up to `serverResolverConcurrency` concurrent
outbound handshakes, sockets and FDs; more connections multiply it with no global bound.

### Fix

Add a global resolver-concurrency limit, a shared semaphore in `NamesEnv` acquired around the
outbound call, separate from the per-client counter, and lower the default. A result cache would also
cut repeat lookups.

---

The findings below are from code review of the PostgreSQL backend (`store_messages: database`), not
bench-measured.

## Bug 6: every SEND is three DB transactions behind a pool of 10

| | |
| --- | --- |
| Reachable | authenticated SEND |
| Trigger | normal message sending |
| Cost | SEND rate capped at ~`poolSize / 3` per transaction latency |
| Evidence | code review |
| Status | present |

### How it works

With `store_messages: database` the queue store runs `useCache = False` (`MsgStore/Postgres.hs:100`),
so each command hits the DB.

### The bug

A SEND does three separate transactions: load the queue (`QueueStore/Postgres.hs:230`),
`delete_expired_msgs` (`MsgStore/Postgres.hs:289`), then `write_message` (`MsgStore/Postgres.hs:193`).
`expireMessagesOnSend` defaults to `True` (`Main.hs:563`, `Server.hs:2118`), so the middle one runs on
every SEND to a non-empty queue. All draw from one pool of `poolSize` (default 10, `Main/Init.hs:44`).
A second pool, `dbPriorityPool`, is opened (`Agent/Store/Postgres.hs:59`) but the SMP server never
uses it. Max SEND rate is about `poolSize / (3 x per-transaction latency)` regardless of client count;
past that all clients block on the pool, and half the opened backends sit idle.

### Fix

Fewer transactions per SEND; make `expireMessagesOnSend` cheaper or default off; drop or use the
priority pool.

---

## Bug 7: unauthenticated batched crypto and per-transmission DB lookup

| | |
| --- | --- |
| Reachable | any handshake-completing peer, pre-auth |
| Trigger | one 16 KB block of SENDs to unknown queues |
| Cost | ~130-250 asymmetric verifications and DB SELECTs per block |
| Evidence | code review |
| Status | present |

### How it works

Recipient and Notifier commands are batch parties (`Protocol.hs:420`), so their queue lookups are
batched. SEND is not, so it takes the per-transmission path
`mapM (\t -> verifyTransmission ...)` (`Server.hs:1281`).

### The bug

Each transmission runs one crypto op and, with `useCache = False`, one `getQueueRec` SELECT
(`Server.hs:1361`). For an unknown queue, `dummyVerifyCmd` (`Server.hs:1459`) still runs a real
Ed25519/Ed448 verify or an X25519 DH. A 16 KB block holds up to 254 transmissions (`Protocol.hs:2292`,
one-byte count), so one write by any peer that completed the handshake costs ~130-250 asymmetric
verifications and ~130-250 SELECTs. The attacker chooses the auth type and that the queue is absent.

### Fix

Batch the sender lookups as Recipient and Notifier already are; cap unknown-queue verifications per
block.

---

## Bug 8: unauthenticated service handshake grows the services table

| | |
| --- | --- |
| Reachable | any client, pre-auth |
| Trigger | a fresh self-signed service cert per handshake |
| Cost | one persistent `services` row and one X509 verify per connection |
| Evidence | code review |
| Status | present |

### How it works

The SMP handshake accepts a self-signed service chain (`CCSelf`, `Transport.hs:759`) and verifies the
supplied cert (`Transport.hs:763`). `getClientService` (`Server.hs:864`) then calls `getCreateService`.

### The bug

`getCreateService` inserts a `services` row on any new fingerprint (`QueueStore/Postgres.hs:478`), and
a fresh self-signed cert is a new fingerprint every time. The only guard is a role check on an
existing fingerprint, so each connection can create one unbounded, persistent row plus one X509 verify,
all before authentication.

### Fix

Require the service to be pre-registered, or authenticate and rate-limit service creation.

---

## Bug 9: Prometheus scrape scans all queues and folds all subscriptions

| | |
| --- | --- |
| Reachable | internal, fires every `prometheus_interval` |
| Trigger | Prometheus enabled |
| Cost | scales with queue count and live subscriptions, every scrape |
| Evidence | code review |
| Status | present |

### How it works

On each scrape the server refreshes its metrics from live state rather than incremental counters.

### The bug

`getEntityCounts` runs six `COUNT(1)` scans over `msg_queues` and `services`
(`QueueStore/Postgres.hs:154`, called at `Server.hs:813`), and `getDeliveredMetrics` folds over all
clients times all their subscriptions in memory (`Server.hs:837`, called at `Server.hs:825`). Cost
scales with the largest dimensions and recurs every interval while Prometheus is on.

### Fix

Maintain the counts incrementally; drop the per-scrape full fold.

---

## Bug 10: subscription changes serialize through one thread and one map

| | |
| --- | --- |
| Reachable | authenticated SUB |
| Trigger | subscription churn, batched SUB of many queues |
| Cost | throughput bounded by one thread and one contended TVar |
| Evidence | code review |
| Status | present |

### How it works

Subscription state lives in `queueSubscribers`, one `Map` in one TVar (`Env/STM.hs:377`). Changes are
enqueued to `subQ` and applied by a single `serverThread` (`Server.hs:284`).

### The bug

All churn passes through that one thread and one TVar, and a batched SUB of N queues is N separate
writes to `subQ` (`Server.hs:1845`), so subscription throughput does not scale with cores or clients.

### Fix

Shard the subscriber map, or batch `subQ` events per client.

---

## Clean: TLS/TCP stack

200 connections opened at once, closed, then measured again.

| Test | Peak per conn | After 25s |
| --- | --- | --- |
| TCP connect, never start TLS | 48.2 KiB | 0.31 KiB |
| TLS done, no SMP handshake | 203.1 KiB | 0.71 KiB |
| handshake done, one byte, then quiet | 264.6 KiB | 0.87 KiB |

All recovered. Also clean: 400 connect/disconnect rounds, and steady forwarding at 50ms each way.

Measure well after closing. At +5s the middle two still read ~120 KiB per connection, which looks like
a 24 MiB leak but is just connections still closing. A number that keeps falling is being freed; one
that stops above where it started is leaked.

The peaks still matter. 200 abandoned half-open connections hold ~40 MiB for ~25s with no
authentication. A client that finishes the handshake then sends one byte holds ~265 KiB for as long as
it stays connected, because there is no read timeout: `transportTimeout` is hardcoded `Nothing`
(`Transport/Server.hs:104`).

## Clean: connectivity and sockets under latency

Latency set with `BENCHLAG_MS` on `proxyfwd`, one way. Sockets counted from `/proc/<pid>/fd`.

| Lag each way | Delivered | Sockets | Relay connects | Reconnects | Timeouts |
| --- | --- | --- | --- | --- | --- |
| 0ms | 12/12 | 8 | 1 | 0 | 0 |
| 500ms | 10/10 | 8 | 1 | 0 | 0 |
| 5s | 6/6 | 8 | 1 | 0 | 0 |
| 16s | 4/4 | 8 | 1 | 0 | 0 |
| 40s | 0/2 | 8 | 1 | 0 | 1 |

Nothing builds up. The socket count is the same whether forwards succeed or time out, the session is
opened once and reused, and there are no reconnects at any latency. This is why Leak 1 has no upper
bound: the session holding the stuck entries never closes. Forwards work to 16s each way and fail at
40s because of the 30s RFWD timeout; the exact cutoff is not measured, since the test transport adds
its delay per read/write rather than per message.
