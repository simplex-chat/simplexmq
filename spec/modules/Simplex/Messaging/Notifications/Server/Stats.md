# Simplex.Messaging.Notifications.Server.Stats

> NTF server statistics collection with own-server breakdown and backward-compatible persistence.

**Source**: [`Notifications/Server/Stats.hs`](../../../../../../src/Simplex/Messaging/Notifications/Server/Stats.hs)

## Non-obvious behavior

### 1. incServerStat double lookup

`incServerStat` performs a non-STM IO lookup first. On cache hit, the STM transaction only touches the per-server `TVar Int` without reading the shared TMap, avoiding contention. On cache miss, the STM block re-checks the map to handle races (another thread may have inserted between the IO lookup and STM entry).

### 2. setNtfServerStats is not thread safe

`setNtfServerStats` is explicitly documented as non-thread-safe and intended for server startup only (restoring from backup file).

### 3. Backward-compatible parsing

The `strP` parser uses `opt` which defaults missing fields to 0. This allows reading stats files from older server versions that don't include newer fields (`ntfReceivedAuth`, `ntfFailed`, `ntfVrf*`, etc.).

### 4. getNtfServerStatsData is a non-atomic snapshot

`getNtfServerStatsData` reads each `IORef` and `TMap` field sequentially in plain `IO`, not inside a single STM transaction. The returned `NtfServerStatsData` is not a consistent point-in-time snapshot — invariants like "received >= delivered" may not hold. The same applies to `getStatsByServer`, which does one `readTVarIO` for the map root TVar, then a separate `readTVarIO` for each per-server TVar. This is acceptable for periodic reporting where approximate consistency suffices.

### 5. Mixed IORef/TVar concurrency primitives

Aggregate counters (`ntfReceived`, `ntfDelivered`, etc.) use `IORef Int` incremented via `atomicModifyIORef'_`, while per-server breakdowns use `TMap Text (TVar Int)` incremented atomically via STM in `incServerStat`. Although both individual operations are atomic, the aggregate and per-server increments are separate operations, so their values can drift: a thread could increment the aggregate `IORef` before `incServerStat` runs, or vice versa.

### 6. setStatsByServer replaces TMap atomically but orphans old TVars

`setStatsByServer` builds a fresh `Map Text (TVar Int)` in IO via `newTVarIO`, then atomically replaces the TMap's root TVar. Old per-server TVars are not reused — any other thread holding a reference from a prior `TM.lookupIO` would modify an orphaned counter. Safe only because it's called at startup (like `setNtfServerStats`), but lacks the explicit "not thread safe" comment.

### 7. Positional parser format despite key=value appearance

The parser is strictly positional: fields must appear in exactly the serialization order. The `opt` alternatives only handle entirely absent fields (defaulting to 0), not reordered fields. Despite the `key=value` on-disk appearance, this is a sequential format — the named prefixes are for human readability, not key-lookup parsing.

### 8. B.unlines trailing newline asymmetry

`strEncode` uses `B.unlines`, which appends `\n` after every element including the last. The parser compensates with `optional A.endOfLine` on the last field. The file always ends with `\n`, but the parser tolerates its absence.
