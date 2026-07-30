# SMP server leak findings

Found with `bench/MemBench.hs`, extended with a proxy plus relay topology and a transport that
adds latency and drops replies. Measured on both the journal store and PostgreSQL, same results.

Three leaks on the proxy path, all client reachable. Two related bugs. TLS/TCP stack is clean.

All three leaks are reached the same way: `PRXY` is unauthenticated unless `newQueueBasicAuth` is
set (`Server.hs:1534`) and names an arbitrary destination, so a client can point the proxy at a
relay it controls.

---

## Leak 1: forwarded commands are never removed on timeout

### Issue

Entries go into `sentCommands` in `mkTransmission_` (`Client.hs:1418`). The only removal is in
`processMsg` (`Client.hs:706`), which runs when a reply arrives. `getResponse` (`Client.hs:1383`)
handles the timeout but never gets the map, so it cannot delete.

Each entry holds the forwarded command: 16226 bytes for `RFWD`.

The session survives too. `monitor` (`Client.hs:668`) drops the client only when
`timeoutErrorCount >= smpPingCount` and nothing has arrived for 900s, and `receive`
(`Client.hs:663`) resets both on every inbound transmission.

### Impact

About 20 KiB per unanswered forward. How long it is held depends on how the relay misbehaves.

| relay behaviour | result |
| --- | --- |
| slow but still replies | not a leak here, the late reply deletes the entry (but see Leak 3) |
| goes fully silent | bounded, `monitor` tears the client down at ~20 min |
| replies to some, drops others | **unbounded** |

The third case is the problem. Any arriving reply resets `lastReceived` and `timeoutErrorCount`,
so the drop condition is never met. Measured with 1 in 3 relay writes dropped and forwarding
running: `proxy_sentCommands` climbed 64 to 1280 over 20 minutes, linear at 64/min, zero
disconnects. That is ~1.3 MiB/min, ~77 MiB/hour, on one session.

Traffic has to be ongoing. Flood and stop and it is reclaimed after 20 minutes.

The ntf server uses the same client code and has the same exposure through unanswered `NSUB`.
Measured with `subtmo 200`: 200 queues, 200 timed out, `sentCommands` 0 to 200, ~1.76 KiB each.
At the ntf batch size of 1360 that is ~2.3 MiB per unanswered batch.

Pings do not help. Subscribe paths call `enablePings` and the proxy send path does not, but in
the unbounded case replies are arriving anyway, which resets the counters either way.

### Fix

Do not just delete on timeout. Late replies are load bearing: `processMsg` forwards them as
`STResponse` (`Client.hs:713`), and `Agent.hs:3093` acts on them. A late `OK`/`SOK` to a `SUB`
calls `processSubOk`, which is what brings a connection back UP, and a late `MSG` is processed as
a real message. Deleting on timeout turns both into `STUnexpectedError` (`Client.hs:702`), so the
agent would report an error instead of recovering, and drop the message.

Bound the map by age instead: stamp `Request` on insert, sweep entries with `pending == False`
older than the window in which a late reply can still matter. Picking that window needs the
agent's recovery behaviour measured, which is not done here.

Two entry points can be fixed by deleting, because no reply is ever coming. `mkTransmission_`
inserts before sending (`Client.hs:1361`) and `sendRecv` returns early at `Client.hs:1366`
(transport error) and `Client.hs:1368` (oversized block) without sending or deleting.

---

## Leak 2: failed relay connects are never cleared

### Issue

A failed connect is cached in `smpClients` as `Left (error, expiry)` (`Client/Agent.hs:275`) and
removed only on a later lookup of the same server (`:250`, `:411`). Nothing sweeps on a timer.
The other removals are `clientDisconnected` (`:311`, connected clients only) and shutdown
(`:427`).

Conditional on `persistErrorInterval > 0`. At 0 the entry goes immediately, but production sets
30 (`Server/Main.hs:607`).

### Impact

Host, port and key hash come from the client, so distinct addresses are unlimited. Measured:
`proxy_smpClients = 300` after 300 dead addresses, ~19 KiB each, never freed while the process
runs. 1000 entries created in about 1s.

That is ~19 MiB/s when the address refuses immediately. An address that blackholes waits out the
45s connect timeout, which throttles it heavily.

### Fix

Sweep the map on a timer, dropping entries past their expiry. The timestamp is already stored.

---

## Leak 3: the proxy's relay message queue has no reader

