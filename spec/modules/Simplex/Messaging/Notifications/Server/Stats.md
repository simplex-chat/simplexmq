# Simplex.Messaging.Notifications.Server.Stats

> NTF server statistics collection with own-server breakdown and backward-compatible persistence.

**Source**: [`Notifications/Server/Stats.hs`](../../../../../../src/Simplex/Messaging/Notifications/Server/Stats.hs)

## Non-obvious behavior

### 1. incServerStat double lookup

`incServerStat` performs a non-STM IO lookup first, then only enters an STM transaction on cache miss. The STM block re-checks the map to handle races (another thread may have inserted between the IO lookup and STM entry). This avoids contention on the shared TMap in the common case where the server's counter TVar already exists.

### 2. setNtfServerStats is not thread safe

`setNtfServerStats` is explicitly documented as non-thread-safe and intended for server startup only (restoring from backup file).

### 3. Backward-compatible parsing

The `strP` parser uses `opt` which defaults missing fields to 0. This allows reading stats files from older server versions that don't include newer fields (`ntfReceivedAuth`, `ntfFailed`, `ntfVrf*`, etc.).
