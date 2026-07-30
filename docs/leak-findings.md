# SMP server leak findings

From `bench/MemBench.hs` extended with a proxy plus relay topology and a transport that adds
latency and drops replies.

Two leaks on the proxy path, both client reachable. Two related bugs. TLS/TCP stack clean.

Measured on both the journal store and the PostgreSQL queue and message store, which is the
production configuration. Results are the same on both.

---

## Leak 1: forwarded commands never removed on timeout

### Issue

Entries go into `sentCommands` in `mkTransmission_` (`Client.hs:1418`). The only removal is in
`processMsg` (`Client.hs:706`), which runs when a reply arrives. `getResponse` (`Client.hs:1383`)
handles the timeout but does not receive the map, so it cannot delete.

Each entry holds the forwarded command, 16226 bytes.

The session survives too. `monitor` (`Client.hs:668`) only tears the client down when
`timeoutErrorCount >= smpPingCount` and nothing has arrived for `recoverWindow` (900s), and
`receive` (`Client.hs:663`) resets both on every inbound transmission. A relay that answers some
requests and drops others therefore keeps the session healthy forever while the dropped ones
accumulate.

`proxytmo 448`: `proxy_sentCommands` goes 64, 128, 192, 256, 320, 384, 448. Monotonic.
About 20 KiB per entry.

### Impact

20 KiB per unanswered forward. How long it is held depends entirely on how the relay
misbehaves, and the three cases differ a lot.

**Slow relay that still replies: transient, not a leak.** A late reply removes the entry, since
`processMsg` deletes on any `corrId` match whether or not the request already timed out.
Measured at 16s each way, where forwards exceed the 30s timeout: `proxy_sentCommands` oscillates
1, 0, 1, 0 and ends at 0. Growth is bounded by in-flight commands. Latency on its own does not
leak.

**Relay that goes fully silent: bounded at about 20 minutes.** `monitor` (`Client.hs:668`) exits
when `timeoutErrorCount >= smpPingCount` and nothing has arrived for `recoverWindow` (900s),
checked on a 600s loop. It runs inside `raceAny_ ... \`finally\` disconnected`
(`Client.hs:649`), so exiting tears the client down and the map goes with it. Measured:
`proxy_sentCommands` sat at 128 for 20 minutes then went to 0, with one disconnect logged.

**Sustained traffic with some replies dropped: unbounded.** `receive` (`Client.hs:665`) resets
both `lastReceived` and `timeoutErrorCount` on every inbound transmission, so as long as traffic
continues and some of it is answered, the drop condition is never met. Measured with 1 in 3
relay writes dropped and forwarding running continuously: `proxy_sentCommands` climbed 64, 128,
192 ... 1280 over 20 minutes, linear at 64 per minute, with zero disconnects. It goes straight
through the 20 minute point where both idle cases collapsed to 0.

At that modest rate, 64 stuck commands per minute is about 1.3 MiB per minute, or 77 MiB per
hour, on a single proxy to relay session.

Note the traffic has to be ongoing. An attacker who floods and then stops gets their memory
reclaimed after 20 minutes. Holding it requires staying connected and keeping the requests
coming, which is cheap but not free.

`PRXY` is unauthenticated unless `newQueueBasicAuth` is set (`Server.hs:1534`), and it names an
arbitrary destination, so a client can point the proxy at exactly such a relay. No rate cap, see
Bug 3.

The ntf server uses the same client code, so it has the same exposure. Reachable through
unanswered `NSUB`: `subscribeSMPQueuesNtfs` (`Client.hs:912`) batches, and `sendBatch` calls
`getResponse` once per request, so an unanswered batch leaks one entry per queue. Batch size is
1360 (`Client/Agent.hs:131`).

Measured with `subtmo 200`, which drives the same batched subscribe path on a bench owned client
so the count can be read directly: 200 queues, 200 timed out, `sentCommands` went from 0 to 200.
One entry per queue, at about 1.76 KiB each. At the ntf server's batch size that is roughly
2.3 MiB per unanswered batch.

