# SMP server stats persistence

## Problem

SMP server stats live in `IORef`s and are written to `smp-server-stats.log` only on clean shutdown or the control port `save` command (`saveServer`, `Server.hs:240`, `Server.hs:1036`). At startup the file is restored and renamed to `.bak` (`Server.hs:2540`), so no stats file exists while the server runs. A crash loses all stats since start, including lifetime counters (`*_services_assoc_*`, `*_services_sub_*`, `ntfNewCreated`, `msgSentBlock`) and the active-queue period sets. Without the file, `qCount` and `ntfCount` start from 0 and drift, and `msgCount` stays wrong until the first expiration run (`Server.hs:491`).

## Goals

- Crash loses at most one save interval of stats.
- Postgres-mode servers keep stats in the database, covered by database backups.
- Memory-mode servers keep stats in the file, written atomically.
- `qCount`, `msgCount`, `ntfCount` are correct after every start.

## Non-goals

- Persisting counters that the file does not persist today (`srvSubOk/More/Fewer/Diff/*Total`, `rcvServicesSubMsg`, `rcvServicesSubDuplicate`, `authDelayExceeded`, `cmdSlotWait*`, `msgRecvAckTimes`).
- XFTP and notification server stats.
- Resetting week/month sets when the server is down on a Monday or the 1st (existing behaviour).

## Configuration

- `ServerConfig.statsSaveInterval :: Int64`, seconds.
- INI `[STORE_LOG] stats_save_interval`, default 300. Generated ini gets `# stats_save_interval = 300` next to `prometheus_interval` (`Main/Init.hs:107`).
- Persistence is active only when `serverStatsBackupFile` is set (`log_stats = on`), as today. The same path is the memory-mode stats file and the Postgres-mode import source.

## Architecture

New module `Simplex.Messaging.Server.StatsStore`:

```haskell
data StatsStore
  = StatsFile FilePath
#if defined(dbServerPostgres)
  | StatsDB DBStore FilePath -- import source
#endif
```

`Env` selects the backend from `ServerStoreCfg`: `SSCMemory` gives `StatsFile`, `SSCDatabase` gives `StatsDB` with the queue store's `DBStore`. Queue and message store classes are unchanged. The module exposes load and save functions; `Server.hs` does not branch on the backend.

### PeriodStats

Each of `day`, `week`, `month` in `PeriodStats` gets a pending `IORef IntSet` of hashes added since the last successful save, and a pending-reset flag. `updatePeriodStats` inserts into the pending set when it inserts into the main set. A reset (rollover) empties the main and pending sets and sets the flag.

The six persisted sets are identified by `PeriodSet`:

| `PeriodSet` | value | source |
|---|---|---|
| `PSMsgDay` | 1 | `activeQueues.day` |
| `PSMsgWeek` | 2 | `activeQueues.week` |
| `PSMsgMonth` | 3 | `activeQueues.month` |
| `PSNtfDay` | 4 | `activeQueuesNtf.day` |
| `PSNtfWeek` | 5 | `activeQueuesNtf.week` |
| `PSNtfMonth` | 6 | `activeQueuesNtf.month` |

## Data flow

### Startup (replaces `restoreServerStats`)

Postgres mode:
1. If the `server_stats` row exists, load it and load `server_stats_queues` into the six sets. A load error logs and exits.
2. Else if the file exists, parse it (parse error logs and exits), write the row and all set hashes in one transaction, rename the file to `.bak`.
3. Else start with empty stats.

A file present together with an existing row is ignored and left in place, with a warning in the log.

Memory mode: if the file exists, load it without renaming; else start with empty stats.

In all cases, after loading:
- `qCount` is set from `getEntityCounts`, `msgCount` from the message restore stats, `ntfCount` from the notification restore stats.
- `msgExpired` and `msgNtfExpired` add the counts expired during startup, as `restoreServerStats` does today.

### Save

`saveStatsThread` runs every `statsSaveInterval` seconds. Shutdown (`saveServer`) and control port `save` run the same save. Every save and the rollover hold `savingLock`. The save function does not take the lock itself: `stopServer` and control `save` already hold it around `saveServer`, and the rollover calls save twice inside one lock.

