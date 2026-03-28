# SMP Server Postgres: Slow Query Analysis

Data from three production servers (A, B, C), ~3.5 day observation window.

## Top queries by total time

| Rank | Query | Server A ms | Server B ms | Server C ms |
|------|-------|-------------|-------------|-------------|
| 1 | getEntityCounts (6 COUNT subqueries) | 1,682,874 | 1,639,325 | 1,619,892 |
| 2 | write_message() | 303,393 | 458,262 | 280,375 |
| 3 | try_del_peek_msg() | 352,912 | 386,036 | 333,877 |
| 4 | expire_old_messages() | 246,034 | 220,003 | 160,232 |
| 5 | UPDATE SET updated_at | 234,146 | 216,911 | 211,480 |
| 6 | INSERT INTO messages | 184,430 | 323,617 | 169,149 |
| 7 | expire batch cursor (array_agg) | 122,739 | 99,061 | 39,975 |
| 8 | Batch recipient_id IN lookups | ~134K | ~79K | ~81K |
| 9 | Batch notifier_id IN lookups | ~143K | ~64K | ~64K |
| 10 | msg_peek (SELECT FROM messages) | ~112K | ~102K | ~126K |

getEntityCounts alone is **45-48%** of total query time on all three servers.

---

## Verified fixes

### 1. getEntityCounts: replace ③④ with SUM(queue_count)

**Query** (`QueueStore/Postgres.hs:160-167`):

```sql
SELECT
  (SELECT COUNT(1) FROM msg_queues WHERE deleted_at IS NULL) AS queue_count,                                            -- ①
  (SELECT COUNT(1) FROM msg_queues WHERE deleted_at IS NULL AND notifier_id IS NOT NULL) AS notifier_count,              -- ②
  (SELECT COUNT(1) FROM services WHERE service_role = ?) AS rcv_service_count,                                           -- trivial
  (SELECT COUNT(1) FROM services WHERE service_role = ?) AS ntf_service_count,                                           -- trivial
  (SELECT COUNT(1) FROM msg_queues WHERE rcv_service_id IS NOT NULL AND deleted_at IS NULL) AS rcv_service_queues_count,  -- ③
  (SELECT COUNT(1) FROM msg_queues WHERE ntf_service_id IS NOT NULL AND deleted_at IS NULL) AS ntf_service_queues_count   -- ④
```

| Server | Calls | Avg ms | Max ms | Total ms |
|--------|-------|--------|--------|----------|
| A | 5,058 | 332.7 | 2,061 | 1,682,874 |
| B | 5,055 | 324.3 | 1,844 | 1,639,325 |
| C | 5,053 | 320.6 | 1,250 | 1,619,892 |

**Problem**: 4 subqueries scan `msg_queues`. Indexes exist for ③
(`idx_msg_queues_rcv_service_id(rcv_service_id, deleted_at)`), ④
(`idx_msg_queues_ntf_service_id(ntf_service_id, deleted_at)`), and potentially ①
(`idx_msg_queues_updated_at_recipient_id(deleted_at, ...)`), but actual query plans
and per-subquery cost are unknown without `EXPLAIN ANALYZE`.

**Fix**: Replace ③ and ④:

```sql
COALESCE((SELECT SUM(queue_count) FROM services WHERE service_role = 'M'), 0) AS rcv_service_queues_count,
COALESCE((SELECT SUM(queue_count) FROM services WHERE service_role = 'N'), 0) AS ntf_service_queues_count
```

**Verification**:
- Trigger logic traced for all transitions (NULL→set, change, soft-delete, physical delete) — correct.
- FK `rcv_service_id REFERENCES services(service_id)` guarantees equivalence.
- `queue_count + p_change` is atomic under READ COMMITTED.
- `update_all_aggregates()` exists as repair mechanism.

**Savings**: Eliminates 2 of 4 msg_queues scans. Exact per-subquery cost unknown — needs `EXPLAIN ANALYZE`.

---

### 2. expire_old_messages: remove trailing COUNTs

At the end of `expire_old_messages` (`Migrations.hs`):

```sql
r_stored_msgs_count := (SELECT COUNT(1) FROM messages);
r_stored_queues := (SELECT COUNT(1) FROM msg_queues WHERE deleted_at IS NULL);
```

| Server | expire avg | r_stored_queues avg | r_stored_msgs avg | COUNTs combined | % of procedure |
|--------|-----------|---------------------|-------------------|-----------------|----------------|
| A | 11,716ms | 695ms | 110ms | 805ms | 6.9% |
| B | 10,476ms | 631ms | 17ms | 648ms | 6.2% |
| C | 7,630ms | 588ms | 53ms | 641ms | 8.4% |