`subscribeSMPQueues` (measured) and `subscribeSMPQueuesNtfs` (the ntf server's call) are the
same function bar the command constructor: both are `enablePings` followed by
`sendProtocolCommands c NRMBackground cs`. So the measurement transfers directly.

Cost per entry is far lower than the proxy case, a subscribe payload rather than a 16226 byte
`RFWD`, but the retention rule is identical.

Pings are not the mitigation they look like. Subscribe paths call `enablePings` (`Client.hs:854,
861, 907, 914, 934`) and the proxy's send path does not, but that only changes liveness detection
on an otherwise idle connection. It does not bound the leak: in the unbounded case there is
sustained traffic and some replies do arrive, and every arrival resets `lastReceived` and
`timeoutErrorCount` whether or not pings are enabled.

### Fix

```haskell
Nothing -> do
  TM.delete corrId sentCommands                              -- new
  modifyTVar' timeoutErrorCount (+ 1) $> Left PCEResponseTimeout
```

Pass `sentCommands` and the request's `corrId` into `getResponse`. Double delete is harmless.

Two more entry points leak with no timeout involved. `mkTransmission_` inserts the request
before it is sent (`Client.hs:1361`), and `sendRecv` then returns early at `Client.hs:1366`
(transport error) and `Client.hs:1368` (block over `blockSize - 2`) without sending or deleting.
Both need the same delete.

---

## Leak 2: failed relay connects never cleared

### Issue

A failed connect is cached in `smpClients` as `Left (error, expiry)` (`Client/Agent.hs:275`),
removed only on a later lookup of the same server (`Client/Agent.hs:250`, `:411`). Nothing sweeps
on a timer. Verified by listing every `smpClients` site: the only other removals are
`clientDisconnected` (`:311`, connected clients only) and shutdown (`:427`).

Conditional on `persistErrorInterval > 0`. At 0 the entry is removed immediately
(`Client/Agent.hs:269-272`) and there is no leak, but production sets 30
(`Server/Main.hs:607`).

The address comes from the client via `PRXY`. Host, port and key hash are arbitrary, so distinct
keys are effectively unlimited.

`proxychurn 300`: `proxy_smpClients = 300`, none removed. A 1000 run settles at ~19 KiB per
entry, created in about 1 second.

### Impact

19 KiB per address, never freed while the process runs.

About 19 MiB/s when the address refuses immediately. An address that blackholes instead waits
out the 45 second connect timeout, which throttles it heavily.

Same unauthenticated `PRXY` as Leak 1.

### Fix

Sweep the map on a timer, dropping entries past their expiry. The timestamp is already stored.

---

## Bug 3: proxy concurrency limit is inert

### Issue

`Server.hs:1590`:

```haskell
bracket_ wait signal . forkClient clnt label $ action
```

`.` binds tighter than `$`, so `signal` runs when the thread starts, not when it finishes. Only
forking is limited.

Measured with `conclimit 8` and `serverClientConcurrency = 1`: eight concurrent PFWDs on one
connection, relay silent.

```
conclimit: n=8 cap=1 completions first=20.0s last=20.0s spread=0.0s
```

All eight ran concurrently. If the cap were enforced each would hold the slot for the 30s RFWD
timeout and they would need ~240s, and because `wait` blocks the client's command loop the next
command could not even be read until the previous finished.

### Impact

No memory cost. Removes the cap on how fast Leak 1 grows, and `procThreads` reads near zero at
any load.

### Fix

```haskell
wait >> forkClient clnt label (action `finally` signal)
```

This enables the limit for the first time. Default is 32, and `wait` blocks the client's whole
command loop when hit, so check the value first.

---

## Bug 4: stale endThreads entry when a command finishes fast

### Issue

`forkClient` (`Server.hs:1480`) registers the thread after `forkIO`. If the action finishes
first, its delete misses and the insert is never undone.

Reproduced in isolation with a verbatim copy of the registration order, including the
`labelMyThread` the child runs before the action. 100k forks: 20% stale at `-N1`, 13% at `-N4`.
About 320 bytes per stale entry. `deRefWeak` returns `Nothing` for all of them, so no thread is
retained.

### What decides the race

Not how long the child takes. How long was the obvious guess and it is wrong. Measured over
20k forks, varying only the work the child does before its delete:

| child does | -N1 | -N4 |
|---|---|---|
| nothing | 17.5% | 10.7% |
| spins 1us | 19.2% | 9.7% |
| spins 10us | 17.3% | 9.7% |
| spins 100us | 17.8% | 9.8% |
| one failing `connect()` | **0%** | **0.1%** |

A spinning child does not lose the race, it *starves* the parent. What closes the window is the
child giving up the capability: a syscall, a safe FFI call, or an STM retry. So the rule is
"does the child yield before its delete", not "is the child fast".

### Which paths yield

There are exactly three `forkClient` call sites.

- **`forkCmd`** (`Server.hs:1593`), used by `PFWD`/`PRXY` (`:1540`, `:1577`) and `RSLV`
  (`:1639`, `:2269`). All do network IO, so all yield. `RSLV` was worth checking separately
  because it is client driven at command rate, but `resolveName` has no cache
  (`Server/Names.hs:62`): every call goes to `resolveHttp`. Safe.
- **`deliverServiceMessages`** (`Server.hs:1977`). Guarded by `unless hasSub`, and
  `clientServiceSubscribed` is a one-way latch set at `Server.hs:2031` that is never reset
  within a session. Fires at most once per connection. Safe by rate.
- **`sendPendingEvtsThread.queueEvts`** (`Server.hs:463`). This is the one that does not yield.
  The child is `atomically (writeTBQueue sndQ ...)` plus three `IORef` bumps. If the queue is
  still full it retries and yields, but if space appeared it commits straight through, which is
  the "nothing" row above.

The earlier oversized-`PFWD` idea does not work: the client's own transmission limit caps
`encBlock` first. Largest block the client will send is about 16270 bytes, and at that size the
proxy still forwards successfully (the relay answers `PROXY (PROTOCOL CRYPTO)`), so the no-IO
return at `Client.hs:1368` is never taken.

### Impact

Small and self-limiting, and I have not driven it live.

The one non-yielding path is rate capped by construction: `sendPending` runs once per
`pendingENDInterval` (15s in production, `Server/Main.hs:581`) for each of two subscriber sets,
and forks at most once per client per run. So at most 2 forks per client per 15s, and only for a
client whose `sndQ` was full at the check and had drained by the time the child ran. At the
measured 18% that is well under one stale entry per client per 15s, about 320 bytes each.

Everything in `endThreads` is dropped by `clientDisconnected` (`Server.hs:1237`), so nothing
survives the session.

A client can influence both preconditions by stalling and resuming its socket reads, so I am no
longer claiming this is unreachable. I am also not claiming it is reachable: that needs winning
a sub-millisecond window at two attempts per 15s, and I did not build the repro, because a
session-scoped few hundred bytes does not justify it. The honest status is a real ordering
defect with one candidate trigger and a hard ceiling.

The practical cost is the misleading `endThreads` counter, which conflates stale entries with
genuinely running forked commands.

### Fix

```haskell
atomically $ modifyTVar' endThreads $ IM.insert tId Nothing        -- before forkIO
atomically $ modifyTVar' endThreads $ IM.adjust (const (Just w)) tId
```

`adjust` is a no-op if the action already removed the key.

---

## Clean

200 connections opened at once, closed, then measured again:

| test                                  | peak per conn | after 25s |
| ------------------------------------- | ------------- | --------- |
| TCP connect, never start TLS          | 48.2 KiB      | 0.31 KiB  |
| TLS done, no SMP handshake            | 203.1 KiB     | 0.71 KiB  |
| Handshake done, one byte, then quiet  | 264.6 KiB     | 0.87 KiB  |

All recovered. Also clean: 400 connect/disconnect rounds, and steady forwarding at 50ms each way.

At +5s the middle two still read ~120 KiB per connection, which looks like a 24 MiB leak but is
teardown still in progress. Falling means reclaimed, flat above baseline means leaked.

Peaks still matter. 200 abandoned half open connections hold ~40 MiB for ~25s, unauthenticated.
A client that finishes the handshake then sends one byte holds ~265 KiB for as long as it stays
connected: no read timeout, `transportTimeout` is hardcoded `Nothing` (`Transport/Server.hs:104`).

## Connectivity and sockets under latency

Latency swept with `BENCHLAG_MS` on `proxyfwd` (one way, so a request/response pair costs twice
this). Sockets counted from `/proc/<pid>/fd` during the run.

| lag each way | delivered | sockets | relay connects | reconnects | timeouts |
| ------------ | --------- | ------- | -------------- | ---------- | -------- |
| 0ms          | 12/12     | 8       | 1              | 0          | 0        |
| 500ms        | 10/10     | 8       | 1              | 0          | 0        |
| 5s           | 6/6       | 8       | 1              | 0          | 0        |
| 16s          | 4/4       | 8       | 1              | 0          | 0        |
| 40s          | 0/2       | 8       | 1              | 0          | 1        |

Nothing accumulates. The socket count is the same whether forwards succeed or time out, the
proxy to relay session is opened once and reused, and there are no reconnects at any latency.
`proxy_smpClients` and `proxy_smpSessions` stay at 1 throughout.

This is the bad news for Leak 1. The session holding the stuck `sentCommands` entries never
drops, so nothing ever frees them. A connection that broke under latency would at least bound
the damage.

Forwards work up to 16s each way and fail at 40s. The governing limit is the 30s RFWD timeout.
The exact cutoff is not pinned down: the test transport adds delay per read/write cycle rather
than per message, so configured lag does not map exactly onto observed round trip.

## Checked and not a problem: socketsLeaked accounting

Recorded because an earlier version of this report listed it as a bug on the strength of code
reading alone, and measuring it did not bear that out.

`closeConn` (`Transport/Server.hs:179`) removes the connection from `active`, then calls
`gracefulClose conn 5000`, then increments `closed`, and
`socketsLeaked = accepted - closed - active`. That ordering does leave a window where a closing
connection is counted in neither bucket.

In practice the window never opened. Read over the control port during 600 sequential
connect/disconnect cycles, and again across 200 simultaneous teardowns:

```
during churn:        accepted: 587  closed: 586  active: 1  leaked: 0
after settling:      accepted: 600  closed: 600  active: 0  leaked: 0
before mass release: accepted: 200  closed: 0    active: 200  leaked: 0
after mass release:  accepted: 200  closed: 200  active: 0    leaked: 0
```

The 5000 in `gracefulClose conn 5000` is a timeout, not a delay: it returns as soon as the peer's
close is processed, which for a clean disconnect is immediate. A peer that vanishes without
closing could in principle widen the window, but that was not produced here, so it is not
claimed.

## Note on running the suite

`should have similar time for auth error, whether queue exists or not` compares wall clock
timings with a 30% tolerance (45% on Postgres), and it fails intermittently when the machine is
busy. Observed twice in four runs while benches were running concurrently, then 4 of 4 and 5 of 5
clean on an idle machine with and without the changes here. It is load sensitivity in the test,
not a regression. Run the suite on an otherwise idle machine.

## Already fixed: the empty session variable leak

Worth recording because an earlier version of this report listed it as "not reproduced", which
was the wrong conclusion. It is not reproducible because it is fixed.

`withGetSessVar'` (`Session.hs:65`) wraps the session var in `bracketOnError` with
`dropEmptySessVar`, so an interrupted connect drops the empty var instead of leaving it to
poison every later request. Fixed in `c9ebf72e` ("smp: fix proxy reconnection to relay after
restart").

`SMPProxyTests` already covers both the proxy and the agent variants, and both pass:

```
recovers when unresponsive relay restarts (control, no disconnect) [OK]
reconnects to relay after sender disconnects mid-connection       [OK]
reconnects after a connect is cancelled mid-flight                [OK]
```

A load phase cannot reproduce a fixed race, so the bench does not try.