### Issue

`newSMPClientAgent` creates one `msgQ` (`Client/Agent.hs:194`) and `connectClient` gives that same
queue to every relay client (`:296`). The ntf server drains its copy
(`Notifications/Server.hs:537`). The SMP server never drains its own: `receiveFromProxyAgent`
reads `agentQ` only (`Server.hs:475`). There are three `readTBQueue` sites on a `msgQ` in `src/`
and none is the proxy's.

It fills from late replies. `processMsg` routes a response to `msgQ` when the request is still in
`sentCommands` but `pending` is already `False` (`Client.hs:713`), so every reply arriving after
the proxy's 30s RFWD timeout leaves an entry that nothing takes out.

When it is full, `processMsgs` blocks in `writeTBQueue` (`Client.hs:694`). That is the `process`
thread, the only reader of `rcvQ`, so the proxy stops handling responses entirely.

### Impact

Measured with the `msgqfill` phase: 4 forwards at 40s each way so replies land after the timeout,
then lag cleared and 3 more attempted. Only `msgQSize` differs.

| `msgQSize` | `proxy_msgQ` at end | `sentCommands` at end | recovery forwards |
| --- | --- | --- | --- |
| 2 | 2 (at cap) | 4 and climbing | **0 of 3** |
| 2048 (production) | 4 | 0 | 3 of 3 |

Two things. The queue never drains: at production size it still holds the 4 late replies at the
end of the run. And when it fills the stall is permanent, not slow: the recovery forwards ran
with no latency at all and got nothing back.

One `msgQ` per agent and one `ProxyAgent` per server, so one slow relay stalls the proxy for every
relay it talks to. That part is from the code, not measured: the bench has one relay.

2048 late replies is a cheap budget for an attacker who controls the destination relay.

This also corrects Leak 1's "slow relay is not a leak" row. That is right about `sentCommands` and
wrong about the session: the late replies that clear `sentCommands` are the ones that pile up
here.

### Fix

Make `msgQ` optional in `SMPClientAgent` and pass `Nothing` for the proxy. `getProtocolClient`
already takes a `Maybe` and `sendMsg` logs instead when it is `Nothing`. A discarding reader would
also work but still allocates and copies every batch.

---

## Bug 3: proxy concurrency limit is inert

### Issue

`Server.hs:1590`:

```haskell
bracket_ wait signal . forkClient clnt label $ action
```

`.` binds tighter than `$`, so `signal` runs when the thread starts, not when it finishes. Only
forking is limited.

Measured with `conclimit 8` and `serverClientConcurrency = 1`, eight concurrent PFWDs on one
connection, relay silent:

```
conclimit: n=8 cap=1 completions first=20.0s last=20.0s spread=0.0s
```

All eight ran at once. Enforced, each would hold the slot for the 30s RFWD timeout, needing ~240s.

### Impact

No memory cost of its own. Removes the cap on how fast Leak 1 grows, and `procThreads` reads near
zero at any load.

### Fix

```haskell
wait >> forkClient clnt label (action `finally` signal)
```

This turns the limit on for the first time. Default is 32 and `wait` blocks the client's whole
command loop when hit, so check that value first.

---

## Bug 4: stale endThreads entry when a command finishes fast

### Issue

`forkClient` (`Server.hs:1480`) registers the thread after `forkIO`. If the action finishes first,
its delete misses and the insert is never undone.

Reproduced in isolation, 100k forks: 20% stale at `-N1`, 13% at `-N4`, ~320 bytes each.
`deRefWeak` returns `Nothing` for all of them, so no thread is retained.

What decides it is not how long the child takes. Measured over 20k forks, varying only the child's
work before its delete:

| child does | -N1 | -N4 |
| --- | --- | --- |
| nothing | 17.5% | 10.7% |
| spins 1us | 19.2% | 9.7% |
| spins 100us | 17.8% | 9.8% |
| one failing `connect()` | **0%** | **0.1%** |

A spinning child does not lose the race, it starves the parent. The window closes when the child
gives up the capability: syscall, safe FFI call, or STM retry.

Against that rule, of the three call sites:

- `forkCmd` (`Server.hs:1593`) for `PFWD`/`PRXY`/`RSLV`: all do network IO, all yield. `RSLV` was
  checked separately since it is client driven at command rate, but `resolveName` has no cache
  (`Server/Names.hs:62`).
