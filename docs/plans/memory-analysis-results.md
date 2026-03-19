## Memory Diagnostics Results (5.5 hours, 07:49 - 13:19, Mar 19)

**rts_heap (total process heap) — grows monotonically, never shrinks:**
```
07:49  10.1 GB
09:24  14.1 GB
11:24  18.7 GB
13:19  20.7 GB
```
Growth: **+10.6 GB in 5.5 hours** (~1.9 GB/hour). GHC never returns memory to the OS.

**rts_live (actual live data) — sawtooth pattern, minimums growing:**
```
07:54   5.5 GB  (post-GC valley)
08:54   6.2 GB
09:44   6.6 GB
11:24   6.6 GB
13:14   9.1 GB
```
The post-GC floor is rising: **+3.6 GB over 5.5 hours**. This confirms a genuine leak.

**But smpQSubs is NOT the cause** — it oscillates between 1.2M-1.4M, not growing monotonically. At ~130 bytes/entry, 1.4M entries = ~180MB. Can't explain 9GB.

**clients** oscillates 14K-20K, also not monotonically growing.

**Everything else is tiny**: ntfStore ~7K entries (<1MB), paClients ~350 (~50KB), all other metrics near 0.

**The leak is in something we're not measuring.** ~6-9GB of live data is unaccounted for by all tracked structures. The most likely candidates are:

1. **Per-client state we didn't measure** — the *contents* of TBQueues (buffered messages), per-client `subscriptions` TMap contents (Sub records with TVars)
2. **TLS connection buffers** — the `tls` library allocates internal state per connection
3. **Pinned ByteStrings** from PostgreSQL queries — these aren't collected by normal GC
4. **GHC heap fragmentation** — pinned objects cause block-level fragmentation

The next step is either:
- **Add more metrics**: measure total TBQueue fill across all clients, total subscription count, and pinned byte count from RTS stats
- **Run with `-hT`**: heap profiling by type to see exactly what's consuming memory
