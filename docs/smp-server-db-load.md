# SMP server database load: root causes and fixes

## Summary

The recurring `pMsgFwdsOwn_pErrorsOther` spikes are a symptom of chronic disk saturation of the
`smp_server` PostgreSQL database, not a proxy or forwarding bug. The baseline read load is the
Prometheus scrape running whole-table `COUNT` scans of `msg_queues` (48.5M rows) every 30 seconds,
compounded by the message-expiration sweep. The write load comes from indexing `updated_at`:
`updateQueueTime` stamps it on the first send to each active queue per UTC day, and these non-HOT
updates bloat the indexes to 104 GB and amplify WAL to about 425 GB per day (37% full-page images,
~31% from `updateQueueTime`). Because the stamp is day-granular, this write burst clusters at 00:00 UTC,
tipping the saturated disk into the observed spike and loading the pgBackRest backup repository.

Code fixes replace the largest metric scan with an estimate and index the sweep and notifier counts.
Reclaiming the index bloat, which also clears the remaining metric scan, and keeping it down are
operator actions, because PostgreSQL never shrinks indexes automatically.

## Environment

The affected deployment runs the pure PostgreSQL backend (`store_queues: database`,
`store_messages: database`), schema `smp_server`, `db_pool_size 20`, `prometheus_interval 30`,
`[NAMES]` enabled, own-server proxying enabled, and forwards routed over a SOCKS proxy.

`msg_queues`: 48.5M live rows, 12.3% dead tuples, 14 GB heap, 104 GB indexes, 118 GB total.

## Evidence

`pg_stat_statements` over a 5 minute window, ordered by disk reads (`track_io_timing` was off, so
`shared_blks_read` is the disk proxy; the two `EXPLAIN ANALYZE` rows are manual and excluded):

| query | calls | mean ms | reads | share of all reads |
| --- | --- | --- | --- | --- |
| `getEntityCounts` (the six-`COUNT` metric query) | 30 | 111,456 | 990 GB | 70.7% |
| queue-record load (`SELECT recipient_id, …`) | 47,027 | 121 | 89 GB | 6.3% |
| expiration sweep batch (`array_agg` in `expire_old_messages`) | 13 | 233,143 | 62 GB | 4.5% |
| message peek (`DISTINCT ON (recipient_id)`) | 46,932 | 76 | 43 GB | 3.0% |
| `updateQueueTime` (`UPDATE msg_queues SET updated_at`) | 172,885 | 4 | 7.7 GB | 0.5% |
| `write_message` | 110,911 | 5 | 7.0 GB | 0.5% |

`EXPLAIN (ANALYZE, BUFFERS)` of each `msg_queues` count inside `getEntityCounts`:

| count | plan | time |
| --- | --- | --- |
| `queue_count` (`deleted_at IS NULL`) | Parallel Seq Scan | 30 s |
| `notifier_count` (`deleted_at IS NULL AND notifier_id IS NOT NULL`) | Parallel Seq Scan | 32.6 s |
| `ntf_service_queues_count` (`ntf_service_id IS NOT NULL AND deleted_at IS NULL`) | Parallel Seq Scan | 30.2 s |
| `rcv_service_queues_count` (`rcv_service_id IS NOT NULL AND deleted_at IS NULL`) | Index Only Scan | 1.4 ms |

The expiration sweep batch: 229 s for one 10,000-row batch, walking `msg_queues_pkey` and discarding
809,729 rows by filter to find 10,000 expirable ones.

`pg_stat_wal` over the measurement window: 27 TB of WAL accumulated, 37.2% of records full-page
images, averaging about 425 GB per day; recent days reach ~470 GB (from the `archive-push` log) as
the queue count grows.

Per-statement WAL from `pg_stat_statements` (`wal_bytes`), leaf statements only (this instance runs
`pg_stat_statements.track = all`, so the `write_message` wrapper double-counts the `INSERT` and
`UPDATE` it runs, and is excluded):