Postgres mode, one transaction:
1. For each set with the pending-reset flag: `DELETE FROM server_stats_queues WHERE period_set = ?`.
2. For each set: `INSERT INTO server_stats_queues (period_set, queue_hash) SELECT ?, unnest(?::BIGINT[]) ON CONFLICT DO NOTHING` with the swapped-out pending hashes.
3. `INSERT ... ON CONFLICT (server_stats_id) DO UPDATE` of all counter columns and `saved_at`.

On commit the pending-reset flags are cleared. On failure the swapped-out pending hashes are merged back into the pending sets, flags stay set, the error is logged, and the next save retries.

Memory mode: write `strEncode` of `ServerStatsData` to `<file>.tmp`, then rename over `<file>`. On failure, log, remove the temp file, keep the old file.

### Daily rollover (`logServerStats`)

Under `savingLock`:
1. Save, flushing pending hashes of the ending period.
2. Swap counters and write the daily line as today; reset the day sets, the week sets on Monday, the month sets on the 1st, setting their pending-reset flags.
3. Save, deleting the reset sets' rows and storing the zeroed counters.

A crash between steps 2 and 3 restores pre-rollover counters, and the next daily line counts them twice; the window is one save.

## Schema

Migration `20261023_server_stats` in `QueueStore/Postgres/Migrations.hs`; down migration drops both tables; `server_schema.sql` regenerated.

```sql
CREATE TABLE server_stats(
  server_stats_id SMALLINT NOT NULL PRIMARY KEY CHECK (server_stats_id = 1),
  saved_at BIGINT NOT NULL,
  from_time BIGINT NOT NULL,
  q_created BIGINT NOT NULL,
  q_secured BIGINT NOT NULL,
  q_deleted_all BIGINT NOT NULL,
  q_deleted_new BIGINT NOT NULL,
  q_deleted_secured BIGINT NOT NULL,
  q_deleted_all_b BIGINT NOT NULL,
  q_blocked BIGINT NOT NULL,
  q_sub BIGINT NOT NULL,
  q_sub_all_b BIGINT NOT NULL,
  q_sub_auth BIGINT NOT NULL,
  q_sub_duplicate BIGINT NOT NULL,
  q_sub_prohibited BIGINT NOT NULL,
  q_sub_end BIGINT NOT NULL,
  q_sub_end_b BIGINT NOT NULL,
  ntf_created BIGINT NOT NULL,
  ntf_new_created BIGINT NOT NULL,
  ntf_deleted BIGINT NOT NULL,
  ntf_deleted_b BIGINT NOT NULL,
  ntf_sub BIGINT NOT NULL,
  ntf_sub_b BIGINT NOT NULL,
  ntf_sub_auth BIGINT NOT NULL,
  ntf_sub_duplicate BIGINT NOT NULL,
  msg_sent BIGINT NOT NULL,
  msg_sent_auth BIGINT NOT NULL,
  msg_sent_quota BIGINT NOT NULL,
  msg_sent_large BIGINT NOT NULL,
  msg_sent_block BIGINT NOT NULL,
  msg_recv BIGINT NOT NULL,
  msg_recv_get BIGINT NOT NULL,
  msg_get BIGINT NOT NULL,
  msg_get_no_msg BIGINT NOT NULL,
  msg_get_auth BIGINT NOT NULL,
  msg_get_duplicate BIGINT NOT NULL,
  msg_get_prohibited BIGINT NOT NULL,
  msg_expired BIGINT NOT NULL,
  msg_sent_ntf BIGINT NOT NULL,
  msg_recv_ntf BIGINT NOT NULL,
  msg_ntfs BIGINT NOT NULL,
  msg_ntfs_b BIGINT NOT NULL,
  msg_ntf_no_sub BIGINT NOT NULL,
  msg_ntf_lost BIGINT NOT NULL,
  msg_ntf_expired BIGINT NOT NULL,
  p_relays_requests BIGINT NOT NULL,
  p_relays_successes BIGINT NOT NULL,
  p_relays_errors_connect BIGINT NOT NULL,
  p_relays_errors_compat BIGINT NOT NULL,
  p_relays_errors_other BIGINT NOT NULL,
  p_relays_own_requests BIGINT NOT NULL,
  p_relays_own_successes BIGINT NOT NULL,
  p_relays_own_errors_connect BIGINT NOT NULL,
  p_relays_own_errors_compat BIGINT NOT NULL,
  p_relays_own_errors_other BIGINT NOT NULL,
  p_msg_fwds_requests BIGINT NOT NULL,
  p_msg_fwds_successes BIGINT NOT NULL,
  p_msg_fwds_errors_connect BIGINT NOT NULL,
  p_msg_fwds_errors_compat BIGINT NOT NULL,
  p_msg_fwds_errors_other BIGINT NOT NULL,
  p_msg_fwds_own_requests BIGINT NOT NULL,
  p_msg_fwds_own_successes BIGINT NOT NULL,
  p_msg_fwds_own_errors_connect BIGINT NOT NULL,
  p_msg_fwds_own_errors_compat BIGINT NOT NULL,
  p_msg_fwds_own_errors_other BIGINT NOT NULL,
  p_msg_fwds_recv BIGINT NOT NULL,
  rcv_services_assoc_new BIGINT NOT NULL,
  rcv_services_assoc_duplicate BIGINT NOT NULL,
  rcv_services_assoc_updated BIGINT NOT NULL,
  rcv_services_assoc_removed BIGINT NOT NULL,
  rcv_services_sub_count BIGINT NOT NULL,
  rcv_services_sub_duplicate BIGINT NOT NULL,
  rcv_services_sub_queues BIGINT NOT NULL,
  rcv_services_sub_end BIGINT NOT NULL,
  ntf_services_assoc_new BIGINT NOT NULL,
  ntf_services_assoc_duplicate BIGINT NOT NULL,
  ntf_services_assoc_updated BIGINT NOT NULL,
  ntf_services_assoc_removed BIGINT NOT NULL,
  ntf_services_sub_count BIGINT NOT NULL,
  ntf_services_sub_duplicate BIGINT NOT NULL,
  ntf_services_sub_queues BIGINT NOT NULL,
  ntf_services_sub_end BIGINT NOT NULL,
  rslv_reqs BIGINT NOT NULL,
  rslv_succ BIGINT NOT NULL,
  rslv_not_found BIGINT NOT NULL,
  rslv_resolver_errs BIGINT NOT NULL,
  rslv_disabled BIGINT NOT NULL
);

CREATE TABLE server_stats_queues(
  period_set SMALLINT NOT NULL,
  queue_hash BIGINT NOT NULL,
  PRIMARY KEY (period_set, queue_hash)
);
```

