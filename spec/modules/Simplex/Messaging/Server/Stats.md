# Simplex.Messaging.Server.Stats

> Router statistics: counters, rolling period tracking, delivery time histograms, proxy stats, service stats.

**Source**: [`Stats.hs`](../../../../../src/Simplex/Messaging/Server/Stats.hs)

## Overview

All stats are `IORef`-based, not STM — individual increments are atomic (`atomicModifyIORef'_`) but multi-field reads are not transactional. `getServerStatsData` reads 30+ IORefs sequentially — the resulting snapshot is temporally smeared, not a point-in-time atomic view.

## PeriodStats — rolling window with boundary-only reset

`PeriodStats` maintains three `IORef IntSet` (day, week, month). `updatePeriodStats` hashes the entity ID and inserts into all three periods. `periodStatCounts` resets a period's IntSet **only** when the period boundary is reached (day 1 of that period). At non-boundary times, it returns `""` (empty string) — the data is kept accumulating but not reported.

See comment on `periodCount`. At day boundary (`periodCount 1 ref`), the day set is atomically swapped to empty and its size returned. Week resets on Monday (day 1 of week), month on the 1st. Periods are independent — day reset does NOT affect week/month accumulation. Each period counts unique queue hashes that were active during that period.

## Disabled metrics — performance trade-offs

See comments on `qSubNoMsg` and `subscribedQueues` in the source. `qSubNoMsg` is disabled because counting "subscription with no message" creates too many STM transactions. `subscribedQueues` is disabled because maintaining PeriodStats-style IntSets for all subscribed queues uses too much memory. Both fields are omitted from the stats output entirely. The parser handles old log files that contain these fields: `qSubNoMsg` is silently skipped via `skipInt`, and `subscribedQueues` is parsed but replaced with empty data.

## TimeBuckets — ceil-aligned bucketing with precision loss

`updateTimeBuckets` quantizes delivery-to-acknowledgment times into sparse buckets. Exact for 0-5s, then ceil-aligned: 6-30s → 5s buckets, 31-60s → 10s, 61-180s → 30s, 180+s → 60s. The `toBucket` formula uses `- ((- n) \`div\` m) * m` for ceiling division. `sumTime` and `maxTime` preserve exact values; only the histogram is lossy.

## Serialization backward compatibility — silent data coercion

The `strP` parser for `ServerStatsData` handles multiple format generations. Old format `qDeleted=` is read as `(value, 0, 0)` — `qDeletedNew` and `qDeletedSecured` default to 0. `qSubNoMsg` is parsed and silently discarded (`skipInt`). `subscribedQueues` is parsed but replaced with empty data. Data loaded from old formats is coerced, not reconstructed — precision is permanently lost.

## Serialization typo — internally consistent

The field `_srvAssocUpdated` is serialized as `"assocUpdatedt="` (extra 't') in `ServiceStatsData` encoding. The parser expects the same misspelling. Both sides are consistent, so it works — but external systems expecting `assocUpdated=` will fail to parse.

## atomicSwapIORef for stats logging

In `logServerStats` (Server.hs), each counter is read and reset via `atomicSwapIORef ref 0`. This is lock-free but means counters are zeroed after each logging interval — values represent delta since last log, not cumulative totals. `qCount` and `msgCount` are exceptions: they're read-only (via `readIORef`) because they track absolute current values, not deltas.

## setPeriodStats — not thread safe

See comment on `setPeriodStats`. Uses `writeIORef` (not atomic). Only safe during router startup when no other threads are running. If called concurrently, period data could be corrupted.