| category | share of WAL | main statements |
| --- | --- | --- |
| `msg_queues` updates | ~42% | `updateQueueTime` ~31%, `msg_can_write` flags ~9%, insert/delete ~2% |
| `messages` insert and delete | ~34% | message `INSERT`, `DELETE` by `message_id` and `recipient_id` |
| read path (hint bits, FPIs on SELECT) | ~24% | message peek ~15%, `msg_queue_size`, `getEntityCounts` |

## Root causes

1. Prometheus scrape. `getEntityCounts` (`QueueStore/Postgres.hs:154`) runs six `COUNT(1)` subqueries
   every `prometheus_interval` (30 s), called from the metrics path (`Server.hs:698`). Four count
   `msg_queues`; three of those seq-scan the 48.5M-row heap. At 70.7% of all reads it is the dominant
   disk consumer, and it runs continuously (mean 111 s per scrape exceeds the 30 s interval).

2. Message-expiration sweep. `expireMessagesThread` (`Server.hs:477`) calls the `expire_old_messages`
   procedure (`server_schema.sql`), whose inner batch query selects expirable queues ordered by
   `recipient_id`. With `oldQueue = 0` the `updated_at` filter matches everything, so the planner
   walks the primary key and filters `msg_queue_expire`, discarding ~99% of rows per batch.

3. Index bloat. 104 GB of indexes on a 14 GB table. `updated_at` is part of
   `idx_msg_queues_updated_at_recipient_id` (`server_schema.sql:526`) and `updateQueueTime`
   (`QueueStore/Postgres.hs:443`) updates it on the day's first send per queue (172,885 times in the
   window above). Updating an indexed column prevents HOT updates, so every update writes a new row
   version plus new entries in every index on the table, and the old index entries accumulate as bloat.

4. WAL amplification. Only 15.6% of `msg_queues` updates are HOT, because its composite index covers
   `updated_at` and `msg_queue_expire`, both changed on the hot path (cause 3); the rest rewrite every
   index on the table. With the 104 GB of bloated indexes and frequent checkpoints (`max_wal_size 4GB`,
   `checkpoint_timeout 5min`, `wal_compression off`), 37% of WAL records are full-page images, and the
   server generates about 425 GB of WAL per day (27 TB accumulated; recent days near 470 GB).
   `updateQueueTime`, stamping `updated_at` on the ~5.3M daily-active queues, is the single largest
   statement at ~31% of WAL (see Evidence). pgBackRest `archive-push` ships all of it, loading the
   primary disk and the backup repository. The load peaks
   at 00:00 UTC because `getSystemDate` rounds `updated_at` to the UTC day, so the first send to each
   active queue after midnight runs `updateQueueTime`, clustering these writes and the `archive-push`
   volume in the 00h hour.

## Index bloat and autovacuum

Autovacuum is running (60 runs on this table) and is not misconfigured, but two limits apply.

Autovacuum reclaims heap dead tuples and refreshes planner statistics; it does not shrink indexes.
Only `REINDEX` or `pg_repack` rebuilds a bloated B-tree. Index bloat therefore has no automatic
remedy.

Default autovacuum pacing assumes moderate churn. `autovacuum_vacuum_scale_factor = 0.2` waits until
20% of the table is dead (about 9.7M rows here) before vacuuming, and cost-based throttling caps its
I/O, so a hot table stays around 12% dead. Per-table tuning makes it run sooner and faster.

The amplifier is indexing `updated_at`, a column updated on every send, which the fixes and operator
actions below address.

## Implemented fixes (batch 1)

Branch `sh/leaks-batch-1`, two commits.

| commit | change | effect |
| --- | --- | --- |
| `88673eee` | migration `20260916_prometheus_indexes` adds partial indexes `idx_msg_queues_expire (recipient_id) WHERE deleted_at IS NULL AND msg_queue_expire` and `idx_msg_queues_notifier_active (notifier_id) WHERE deleted_at IS NULL AND notifier_id IS NOT NULL` | the sweep batch and `notifier_count` become index scans |
| `2912be1e` | `getEntityCounts.queue_count` uses `pg_class.reltuples` (`QueueStore/Postgres.hs:154`) | removes the 30 s, 990 GB whole-table `COUNT` on every scrape |

