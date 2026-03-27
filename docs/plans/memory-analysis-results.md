## Memory Diagnostics Results

### Data Collection

Server: smp19.simplex.im, PostgreSQL backend, `useCache = False`
RTS flags: `+RTS -N -A16m -I0.01 -Iw15 -s -RTS` (16 cores)

### Mar 20 Data (1 hour, 07:19-08:19)

```
Time    rts_live  rts_heap  rts_large  rts_frag   clients  non-large
07:19    7.5 GB    8.2 GB    5.5 GB    0.03 GB    14,000    2.0 GB
07:24    6.4 GB   10.8 GB    5.2 GB    3.6 GB     14,806    1.2 GB
07:29    8.2 GB   10.8 GB    6.5 GB    1.8 GB     15,667    1.7 GB
07:34   10.0 GB   12.3 GB    7.9 GB    1.4 GB     15,845    2.1 GB
07:39    6.7 GB   13.0 GB    5.3 GB    5.6 GB     16,589    1.4 GB
07:44    8.5 GB   13.0 GB    6.7 GB    3.7 GB     16,283    1.8 GB
07:49    6.5 GB   13.0 GB    5.2 GB    5.8 GB     16,532    1.3 GB
07:54    6.0 GB   13.0 GB    4.8 GB    6.3 GB     16,636    1.2 GB
07:59    6.4 GB   13.0 GB    5.1 GB    5.9 GB     16,769    1.3 GB
08:04    8.3 GB   13.0 GB    6.5 GB    3.9 GB     17,352    1.8 GB
08:09   10.2 GB   13.0 GB    8.0 GB    1.9 GB     17,053    2.2 GB
08:14    5.6 GB   13.0 GB    4.5 GB    6.8 GB     17,147    1.1 GB
08:19    7.6 GB   13.0 GB    6.1 GB    4.6 GB     17,496    1.5 GB
```

non-large = rts_live - rts_large (normal Haskell heap objects: Maps, TVars, closures)

### Mar 19 Data (5.5 hours, 07:49-13:19)

rts_heap grew from 10.1 GB to 20.7 GB over 5.5 hours.
Post-GC rts_live floor rose from 5.5 GB to 9.1 GB.

### Findings

**1. Large/pinned objects dominate live data (60-80%)**

`rts_large` = 4.5-8.0 GB out of 5.6-10.2 GB live. These are allocations > ~3KB that go on GHC's large object heap. They oscillate (not growing monotonically), meaning they are being allocated and freed constantly — transient, not leaked.

**2. Fragmentation is the heap growth mechanism**

`rts_heap ≈ rts_live + rts_frag`. The heap grows because pinned/large objects fragment GHC's block allocator. Once GHC expands the heap, it never shrinks. Growth pattern:
- Large objects allocated → occupy blocks
- Large objects freed → blocks can't be reused if ANY other object shares the block
- New allocations need fresh blocks → heap expands
- Heap never returns memory to OS

**3. Non-large heap data is stable (~1.0-2.2 GB)**

Normal Haskell objects (Maps, TVars, closures, client structures) account for only 1-2 GB. This scales with client count at ~100-130 KB/client and does NOT grow over time.

**4. All tracked data structures are NOT the cause**

- `clientSndQ=0, clientMsgQ=0` — TBQueues empty, no message accumulation
- `smpQSubs` oscillates ~1.0-1.4M — entries are cleaned up, not leaking
- `ntfStore` < 2K entries — negligible
- All proxy agent maps near 0
- `loadedQ=0` — useCache=False confirmed working

**5. Source of large objects is unclear without heap profiling**

The 4.5-8.0 GB of large objects could come from:
- PostgreSQL driver (`postgresql-simple`/`libpq`) — pinned ByteStrings for query results
- TLS library (`tls`) — pinned buffers per connection
- Network socket I/O — pinned ByteStrings for recv/send
- SMP protocol message blocks

Cannot distinguish between these without `-hT` heap profiling (which is too expensive for this server).

### Root Cause

**GHC heap fragmentation from constant churn of large/pinned ByteString allocations.**

Not a data structure leak. The live data itself is reasonable (5-10 GB for 15-17K clients). The problem is that GHC's copying GC cannot compact around pinned objects, so the heap grows with fragmentation and never shrinks.

### Mitigation Options

All are RTS flag changes — no rebuild needed, reversible by restart.

**1. `-F1.2`** (reduce GC trigger factor from default 2.0)
- Triggers major GC when heap reaches 1.2x live data instead of 2x
- Reclaims fragmented blocks sooner
- Trade-off: more frequent GC, slightly higher CPU
- Risk: low — just makes GC run more often

**2. Reduce `-A16m` to `-A4m`** (smaller nursery)
- More frequent minor GC → short-lived pinned objects freed faster
- Trade-off: more GC cycles, but each is smaller
- Risk: low — may actually improve latency by reducing GC pause times

**3. `+RTS -xn`** (nonmoving GC)
- Designed for pinned-heavy workloads — avoids copying entirely
- Available since GHC 8.10, improved in 9.x
- Trade-off: different GC characteristics, less battle-tested
- Risk: medium — different GC algorithm, should test first

**4. Limit concurrent connections** (application-level)
- Since large objects scale per-client, fewer clients = less fragmentation
- Trade-off: reduced capacity
- Risk: low but impacts users
