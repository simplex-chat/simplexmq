# SMP Server Postgres: Slow Query Analysis

Data from three production servers (A, B, C) over a multi-day observation window.

## Verified fixes

### 1. getEntityCounts: replace ③④ with SUM(queue_count)

**Query** (`QueueStore/Postgres.hs:160-167`):

```sql
SELECT
  (SELECT COUNT(1) FROM msg_queues WHERE deleted_at IS NULL) AS queue_count,                                            -- ① scan
  (SELECT COUNT(1) FROM msg_queues WHERE deleted_at IS NULL AND notifier_id IS NOT NULL) AS notifier_count,              -- ② scan
  (SELECT COUNT(1) FROM services WHERE service_role = ?) AS rcv_service_count,                                           -- trivial (<10 rows)
  (SELECT COUNT(1) FROM services WHERE service_role = ?) AS ntf_service_count,                                           -- trivial (<10 rows)
  (SELECT COUNT(1) FROM msg_queues WHERE rcv_service_id IS NOT NULL AND deleted_at IS NULL) AS rcv_service_queues_count,  -- ③ scan
  (SELECT COUNT(1) FROM msg_queues WHERE ntf_service_id IS NOT NULL AND deleted_at IS NULL) AS ntf_service_queues_count   -- ④ scan
```

**Performance**: ~315ms avg, ~2s max, ~2500 calls. #1 slow query by total time (~800s).

**Problem**: 4 scans of `msg_queues`. Indexes exist for some subqueries
(`idx_msg_queues_rcv_service_id(rcv_service_id, deleted_at)` for ③,
`idx_msg_queues_ntf_service_id(ntf_service_id, deleted_at)` for ④,
`idx_msg_queues_updated_at_recipient_id(deleted_at, ...)` potentially for ①),
but whether PostgreSQL uses them for COUNT and the actual per-subquery cost is
unknown without `EXPLAIN ANALYZE`.

**Fix**: Replace ③ and ④:

```sql
COALESCE((SELECT SUM(queue_count) FROM services WHERE service_role = 'M'), 0) AS rcv_service_queues_count,
COALESCE((SELECT SUM(queue_count) FROM services WHERE service_role = 'N'), 0) AS ntf_service_queues_count
```

**Verification**:
- Trigger logic traced for all transitions (NULL→set, change, soft-delete, physical delete) — correct.
- FK `rcv_service_id REFERENCES services(service_id)` guarantees every non-NULL value maps to a row.
- `queue_count + p_change` is atomic under READ COMMITTED — concurrent-safe.
- `update_all_aggregates()` exists as repair mechanism.
- `services` table has <10 rows — SUM is O(1) vs full table scan.

**Savings**: Eliminates 2 of 4 msg_queues scans (③④ → trivial SUM on <10 rows).
Exact savings unknown — if ③④ already use indexes efficiently, savings may be modest.
`EXPLAIN ANALYZE` needed to measure actual per-subquery cost.

---

### 2. expire_old_messages: remove trailing COUNTs

**Stored procedure** (`Migrations.hs`), at the end of `expire_old_messages`:

```sql
r_expired_msgs_count := total_deleted;
r_stored_msgs_count := (SELECT COUNT(1) FROM messages);           -- 13-114ms per call (CSV)
r_stored_queues := (SELECT COUNT(1) FROM msg_queues WHERE deleted_at IS NULL);  -- 544-719ms per call (CSV)
```

**Performance**: 10 calls per observation window. Per-call cost of these COUNTs (from CSV):

| Server | expire_old_messages avg | r_stored_queues avg | r_stored_msgs avg | COUNTs combined | % of procedure |
|---|---|---|---|---|---|
| A | 11,798ms | 719ms | 114ms | 833ms | 7.1% |
| B | 11,242ms | 544ms | 13ms | 557ms | 5.0% |
| C | 7,296ms | 588ms | 67ms | 655ms | 9.0% |

**How results are used** (`Server.hs:485-488`):

```haskell
Right msgStats@MessageStats {storedMsgsCount = stored, expiredMsgsCount = expired} -> do
  atomicWriteIORef (msgCount stats) stored     -- resets msgCount from storedMsgsCount
  atomicModifyIORef'_ (msgExpired stats) (+ expired)
  printMessageStats "STORE: messages" msgStats  -- logs all three fields
```

- `expiredMsgsCount` — computed incrementally in the loop. **Needed, already cheap.**
- `storedMsgsCount` — used to reset `msgCount` stat. But `msgCount` is also maintained
  incrementally (`+1` on send at line 1963, `-1` on ACK at line 1916). The reset corrects drift.
- `storedQueues` — **used only for logging**. Same value available from `getEntityCounts`
  which runs every ~60s via Prometheus.

**Fix**: Remove both COUNTs from the stored procedure. Return only `r_expired_msgs_count`.

For `storedMsgsCount`: either trust the incremental `msgCount` counter, or query
`SELECT COUNT(1) FROM messages` separately (in parallel, not blocking the procedure).

