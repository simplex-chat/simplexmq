# Simplex.Messaging.Server.QueueStore.Postgres

> PostgreSQL queue store: cache-coherent TMap layer over database, double-checked locking, soft-delete lifecycle, COPY-based bulk import.

**Source**: [`Postgres.hs`](../../../../../../src/Simplex/Messaging/Server/QueueStore/Postgres.hs)

## addQueue_ — no in-memory duplicate check, relies on DB constraint

See comment on `addQueue_`: "Not doing duplicate checks in maps as the probability of duplicates is very low." The Postgres implementation relies on `UniqueViolation` from the DB rather than pre-checking in-memory maps.

## addQueue_ — non-atomic cache updates

After the successful SQL INSERT, each cache map (`queues`, `senders`, `notifiers`, `links`) is updated in its own `atomically` block. Between these updates, the cache is partially consistent — a concurrent `getQueue_` by sender ID could miss the queue during the window between the `queues` insert and the `senders` insert. The STM implementation updates all maps in a single `atomically` block. `E.uninterruptibleMask_` prevents async exceptions but not concurrent reads.

## getQueue_ / SNotifier — one-shot cache eviction on read

See comment on `getQueue_` for the SNotifier case. After a successful notifier lookup, the notifier ID is deleted from the `notifiers` TMap. This makes the notifier cache a one-shot cache: the first lookup uses the cache, subsequent lookups hit the database. Unique to SNotifier — SSender entries persist indefinitely. The batch path (`getQueues_` SNotifier) does NOT do this eviction, so single and batch paths have different cache side effects.

## getQueue_ / loadNtfQueue — notifier lookups never cache the queue

See comment on `loadNtfQueue`: "checking recipient map first, not creating lock in map, not caching queue." Notifier-initiated DB loads produce ephemeral queue objects created with `mkQ False` (no persistent lock). Two concurrent notifier lookups for the same queue create independent queue objects with separate `TVar`s. Contrast with `loadSndQueue_` which caches via `cacheQueue`.

## cacheQueue — double-checked locking

Classic pattern: (1) TMap lookup outside lock, (2) if miss, DB load + create queue + acquire `withQueueLock`, (3) second TMap check inside lock + `atomically`, (4) if another thread won the race, discard the freshly created queue. See comment on `cacheQueue` for the rationale about preventing duplicate file opens. For Journal storage, the losing thread's lock remains in `queueLocks` as a harmless orphan. For Postgres-only storage (`mkQueue` creates a TVar), no resource leak.

## getQueues_ — snapshot-based cache with stale-read risk

Both SRecipient and SNotifier paths start with `readTVarIO` snapshots of the relevant TMap(s), then partition requested IDs into "found" and "need DB load." Between snapshot and DB query, the cache can change. The `cacheRcvQueue` path handles this with a second check inside the lock. The SNotifier path does NOT cache — it uses the stale snapshot to decide `maybe (mkQ False rId qRec) pure (M.lookup rId qs)`, so concurrent loads can create duplicate ephemeral objects.

## getQueues_ — error code asymmetry: INTERNAL vs AUTH

When all IDs are found in cache but some map to `Left` (theoretically impossible), the error is `INTERNAL`. When some IDs needed DB loading and were missing, the error is `AUTH`. Same "not found" condition, different error codes depending on whether the DB was consulted. The `INTERNAL` branch is a defensive assertion against inconsistent TMap snapshots.

## withDB — every operation runs in its own transaction

`withDB` wraps each action in `withTransaction` (PostgreSQL `READ COMMITTED`). No multi-statement transactions in queue store operations (unlike `getEntityCounts` and `batchInsertQueues` which use `withTransaction` directly). SQL exceptions are caught, logged, and mapped to `STORE` with the exception text — which propagates to the SMP client over the wire.

## withQueueRec — lock-mask-read pattern

All mutating operations share: (1) `withQueueLock` (per-queue lock), (2) `E.uninterruptibleMask_` (no async exceptions mid-operation), (3) `readQueueRecIO` (check queue not deleted). If the TVar reads `Nothing`, the operation short-circuits with `AUTH` without touching the database. The TVar is the authoritative "is deleted" check; `assertUpdated` (zero rows → `AUTH`) catches cache-DB divergence as a secondary check.

## deleteStoreQueue — two-phase soft delete

Queue deletion is soft: `UPDATE ... SET deleted_at = ?`. The row remains in the database. `compactQueues` later does the hard delete: `DELETE ... WHERE deleted_at < ?` using the configurable `deletedTTL`. All queries include `AND deleted_at IS NULL` to exclude soft-deleted rows. The STM implementation has no equivalent — `compactQueues` returns `pure 0`.

## deleteStoreQueue — non-atomic cache cleanup, links never cleaned

