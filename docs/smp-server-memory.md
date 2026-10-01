# SMP server memory at production scale

Production: ~40k client connections per server, 32 GB RAM shared with PostgreSQL, pure PostgreSQL
store, 14 servers proxying to each other, GHC 9.6.3, `+RTS -N -F1.2 -A16m -I0.01 -Iw15 -s -RTS`.
With `-F1.2` the copying GC needs about 2.2x the live heap plus the nursery, so the server's live
heap has to stay well under ~10 GB.

A busy connection (20 batch-subscribed queues, 2 created with NEW, message traffic) cost 237 KiB of
server live heap, 9.0 GiB at 40k connections. With the changes below it costs 43 KiB, 1.6 GiB.

Earlier findings on leaks and PostgreSQL load are in `leak-findings.md` and `smp-server-db-load.md`.

## Method

All numbers are server-only: the bench client runs in a child process, so the measuring process holds
only the server. PostgreSQL store, production RTS flags, 16-core machine. Live heap is measured after
two major GCs with finalizers allowed to run in between (`liveBytesMiB` in `bench/MemBench.hs`).

| Phase | Measures |
| --- | --- |
| `prodmix` | 2000 connections, each SUBs 20 queues in one block and creates 2 with NEW, then 30 s of SEND/MSG/ACK traffic |
| `conns N` | N idle connections after the SMP handshake |
| `subslice N` | per subscription: `SUBMODE=sub` (`SUBBATCH`, `SUBKEEP`), `new`, `newthensub` |
| `load` | server CPU per operation under a fixed mixed workload |
| `ntfloop`, `ntfdeliver` | notification store and its delivery loop |
| `mesh` | proxy and relay in separate processes: relay sessions, forwards in flight, forward rate (`MESH=`) |
| `pfwdbig` | oversized forwards left in the proxy's `sentCommands` |

```sh
cabal build -fserver_postgres exe:smp-mem-bench
BENCHID=1 PROD_CONNS=2000 PROD_QUEUES=20 PROD_NEW=2 PROD_SEC=30 \
  $(cabal list-bin -fserver_postgres exe:smp-mem-bench) prodmix 0 \
  +RTS -N -F1.2 -A16m -I0.01 -Iw15 -T -ki2k -RTS
```

`BENCHID` offsets ports and the database, so runs do not collide with each other or with tests.

## Results

`prodmix`, live heap per connection after subscribing and peak memory in use under traffic. Each row
adds to the previous one.

| Change | KiB/conn | Peak in use | 40k conns |
| --- | --- | --- | --- |
| base (`sh/fix-leak`) | 236.6 | 1075 MiB | 9.0 GiB |
| `-ki2k` | 111.5 | 719 MiB | 4.3 GiB |
| connection commits (`sh/fix-conn-mem`) | 89.8 | 635 MiB | 3.4 GiB |
| unpinned subscription keys, proxy commits (`sh/mem-combined`) | 80.0 | 604-622 MiB | 3.1 GiB |
| patched tls 1.9 | 42.9 | 469 MiB | 1.6 GiB |

Idle connections (`conns 2000`): 153 KiB at default flags, 68.4 KiB on `sh/mem-combined` with
`-ki2k`, 34.8 KiB with the patched tls.

Message throughput did not drop in any row. `-ki2k` costs some GC time (below).

## Findings

### 1. Thread stacks: 125 KiB per busy connection

Each connection has several threads that block in shallow loops. A thread starts with a 1 KiB stack
(`-ki1k`). On first overflow the RTS copies up to `-kb` (1 KiB) of frames into a new 32 KiB chunk
(`-kc32k`), which with a 1 KiB initial stack moves the loop frame itself, so the thread never returns
to its first chunk and keeps the 32 KiB chunk while the connection lives.

| Flags | idle KiB/conn | prodmix KiB/conn |
| --- | --- | --- |
| default | 153 | 236.6 |
| `-kc8k` | 100 | 135.0 |
| `-ki2k` | 91 | 111.5 |

`-ki2k` leaves the loop frame in the first chunk, so the overflow chunk is freed on return. Cost, 3
alternating 60 s `load` runs: GC CPU +15% (4.8-5.2 s to 5.7-5.8 s per run), major GCs +43% (the live
heap is smaller, so `-F1.2` triggers major GCs sooner), CPU per operation +0-5% (2.74-3.02 ms to
2.91-3.35 ms, one noisy run). One `load` run with `-kc2k` grew to 6.8 GB RSS; not investigated, so
`-kc` is left at its default.

Branch `sh/rts-ki2k` sets `-with-rtsopts=-ki2k` for smp-server. Command-line `+RTS` flags still apply.

### 2. Pinned blocks kept alive by small long-lived objects

