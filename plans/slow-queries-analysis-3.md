# SMP Server Postgres: Slow Query Analysis (post-reset)

Data from three production servers (A, B, C), ~5.5 hour window after stats reset.
EXPLAIN ANALYZE from a large server (~30M rows in msg_queues).

## Top queries by total time

| Rank | Query | A total ms | B total ms | C total ms |
|------|-------|-----------|-----------|-----------|
| 1 | getEntityCounts (6 COUNT subqueries) | 99,799 | 101,946 | 121,495 |
| 2 | UPDATE SET updated_at | 35,799 | 30,797 | 26,551 |
| 3 | try_del_peek_msg() | 28,903 | 23,147 | 26,482 |
| 4 | write_message() | 23,103 | 18,942 | 20,301 |
| 5 | Batch recipient_id IN lookups | 16,062 | 12,529 | 9,977 |
| 6 | INSERT INTO messages | 14,395 | 11,911 | 12,882 |
| 7 | msg_peek (SELECT FROM messages) | 12,882 | 11,992 | 14,661 |
| 8 | expire_old_messages() | 9,762 | 11,619 | 10,863 |
| 9 | delete_expired_msgs() | 7,801 | 5,456 | 6,256 |
| 10 | expire batch cursor (array_agg) | 4,421 | 5,679 | 4,566 |

Grand totals: A ~292s, B ~317s, C ~288s.

getEntityCounts is **34-42%** of all query time across all three servers.

---

## EXPLAIN ANALYZE results for getEntityCounts

Run on a large server (~30M rows in msg_queues, cold cache):

| Subquery | Time | % of 23.4s | Plan | Rows scanned | Key detail |
|----------|------|-----------|------|-------------|------------|
| ① queue_count | **7,851ms** | **33.5%** | Parallel Seq Scan | 30.6M (97% match) | No useful index |
| ② notifier_count | **6,382ms** | **27.2%** | Parallel Seq Scan | 30.6M (4M match) | No useful index |
| ③ rcv_service_queues | 0.5ms | 0% | Index Only Scan | 0 rows | No rcv services on this server; similar cost to ④ on servers with rcv services |
| ④ ntf_service_queues | **8,914ms** | **38.0%** | Parallel Index Only Scan | 3.7M match | **2.7M heap fetches** |
| Services (③④) | 1.8ms | 0% | Index Only / Bitmap | 0 + 6 rows | Trivial |
| JIT + Planning | 1,341ms | 5.7% | — | — | JIT compilation overhead |
| **Total** | **23,440ms** | | | | |

The CSV averages (302-368ms) reflect warm-cache performance. This EXPLAIN is cold cache
(`shared read=3.4M` vs `shared hit=44K` — 98.7% read from disk).

---

## Verified fixes

### 1. getEntityCounts: replace ③④ with SUM(queue_count)

```sql
-- Current ③ and ④:
(SELECT COUNT(1) FROM msg_queues WHERE rcv_service_id IS NOT NULL AND deleted_at IS NULL)  -- ③: 0.5ms
(SELECT COUNT(1) FROM msg_queues WHERE ntf_service_id IS NOT NULL AND deleted_at IS NULL)  -- ④: 8,914ms

-- Fix:
COALESCE((SELECT SUM(queue_count) FROM services WHERE service_role = 'M'), 0)  -- ~0ms
COALESCE((SELECT SUM(queue_count) FROM services WHERE service_role = 'N'), 0)  -- ~0ms
```

**EXPLAIN ANALYZE confirmed**: ③ returns 0 rows (already free). ④ costs 8,914ms due to
Parallel Index Only Scan with 2.7M heap fetches on `idx_msg_queues_ntf_service_id`.

**Verification**:
- Trigger logic traced for all transitions (NULL→set, change, soft-delete, physical delete) — correct.
- FK `rcv_service_id REFERENCES services(service_id)` guarantees equivalence.
- `queue_count + p_change` is atomic under READ COMMITTED.
- `update_all_aggregates()` exists as repair mechanism.

**Savings**: ~8.9s cold cache (38% of query). Warm cache proportionally less but still dominant ④ cost.

---

### 2. getEntityCounts: partial indexes for ① and ②

```sql
CREATE INDEX idx_msg_queues_active ON msg_queues ((1)) WHERE deleted_at IS NULL;
CREATE INDEX idx_msg_queues_active_notifier ON msg_queues ((1)) WHERE deleted_at IS NULL AND notifier_id IS NOT NULL;
```