Verified: both indexes are created and used as index-only scans, the schema-dump test passes, and
`smp-server` builds. `queueCount` is consumed only by metrics, logs, and display
(`Server.hs:528,698,815,2369`), so an estimate is safe.

The migration uses plain `CREATE INDEX` because migrations run inside a transaction. Operators should
pre-create both indexes with `CREATE INDEX CONCURRENTLY` before deploying to avoid the build lock; the
migration then no-ops.

Not fixed by new indexes:

- `ntf_service_queues_count` seq-scans only because of index bloat; `idx_msg_queues_ntf_service_id`
  already covers it. `REINDEX` restores the index-only scan, as proven by `rcv_service_queues_count`.
- `rcv_service_queues_count` and the two `services` counts are already cheap.

## Operator actions

1. Reclaim index bloat (online, no lock; needs free disk near the index size; run largest first):
   ```
   REINDEX INDEX CONCURRENTLY smp_server.idx_msg_queues_updated_at_recipient_id;
   REINDEX INDEX CONCURRENTLY smp_server.idx_msg_queues_notifier_id;
   REINDEX INDEX CONCURRENTLY smp_server.idx_msg_queues_ntf_service_id;
   REINDEX INDEX CONCURRENTLY smp_server.idx_msg_queues_rcv_service_id;
   REINDEX INDEX CONCURRENTLY smp_server.idx_msg_queues_sender_id;
   REINDEX INDEX CONCURRENTLY smp_server.idx_msg_queues_link_id;
   ANALYZE smp_server.msg_queues;
   ```
   Expect `pg_indexes_size('smp_server.msg_queues')` to drop from 104 GB to roughly 15-20 GB. `ANALYZE`
   restores the index-only scan for `ntf_service_queues_count`.

2. Tune per-table autovacuum so dead tuples and bloat do not return, and schedule a monthly
   `REINDEX TABLE CONCURRENTLY`:
   ```
   ALTER TABLE smp_server.msg_queues SET (
     autovacuum_vacuum_scale_factor  = 0.02,
     autovacuum_analyze_scale_factor = 0.01,
     autovacuum_vacuum_cost_limit    = 2000,
     autovacuum_vacuum_cost_delay    = 2
   );
   ```

3. Cut WAL and checkpoint pressure (all reloadable, no restart):
   ```
   ALTER SYSTEM SET wal_compression = 'lz4';
   ALTER SYSTEM SET max_wal_size = '32GB';
   ALTER SYSTEM SET checkpoint_timeout = '30min';
   SELECT pg_reload_conf();
   ```
   Fewer checkpoints produce fewer full-page images; `wal_compression` shrinks those that remain.
   Together these reduce the WAL written on the primary and shipped by `archive-push`. The message
   insert and delete volume itself is fixed by traffic, but most of its WAL cost is amplification
   (full-page images and hint-bit writes on bloated pages), which these settings and `REINDEX` reduce.
   This is separate from pgBackRest repo-side compression, which does not reduce WAL on the primary.
   Verify with `pg_stat_reset_shared('wal')`, wait, then re-check `wal_fpi` and `wal_bytes` in
   `pg_stat_wal`.

4. Enable `track_io_timing = on` so disk wait time is measurable in `pg_stat_statements`.

## Proposed follow-up (batch 2)

Drop `idx_msg_queues_updated_at_recipient_id` if it is redundant. The new `idx_msg_queues_expire`
covers the sweep, and with `oldQueue = 0` the `updated_at` range provides no selectivity. Removing the
only index on `updated_at`, and setting `fillfactor = 90` on `msg_queues`, makes `updateQueueTime`
updates HOT-eligible and largely stops index bloat at the source, which also cuts the WAL and
archive-push load (that update is ~31% of WAL). It reduces how often `REINDEX` is needed. Before
dropping it, confirm no caller passes a real `updated_at` cutoff; one query filters
`WHERE deleted_at IS NULL AND updated_at > ? ORDER BY recipient_id ASC` (`QueueStore/Postgres.hs:628`).
The deeper fix also requires keeping `msg_queue_expire` out of hot-path indexes (it changes on every
send); a partial index churns only on the empty-to-nonempty flip, not every message.