**How used** (`Server.hs:485-488`):
- `storedMsgsCount` → resets `msgCount` stat (also maintained incrementally: +1 on send, -1 on ACK)
- `storedQueues` → **only logged** via `printMessageStats`. Same value available from `getEntityCounts`.

**Fix**: Remove both COUNTs. Return only `r_expired_msgs_count`.

**Verification**: All usages traced. `storedQueues` is only logged. `storedMsgsCount` resets
an incrementally-maintained counter — removing means potential drift, corrected on restart.

**Savings**: 641–805ms per cycle × 21 cycles = **13.5–16.9s total** (CSV-verified).

---

### 3. Trigger WHEN clause: skip PL/pgSQL call for non-service updates

**Current** (`Migrations.hs:566-568`):

```sql
CREATE TRIGGER tr_queue_update
AFTER UPDATE ON msg_queues
FOR EACH ROW EXECUTE PROCEDURE on_queue_update();
```

Server C data — ~2.6M updates, only ~110K (4.3%) change service fields:

| UPDATE pattern | Calls | Service fields? |
|----------------|-------|-----------------|
| SET updated_at | ~1,275K | No |
| SET msg_can_write/size/expire (write_message) | ~600K | No |
| SET msg_can_write/size/expire (try_del_*) | ~331K | No |
| SET msg_can_write/size/expire (try_del reset) | ~258K | No |
| SET sender_key | ~17K | No |
| SET msg_can_write/size/expire (delete_expired) | ~3K | No |
| **SET rcv_service_id** | **~101K** | **Yes** |
| **SET deleted_at** | **~10K** | **Yes** |

**Fix**: Add `WHEN` clause — evaluated in C by PostgreSQL, skips function call entirely:

```sql
CREATE TRIGGER tr_queue_update
AFTER UPDATE ON msg_queues
FOR EACH ROW
WHEN (
  OLD.deleted_at IS DISTINCT FROM NEW.deleted_at
  OR OLD.rcv_service_id IS DISTINCT FROM NEW.rcv_service_id
  OR OLD.ntf_service_id IS DISTINCT FROM NEW.ntf_service_id
  OR OLD.notifier_id IS DISTINCT FROM NEW.notifier_id
)
EXECUTE PROCEDURE on_queue_update();
```

**Verification**:
- PostgreSQL supports `OLD`/`NEW` in `WHEN` for `AFTER UPDATE` triggers.
- 4 conditions match exactly the fields checked inside `on_queue_update()`.
- Behavioral change: **none**.

**Savings**: ~2.5M PL/pgSQL calls avoided. Per-call overhead estimated ~0.02–0.05ms.
Total: ~50–125s estimated, not measured.

---

## Needs EXPLAIN ANALYZE

### 4. Partial indexes for getEntityCounts ① and ②

After fix #1, subqueries ① and ② remain. ② has no index covering both
`deleted_at IS NULL` and `notifier_id IS NOT NULL`.

```sql
CREATE INDEX idx_msg_queues_live ON msg_queues ((1)) WHERE deleted_at IS NULL;
CREATE INDEX idx_msg_queues_live_notifier ON msg_queues ((1)) WHERE deleted_at IS NULL AND notifier_id IS NOT NULL;
```

**Trade-off**: Write overhead on every INSERT/UPDATE/DELETE. Need `EXPLAIN ANALYZE`
to confirm PostgreSQL uses these for COUNT vs choosing seq scan.

---

## Not problems

- **write_message / try_del_peek_msg** (ranks #2-3): 0.5-0.7ms avg. High total from volume (~600K calls).
  Max spikes (490-523ms) are lock contention on `FOR UPDATE` — architectural, not fixable.

- **UPDATE SET updated_at** (rank #5): 0.17ms avg, ~1.3M calls. Already minimal.
  Fix #3 eliminates the trigger overhead on these.

- **SET rcv_service_id** (Server C only, 100K calls): CSV shows rows_affected = calls — all
  legitimate associations. Haskell guard at `Postgres.hs:487` works correctly.

- **Batch lookups** (ranks #8-9): 1.8-2.0ms avg for ~135 PK probes. Near-optimal.

---

## Summary

| # | Fix | Per-call savings | Calls | Total savings | Verified |
|---|-----|-----------------|-------|---------------|----------|
| 1 | getEntityCounts ③④ → `SUM(queue_count)` | 0–158ms (unknown split) | ~5,050 | 0–800s | Correctness: yes. Savings: needs EXPLAIN ANALYZE |
| 2 | Remove trailing COUNTs from expire_old_messages | 641–805ms | 21 | 13.5–16.9s | Yes (CSV) |
| 3 | Add WHEN clause to tr_queue_update | ~0.02–0.05ms | ~2.5M skipped | ~50–125s est. | Correctness: yes. Savings: estimated |
| 4 | Partial indexes for ①② | Unknown | ~5,050 | Unknown | Needs EXPLAIN ANALYZE |