`ByteString`s and crypton's `ScrubbedBytes` are pinned and share 4 KiB blocks. GHC treats a pinned
block as live if any object in it is live, and treats every object in a live pinned block as alive,
including dead `ScrubbedBytes`, whose weak pointers and finalizers then stay allocated (GHC 9.6.3
`Evac.c:443`, `GCAux.c:73`). A 24-byte value created during request processing, among crypto
temporaries, therefore keeps ~4 KiB and several dead keys alive for as long as it lives. A standalone
program reproduces it (pinned key 2742 B live per key, unpinned 80 B).

Subscriptions. The subscription key is such a value.

| `subslice 5000` | before | unpinned keys |
| --- | --- | --- |
| NEW-created | 5.25 KiB | 0.46 KiB |
| one SUB per block | 1.67-2.42 KiB | 0.47 KiB |
| 100 SUBs per block | 0.49 KiB | 0.46 KiB |
| NEW0, then SUB on the same connection | 4.98 KiB | 0.47 KiB |

Branch `sh/fix-sub-mem` stores the keys of `subscriptions`, `ntfSubscriptions` and `queueSubscribers`
as `ShortByteString` and shares one key between the maps. CPU unchanged.

TLS session state. tls 1.9 keeps record keys, IVs, TLS 1.3 traffic secrets, verify data and
handshake state for the connection's lifetime, all allocated during the handshake. A heap census per
connection before and after re-allocating them together at the end of the handshake:

| | tls 1.9 | patched |
| --- | --- | --- |
| weak pointers | ~138 | ~45 |
| memory in pinned blocks, outside the census | ~39 KiB | ~13 KiB |
| idle KiB/conn | 68.4 | 34.8 |
| prodmix KiB/conn | 80.0 | 42.9 |

The patch (`tls-1.9-compact-state.patch`: `Network.TLS.Handshake.Compact`, called at the end of
`handshake` under the context locks) re-derives the TLS 1.3 record keys from the kept traffic
secrets, copies the IVs, secrets, session ID, verify data, randoms, main and resumption secrets and
the transcript hash, and reseeds the context RNG. It needs a tls fork. Not compacted: the TLS 1.2 bulk
key, keys installed later by KeyUpdate. The transcript hash copy coerces crypton's hidden `Context`
newtype, so it must be checked on crypton upgrades.

Full test suite with the patched tls: 1431 examples, 0 failures. The same run on unpatched tls had 1
failure, the XFTP agent's "should resume sending file after restart".

SMP handshake state (session secret, chain keys) has the same pattern and is not done yet; the
remaining ~13 KiB outside the census is likely there.

### 3. IDs sliced from the received block: 16 KiB per subscription

Parsed `corrId` and `entityId` are slices of the ~16 KB decrypted block, and the entity ID was stored
as the subscription key, so one live key kept the block. One SUB per block cost 16.43 KiB per
subscription, one survivor of 100 cost 18.04 KiB. `sh/fix-sub-keys` copies both IDs in
`tDecodeServer` (16.43 to 1.67-2.42 KiB). Unpinned keys (finding 2) also remove it for the maps.

### 4. Connection structure: 21 KiB per busy connection

- tls 1.9 stores the receive record state lazily, so each connection kept its last received 16 KB
  record. `recvTLS` forces the state after each read. Not needed with tls 2.x.
- The send and message-send loops are one thread, and one server-wide thread expires inactive clients
  instead of one per client: 6 threads per connection become 4.

`sh/fix-conn-mem`: `prodmix` 111.5 to 89.8 KiB with `-ki2k`, 236.6 to 210.5 KiB without.

### 5. Notification store and its delivery loop

Keys of notifiers whose notifications were delivered stayed in the store, and the loop in
`deliverNtfsThread` sends every key to `getQueueNtfServices` (one `notifier_id IN ?` query read in
full) every 1.5 s.

| `ntfloop` (keys, no traffic) | allocation | CPU | peak in use |
| --- | --- | --- | --- |
| 0 | 0 MiB/s | 0 | 280 MiB |
| 100k | 168 MiB/s | 0.42 cores | 530 MiB |
| 300k | 263 MiB/s | 0.76 cores | 913 MiB |

`ntfdeliver` with 20k delivered notifications: 20000 keys kept, idle server allocating 36 MiB/s at
0.18 cores; with `sh/fix-ntf-store` 0 keys, 0.2 MiB/s, 0.01 cores.

### 6. Proxy mesh

The relay processed forwarded commands from a proxy one at a time in the connection's command loop,
with a PostgreSQL round trip each; all users of a proxy share its connection. Forwards the relay has
not reached wait on the proxy, each with a thread and its ~16 KB block. `mesh`, 1000 forwards per
second for 20 s, proxy and relay in separate processes, 2 runs each:

| | serial | concurrent |
| --- | --- | --- |
| forwards ok / failed | 19,968 / 0 | 19,968 / 0 |
| proxy live heap at end of sending | 192-200 MiB | 13 MiB |
| proxy memory in use | 653-672 MiB | 325 MiB (idle baseline) |
| proxy threads | 4,026-4,137 | 420 |