The TVar is set to `Nothing` first, then secondary maps (`senders`, `notifiers`, `notifierLocks`) are cleaned in separate `atomically` blocks. Between these, secondary maps point to a dead queue (functionally correct — returns AUTH either way). The `links` map is never cleaned up here — link entries for deleted queues remain in memory indefinitely.

## secureQueue — idempotency difference from STM

Re-securing with the same key falls through the verify function to `pure ()`, then **still executes the SQL UPDATE and TVar write**. The STM implementation returns `Right ()` without TVar mutation when the same key is provided. Both implementations write a store log entry either way. The Postgres version performs an unnecessary DB round-trip, connection pool checkout, and TVar write that the STM version avoids.

## addQueueNotifier — three-layer duplicate detection

(1) **Cache check**: `checkCachedNotifier` acquires a per-notifier-ID lock via `notifierLocks`, then checks `TM.memberIO`. Returns `DUPLICATE_`. (2) **Queue lock**: Via `withQueueRec`, prevents concurrent modifications to the same queue. (3) **Database constraint**: `handleDuplicate` catches `UniqueViolation`, returns `AUTH`. Same duplicate, different error codes depending on whether cache was warm. The `notifierLocks` map grows unboundedly — locks are never removed except when the queue is deleted.

## rowToQueueRec — link data replaced with empty stubs

The standard `queueRecQuery` does NOT select `fixed_data` and `user_data` columns. When converting to `QueueRec`, link data is stubbed: `(,(EncDataBytes "", EncDataBytes "")) <$> linkId_`. Actual link data is loaded on demand via `getQueueLinkData`. Any code reading `queueData` from a cached `QueueRec` without going through `getQueueLinkData` sees empty bytes. The separate `rowToQueueRecWithData` (used by `foldQueueRecs` with `withData = True`) includes real data.

## getCreateService — serialization via serviceLocks

Entire operation wrapped in `withLockMap (serviceLocks st) fp`, serializing all creation/lookup for the same certificate fingerprint. Inside the lock: SELECT by `service_cert_hash`, if not found attempt INSERT catching `UniqueViolation`.

## batchInsertQueues — COPY protocol with manual CSV serialization

Uses PostgreSQL's `COPY FROM STDIN WITH (FORMAT CSV)` for bulk import. Queue records manually serialized via `queueRecToText`/`renderField`. This must stay in sync with `insertQueueQuery` column order — a mismatch causes silent data corruption. The `renderField` function does not escape CSV metacharacters, which is safe only because field values (entity IDs, keys, DH secrets) are binary data without commas/quotes/newlines. Runs in a single transaction; row count queried in a separate transaction afterward.

## withLog_ — fire-and-forget store log writes

`withLog_` catches all exceptions via `catchAny` and logs a warning, but does not fail the operation. Store log writes are best-effort. Contrast with the STM `withLog'` where log failures can propagate as `STORE` errors. In the Postgres implementation, the store log can fall behind the database state since the DB is the authoritative persistence layer.

## useCache flag — behavioral bifurcation

`useCache :: Bool` creates two distinct code paths. When `False`: `addQueue_` skips all TMap updates, `getQueue_` always loads from DB, `addQueueNotifier` skips cache duplicate check, `deleteStoreQueue` skips cache cleanup. Notably, `loadQueueNoCache` still creates queues with `mkQ True` (persistent lock) even though caching is disabled — the lock is needed for `withQueueRec`'s `withQueueLock`.

## getServiceQueueCountHash — behavioral divergence from STM

Postgres returns `Right (0, mempty)` when the service is not found (via `maybeFirstRow'` default). STM returns `Left AUTH`. Same logical condition, different error handling. Callers that expect AUTH on missing service will silently get a zero count from Postgres.

## deleteStoreQueue — cross-module lock contract

See comment on `deleteStoreQueue`: "this method is called from JournalMsgStore deleteQueue that already locks the queue." Unlike other mutations that go through `withQueueRec` (which acquires the lock), `deleteStoreQueue` uses `E.uninterruptibleMask_ $ runExceptT` directly — no `withQueueLock`. The caller must hold the lock.

## addQueueLinkData — immutable data protection

When link data already exists with the same `lnkId`, the SQL UPDATE adds `AND (fixed_data IS NULL OR fixed_data = ?)` to prevent overwriting immutable (fixed) data. If the immutable portion doesn't match, `assertUpdated` triggers AUTH. This enforces the invariant that `fixed_data` can only be set once.

## assertUpdated — AUTH is overloaded

`assertUpdated` checks that non-zero rows were affected. Zero rows → `AUTH`. This is the same error code returned for "not found" (via `readQueueRecIO`) and "duplicate" (via `handleDuplicate`). The actual cause — stale cache, deleted queue, or constraint violation — is indistinguishable in logs.