For `storedQueues`: use the value from the most recent `getEntityCounts` call.

**Verification**: Traced all usages of `MessageStats` fields from `expireOldMessages` in
`Server.hs`. `storedQueues` is only logged. `storedMsgsCount` resets a counter that's already
maintained incrementally — removing the reset means potential drift, but the counter is
corrected on next server restart anyway.

**Savings**: 560-830ms per expiration cycle × 10 cycles = **5.6-8.3s total** over observation window.

---

### 3. Trigger WHEN clause: skip function call for non-service updates

**Current trigger** (`Migrations.hs:566-568`):

```sql
CREATE TRIGGER tr_queue_update
AFTER UPDATE ON msg_queues
FOR EACH ROW EXECUTE PROCEDURE on_queue_update();
```

Fires on **every UPDATE** to `msg_queues`. From Server C data, ~1.2M updates per observation
window, but only ~105K (8.7%) actually change service-related fields:

| UPDATE pattern | Calls | Changes service fields? |
|---|---|---|
| SET updated_at | ~427K | No |
| SET msg_can_write/size/expire (write_message) | ~336K | No |
| SET msg_can_write/size/expire (try_del_*) | ~196K | No |
| SET msg_can_write/size/expire (delete_expired) | ~136K | No |
| SET sender_key | ~8K | No |
| SET status | ~2K | No |
| **SET rcv_service_id** | **~101K** | **Yes** |
| **SET deleted_at** | **~5K** | **Yes** |

The `on_queue_update()` PL/pgSQL function evaluates 8-12 boolean conditions on every call,
then returns without calling `update_aggregates` for 91% of invocations.

**Fix**: Add a `WHEN` clause to the trigger definition. PostgreSQL evaluates `WHEN` in C code
before calling the PL/pgSQL function — no function entry overhead at all:

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
- PostgreSQL supports `OLD`/`NEW` in `WHEN` clauses for `AFTER UPDATE` triggers.
- The 4 conditions match exactly the fields checked inside `on_queue_update()`.
- When WHEN is false, the function is **never called** — zero PL/pgSQL overhead.
- When WHEN is true, the function runs identically to today.
- Behavioral change: **none** — same aggregates updated in same cases.

**Savings**: ~1.1M PL/pgSQL function calls avoided. Each call has fixed overhead
(function entry, OLD/NEW row extraction, condition evaluation, return). Exact savings
need measurement, but function call overhead is non-trivial at this volume.

---

## Fixes that need EXPLAIN ANALYZE

### 4. Partial indexes for getEntityCounts ① and ②

Subqueries ① and ② still scan msg_queues. ① may use
`idx_msg_queues_updated_at_recipient_id(deleted_at, ...)` but ② has no index covering
both `deleted_at IS NULL` and `notifier_id IS NOT NULL`. Actual plans unknown.

Candidate indexes:

```sql
-- For ① queue_count: enables index-only COUNT
CREATE INDEX idx_msg_queues_live ON msg_queues ((1)) WHERE deleted_at IS NULL;

-- For ② notifier_count: enables index-only COUNT
CREATE INDEX idx_msg_queues_live_notifier ON msg_queues ((1)) WHERE deleted_at IS NULL AND notifier_id IS NOT NULL;
```

**Trade-off**: Each index adds write overhead on every INSERT/UPDATE/DELETE touching the
filtered columns. Need `EXPLAIN ANALYZE` to confirm the COUNT actually uses the index
(PostgreSQL may choose seq scan if the partial index covers most rows).

---

## Not fixable (architectural)

- **write_message / try_del_peek_msg max times (490-523ms)**: Lock contention on
  `FOR UPDATE` of the same `recipient_id` row. Inherent to concurrent queue access — cannot
  use `SKIP LOCKED` because these operations require the lock for correctness.

- **UPDATE msg_queues SET updated_at (~430K calls, 83-90s total, 0.20ms avg)**: Per-call cost
  is already minimal. Trigger does zero aggregate work for this pattern (verified — all
  IS DISTINCT FROM checks fail, no `update_aggregates` called). Fix #3 eliminates even
  the function call overhead.

---

## Summary

| # | Fix | Per-call savings | Calls | Total savings | Verified |
|---|-----|-----------------|-------|---------------|----------|
| 1 | getEntityCounts ③④ → `SUM(queue_count)` | 0–158ms (unknown split across 4 subqueries) | ~2,500 | 0–395s | Correctness: yes. Savings: needs EXPLAIN ANALYZE |
| 2 | Remove trailing COUNTs from expire_old_messages | 557–833ms (CSV-verified) | 10 | 5.6–8.3s | Yes (CSV verified) |
| 3 | Add WHEN clause to tr_queue_update | ~0.02–0.05ms (PL/pgSQL entry overhead estimate) | ~1.1M skipped | ~22–55s | Correctness: yes. Savings: estimated, not measured |
| 4 | Partial indexes for ①② | Unknown | ~2,500 | Unknown | No — needs EXPLAIN ANALYZE |