- `deliverServiceMessages` (`Server.hs:1977`): `clientServiceSubscribed` is a one-way latch
  (`Server.hs:2031`), so at most once per connection.
- `sendPendingEvtsThread.queueEvts` (`Server.hs:463`): the only one that can skip yielding. The
  child is `writeTBQueue sndQ` plus three `IORef` bumps, so if space appeared it commits straight
  through.

### Impact

Small and bounded, and not driven live.

The one non-yielding path forks at most twice per client per `pendingENDInterval` (15s,
`Server/Main.hs:581`), and only for a client whose `sndQ` was full at the check and drained by the
time the child ran. `clientDisconnected` (`Server.hs:1237`) drops the whole map, so nothing
survives the session.

A client can influence both preconditions by stalling and resuming socket reads, so this is not
unreachable, but winning a sub-millisecond window at two attempts per 15s was not demonstrated.

Practical cost is the misleading `endThreads` counter, which mixes stale entries with genuinely
running forked commands.

### Fix

```haskell
atomically $ modifyTVar' endThreads $ IM.insert tId Nothing        -- before forkIO
atomically $ modifyTVar' endThreads $ IM.adjust (const (Just w)) tId
```

`adjust` is a no-op if the action already removed the key.

---

## Clean: TLS/TCP stack

200 connections opened at once, closed, then measured again:

| test | peak per conn | after 25s |
| --- | --- | --- |
| TCP connect, never start TLS | 48.2 KiB | 0.31 KiB |
| TLS done, no SMP handshake | 203.1 KiB | 0.71 KiB |
| handshake done, one byte, then quiet | 264.6 KiB | 0.87 KiB |

All recovered. Also clean: 400 connect/disconnect rounds, and steady forwarding at 50ms each way.

Sample late. At +5s the middle two still read ~120 KiB per connection, which looks like a 24 MiB
leak but is teardown in progress. Falling means reclaimed, flat above baseline means leaked.

Peaks still matter: 200 abandoned half open connections hold ~40 MiB for ~25s, unauthenticated. A
client that finishes the handshake then sends one byte holds ~265 KiB for as long as it stays
connected, since `transportTimeout` is hardcoded `Nothing` (`Transport/Server.hs:104`).

## Clean: connectivity and sockets under latency

`BENCHLAG_MS` swept on `proxyfwd`, one way. Sockets counted from `/proc/<pid>/fd`.

| lag each way | delivered | sockets | relay connects | reconnects | timeouts |
| --- | --- | --- | --- | --- | --- |
| 0ms | 12/12 | 8 | 1 | 0 | 0 |
| 500ms | 10/10 | 8 | 1 | 0 | 0 |
| 5s | 6/6 | 8 | 1 | 0 | 0 |
| 16s | 4/4 | 8 | 1 | 0 | 0 |
| 40s | 0/2 | 8 | 1 | 0 | 1 |

Nothing accumulates. Same socket count whether forwards succeed or time out, session opened once
and reused, no reconnects at any latency.

That robustness is what makes Leak 1 unbounded: the session holding the stuck entries never drops.

Forwards work to 16s each way and fail at 40s, governed by the 30s RFWD timeout. The exact cutoff
is not pinned down, since the test transport delays per read/write cycle rather than per message.

## Checked, not a problem: socketsLeaked accounting

`closeConn` (`Transport/Server.hs:179`) removes from `active`, calls `gracefulClose conn 5000`,
then increments `closed`, and `socketsLeaked = accepted - closed - active`. That ordering leaves a
window where a closing connection is in neither bucket.

The window never opened in practice. Over 600 sequential cycles and 200 simultaneous teardowns,
read from the control port, `leaked` was 0 at every sample. The 5000 is a timeout, not a delay.

Listed because an earlier version of this report called it a bug on code reading alone.

## Already fixed: empty session variable

`withGetSessVar'` (`Session.hs:65`) wraps the session var in `bracketOnError` with
`dropEmptySessVar`, so an interrupted connect drops the empty var. Fixed in `c9ebf72e`.
`SMPProxyTests` covers the proxy and agent variants and both pass. Not reproducible because it is
fixed, not because it never happened.

## Running the suite

`should have similar time for auth error, whether queue exists or not` compares wall clock with a
30% tolerance (45% on Postgres) and fails intermittently on a busy machine. Seen twice in four
runs under concurrent bench load, then 4/4 and 5/5 clean when idle, with and without these
changes. Run the suite on an idle machine.