Times are epoch seconds, as in existing tables. `qCount`, `msgCount`, `ntfCount` are not stored; they are recomputed at startup.

Expected size at month end on current servers (1.5M monthly and 1.3M notification monthly queues mid-month, Oct 14): 4–6M hash rows, 300–400MB with the primary key index. Each save inserts only new hashes.

Manual correction, with the server stopped:

```sql
UPDATE server_stats SET rcv_services_assoc_new = rcv_services_assoc_new + 835795;
```

## Error handling

| Failure | Behaviour |
|---|---|
| DB load at startup | Log, exit. Starting with zeros would overwrite the row on the first save. |
| File parse at startup or import | Log, exit (as today). |
| Periodic DB save | Log, merge pending hashes back, keep reset flags, retry next interval. |
| Memory file write | Log, remove temp file, keep old file. |
| Shutdown save | Log. |

## Testing

In `tests/ServerTests.hs`, next to the existing stats tests (`:1049`, `:1196`):

1. Memory mode, 1s interval: after activity, the file read while the server runs has matching counters; a restart from a copy of that mid-run file restores them; the file is not renamed.
2. Postgres: while the server runs, the `server_stats` row and `server_stats_queues` counts per set match the activity.
3. Postgres import: file and no row produce the row with file values and a `.bak` file; file and existing row keep the row and leave the file in place.
4. No stats source with existing queues and messages: `qCount`, `msgCount`, `ntfCount` equal store counts.
5. `StatsStore` against Postgres: save/load round trip; pending hashes merged back after a failed save; reset flags delete only the flagged sets; load after rollover returns only new-period hashes.
6. Pure functions: pending-hash merge and pending-reset flag handling.

Postgres tests run with `-fserver_postgres`, as existing ones do.