**EXPLAIN ANALYZE confirmed**: ① does Parallel Seq Scan (7,851ms), ② does Parallel Seq Scan (6,382ms).
No existing index is used for these subqueries despite `idx_msg_queues_updated_at_recipient_id`
having `deleted_at` as first column — PostgreSQL chose seq scan because 97% of rows match.

Partial indexes contain only matching rows, enabling fast index-only COUNT without scanning
the full table.

**Trade-off**: Write overhead on every INSERT/UPDATE/DELETE that changes `deleted_at` or
`notifier_id`. For the ~30M row table with ~300K updates per 5.5h, this is acceptable.

**Savings**: ~14.2s cold cache (61% of query). Combined with fix #1: **23.1s → ~1.3s** (JIT only).

---

### 3. expire_old_messages: remove trailing COUNTs

At the end of `expire_old_messages` (`Migrations.hs`):

```sql
r_stored_msgs_count := (SELECT COUNT(1) FROM messages);
r_stored_queues := (SELECT COUNT(1) FROM msg_queues WHERE deleted_at IS NULL);
```

| Server | expire avg | r_stored_queues | r_stored_msgs | COUNTs combined | % of procedure |
|--------|-----------|-----------------|---------------|-----------------|----------------|
| A | 9,762ms | 535ms | 50ms | 585ms | 6.0% |
| B | 11,619ms | 390ms | 12ms | 402ms | 3.5% |
| C | 10,863ms | 659ms | 25ms | 684ms | 6.3% |

**Usage** (`Server.hs:485-488`):
- `storedMsgsCount` → resets `msgCount` stat (also maintained incrementally: +1 on send, -1 on ACK).
- `storedQueues` → **only logged**. Same value available from `getEntityCounts`.

**Fix**: Remove both COUNTs. Return only `r_expired_msgs_count`.

**Verification**: All usages traced. `storedQueues` is only logged. `storedMsgsCount` resets
an incrementally-maintained counter — removing means potential drift, corrected on restart.

**Savings**: 402–684ms per cycle (CSV-verified).

---

### 4. Trigger WHEN clause: skip PL/pgSQL call for non-service updates

**Current** (`Migrations.hs:566-568`):

```sql
CREATE TRIGGER tr_queue_update
AFTER UPDATE ON msg_queues
FOR EACH ROW EXECUTE PROCEDURE on_queue_update();
```

Server C data — ~297K updates, only ~670 (0.2%) change service-related fields:

| UPDATE pattern | Calls | Service fields? |
|----------------|-------|-----------------|
| SET updated_at | ~213K | No |
| SET msg_can_write/size/expire (write_message) | ~40K | No |
| SET msg_can_write/size/expire (try_del_*) | ~27K | No |
| SET msg_can_write/size (try_del reset) | ~14K | No |
| SET sender_key | ~2K | No |
| **SET deleted_at** | **~563** | **Yes** |
| **ntf_service_id/notifier_id changes** | **~108** | **Yes** |

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

**Savings**: ~296K PL/pgSQL calls avoided (99.8% of trigger fires). Per-call overhead
estimated ~0.02–0.05ms. Total: ~6–15s estimated over this 5.5h window.

---

## Not problems

- **write_message / try_del_peek_msg**: 0.5-0.65ms avg. High total from volume. Max spikes are lock contention — architectural.
- **UPDATE SET updated_at**: 0.12-0.17ms avg. Fix #4 eliminates trigger overhead.
- **Batch lookups**: 1.7-2.6ms avg for ~135 PK probes. Near-optimal.

---

## Summary

| # | Fix | Savings | Verified |
|---|-----|---------|----------|
| 1 | getEntityCounts ③④ → `SUM(queue_count)` | ~8.9s/call cold, ④ eliminated (EXPLAIN ANALYZE) | Yes |
| 2 | Partial indexes for getEntityCounts ①② | ~14.2s/call cold, ①② eliminated (EXPLAIN ANALYZE) | Yes — plan confirmed, index benefit to verify after creation |
| 3 | Remove trailing COUNTs from expire_old_messages | 402–684ms/cycle (CSV) | Yes |
| 4 | Add WHEN clause to tr_queue_update | ~6–15s est. over 5.5h (296K calls skipped) | Correctness: yes. Savings: estimated |

Fixes #1 + #2 combined: getEntityCounts **23.4s → ~1.3s cold cache** (94% reduction).
