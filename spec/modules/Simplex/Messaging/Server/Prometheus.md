# Simplex.Messaging.Server.Prometheus

> Prometheus text exposition format for router metrics, with histogram gap-filling and derived aggregations.

**Source**: [`Prometheus.hs`](../../../../../src/Simplex/Messaging/Server/Prometheus.hs)

## Histogram gap-filling

`showTimeBuckets` uses `mapAccumL` over sorted bucket keys. When the gap between consecutive buckets exceeds 60 seconds, it inserts a synthetic bucket at `sec - 60` with the cumulative total up to that point. This fills sparse `TimeBuckets` maps into continuous Prometheus histograms. The 60-second gap threshold is hardcoded.

## Bucket sum aggregation — filters by value, not key

`showBucketSums` intends to aggregate buckets into fixed time periods: 0-60s, 60-300s, 300-1200s, 1200-3600s, 3600+s. However, `IM.filter` (from `Data.IntMap.Strict`) filters by **value** (count), not by key (time). The predicate `\sec -> minTime <= sec && sec < maxTime` is applied to count values, not to the IntMap keys that represent seconds. This means buckets are selected based on whether their count falls in the range, not based on their time boundary. The aggregation boundaries are also independent of the bucketing thresholds in `updateTimeBuckets` (Stats.hs), which uses 5s/10s/30s/60s quantization.

## Non-standard Prometheus timestamp output

The `mstr` function appends `tsEpoch ts` (millisecond-precision Unix timestamp) directly after metric values, which is valid Prometheus text exposition format.

## Delivery histogram count/sum source

`simplex_smp_delivery_ack_confirmed_time_count` is `_msgRecv + _msgRecvGet`. `simplex_smp_delivery_ack_confirmed_time_sum` is `sumTime` from `_msgRecvAckTimes`. The count is accumulated separately from the histogram — if there's a code path that increments `msgRecv` without calling `updateTimeBuckets`, count and sum diverge.