Here the backlog drained within the 30 s forward timeout. With a slower relay (a busy database, a
remote relay over SOCKS) the queueing delay exceeds it and forwards fail; not reproduced.

`sh/fix-proxy-mesh` forks each forwarded command under the per-connection concurrency limit, stops
keeping the forwarded block on the proxy while waiting (53.0 to 36.8 KiB per in-flight forward,
relay not answering) and caps forwards in flight per relay at 512 (`[PROXY] relay_concurrency`).
Forwarded commands use per-command nonces and secrets and are matched by correlation ID, so concurrent
processing is safe; the SimpleX agent keeps one message in flight per queue. The spec requires
responses in order per queue within a connection (`simplex-messaging.md`, "same order within each
queue ID"); serializing forwarded commands per queue ID is not done yet.

Also in the proxy path (`sh/fix-proxy-leak`): a PFWD of 16260-16266 bytes from a client that declares
`proxyServer = True` failed with `TELargeMsg` before sending and left its 20.2 KiB request in
`sentCommands` for the life of the relay session (2001 PFWDs, 2001 entries); timed-out requests were
kept too; and a relay session that stopped answering was never dropped (10 of 10 forwards timed out).

### 7. Concurrency limit and name resolution

`forkCmd` released its slot when the thread was forked, not when the command finished, so
`serverClientConcurrency` and `serverResolverConcurrency` limited nothing: 16 RSLVs with a limit of 4
all reached the resolver, 64 RSLVs from one connection were 64 concurrent requests, and 5 lookups
answered with 502 opened 5 connections because error bodies were not read. `sh/fix-rslv-fanout` holds
the slot until completion, adds a global limit (`[NAMES] resolver_global_concurrency`, 32) and reads
error bodies. With the limit working, a client that hits it blocks its own command loop.

### 8. Smaller findings

- Active-queue statistics are `IntSet`s at 64 B per element (15M elements, 916 MiB for one set), six
  of them, reset only when `log_stats` is on.
- Control port `save` closes the PostgreSQL pool while the server keeps running; every later DB
  operation blocks (`cpsave` phase: NEW after `save` gets no response).

### 9. tls 2.x

tls 2.1.6 (with tls-session-manager 0.0.6, crypton-connection 0.4.3, http-client-tls 0.3.6.4, an
index-state bump and version pins) saves 2-5 KiB per connection: `prodmix` 75.4 KiB against 80.0.
Problems found:

- After a failed handshake a tls 2 client and a tls 2 server wait for each other in `bye`; this hung
  `testServerMultipleIdentities`. Fixed on `sh/tls2` by closing the context without `bye`.
- A tls 2 client that receives a CertificateRequest runs a timed read inside `handshake`; when the
  timeout fires in the middle of a record the stream fails ("bad record mac") or hangs. SMP servers
  always request client certificates. 1-2 failures per 2000 concurrent connections; present in tls
  2.4.3. A `conns 2000` run with tls 2 on both sides stopped at 53 connections.

tls 2.x is not recommended; `sh/tls2` is kept for reference.

## Open

- Serialize forwarded commands per queue ID on the relay (spec response order).
- A client that sends PFWDs and never reads the responses costs the proxy 6.3 MiB live (11.4 MiB in
  use) until the inactive-client expiry (up to 6 hours), 6 GiB per 1000 such clients.
- PRXY to many aliases of one relay opens an unbounded number of relay sessions, each 207 KiB on the
  proxy and 149 KiB on the relay: 2.0 GiB and 1.4 GiB per 10k.
- Compact the SMP handshake state after the handshake, as in finding 2.
- Publish the tls fork and reference it from `cabal.project`.
- A SEND right after NEW or SUB can find no subscriber yet (`queueSubscribers` is updated through
  `subQ`), so the message waits for the next SUB or ACK. `deliverIfSame` may leave a subscription
  without a delivery thread. Both seen as occasional stuck steps in `load`; not memory.
- `[PROXY] relay_concurrency` and `[NAMES] resolver_global_concurrency` are new INI keys.

## Branches

| Branch | Base | Content |
| --- | --- | --- |
| `sh/fix-ntf-store` | master | finding 5 |
| `sh/fix-sub-keys` | master | finding 3 |
| `sh/fix-proxy-leak` | master | finding 6, request leak and stuck session |
| `sh/fix-rslv-fanout` | master | finding 7 |
| `sh/fix-conn-mem` | master | finding 4 |
| `sh/fix-sub-mem` | master | finding 2, subscription keys |
| `sh/fix-proxy-mesh` | `sh/fix-proxy-leak` | finding 6, relay concurrency, per-relay limit |
| `sh/rts-ki2k` | master | finding 1 |
| `sh/mem-combined` | `sh/fix-leak` | findings 1-6 together, as measured in Results (local) |
| `sh/tls2` | `sh/mem-combined` | finding 9, not for merge (local) |
