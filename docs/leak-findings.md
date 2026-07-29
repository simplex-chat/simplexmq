# SMP server leak findings

From `bench/MemBench.hs` extended with a proxy plus relay topology and a transport that adds
latency and drops replies.

Two leaks on the proxy path, both client reachable. Two related bugs. TLS/TCP stack clean.

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

The ntf server uses the same client code, so it is exposed too, but less. Analysis only, not
measured here, since it needs Postgres:

- Reachable through unanswered `NSUB`. `subscribeSMPQueuesNtfs` (`Client.hs:912`) batches, and
  `sendBatch` calls `getResponse` once per request, so an unanswered batch leaks one entry per
  queue. Batch size is 1360 (`Client/Agent.hs:131`).
- Much cheaper per entry: an `NSUB` payload rather than a 16226 byte `RFWD`.
- Partly self limiting. Every subscribe path calls `enablePings` (`Client.hs:854, 861, 907, 914,
  934`), so a fully silent server is eventually dropped and the map goes with it. The proxy
  never subscribes, so it never pings, which is why only the proxy is unbounded.
- Still leaks against a server that answers pings but not subscribes, since any reply resets the
  counters.

### Fix

```haskell
Nothing -> do
  TM.delete corrId sentCommands                              -- new
  modifyTVar' timeoutErrorCount (+ 1) $> Left PCEResponseTimeout
```

Pass `sentCommands` and the request's `corrId` into `getResponse`. Double delete is harmless.

Same leak with no timeout at `Client.hs:1366` and `1368`, where the request is inserted before
an early error return.

---

## Leak 2: failed relay connects never cleared

### Issue

A failed connect is cached in `smpClients` as `Left (error, expiry)`, removed only on a later
lookup of the same server (`Client/Agent.hs:250`, `:411`). Nothing sweeps on a timer.

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

100k forks: 20% stale at `-N1`, 12% at `-N4`, 0% when the action blocks 1ms. Real callers
(`PFWD`, `PRXY`, `RSLV`) wait on the network. Reachable at speed via an oversized `PFWD` that
fails the block size check without IO.

### Impact

About 320 bytes per entry, freed on disconnect. 10k fast failing commands on one connection is
roughly 640 KB. Minor. The real cost is that `endThreads` no longer distinguishes stuck commands
from counter error.

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
`gracefulClose` waiting up to 5s per connection. Falling means reclaimed, flat above baseline
means leaked.

Peaks still matter. 200 abandoned half open connections hold ~40 MiB for ~25s, unauthenticated.
A client that finishes the handshake then sends one byte holds ~265 KiB for as long as it stays
connected: no read timeout, `transportTimeout` is hardcoded `Nothing` (`Transport/Server.hs:104`).

## Bug 5: socketsLeaked over-reports during teardown

### Issue

`closeConn` (`Transport/Server.hs:179`) removes the connection from `active`, then calls
`gracefulClose conn 5000`, then increments `closed`:

```haskell
atomically $ writeTVar closed True >> modifyTVar' clients (IM.delete cId)
gracefulClose conn 5000 `catchAll_` pure ()
atomically $ modifyTVar' gracefullyClosed (+ 1)
```

`socketsLeaked = accepted - closed - active` (`Transport/Server.hs:225`). For up to 5 seconds a
closing connection is in neither `closed` nor `active`, so it counts as leaked.

### Impact

No memory cost. Under connection churn `socketsLeaked` shows a steady nonzero value that is not
a leak, which makes the metric unusable for the thing it is named after. This is the same 5
second teardown window that made the TLS tests look like they leaked 24 MiB.

### Fix

Count the connection as closed before starting `gracefulClose`, or drop it from `active` only
after `gracefulClose` returns. Either ordering keeps the invariant.

---

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

## Not reproduced

Empty session variable leak. After 100 rounds `proxysess` ends with `proxy_smpClients=0` and
`proxy_smpSessions=0`, checked before and after the 45 second connect timeout. `bracketOnError`
in `withGetSessVar` drops the empty entry.

The ~108 KiB per round it shows is harness overhead, not a server finding.
