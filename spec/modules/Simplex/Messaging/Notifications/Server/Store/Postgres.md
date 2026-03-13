# Simplex.Messaging.Notifications.Server.Store.Postgres

> PostgreSQL-backed persistent store for notification tokens, subscriptions, and last-notification delivery.

**Source**: [`Notifications/Server/Store/Postgres.hs`](../../../../../../../src/Simplex/Messaging/Notifications/Server/Store/Postgres.hs)

## Non-obvious behavior

### 1. deleteNtfToken exclusive row lock

`deleteNtfToken` acquires `FOR UPDATE` on the token row before cascading deletes. This prevents concurrent subscription inserts for this token during the deletion window. The subscriptions are aggregated by SMP server and returned for in-memory subscription cleanup.

### 2. addTokenLastNtf atomic CTE

`addTokenLastNtf` executes a single SQL statement with three CTEs that atomically:
1. **Upserts** the new notification into `last_notifications` (one row per token+subscription)
2. **Collects** the most recent notifications for the token (limited to `maxNtfs = 6`)
3. **Deletes** any older notifications beyond the limit

This ensures the push notification always contains the most recent notifications across all of a token's subscriptions, with bounded storage.

### 3. setTokenActive cleans duplicate registrations

After activating a token, `setTokenActive` deletes all other tokens with the same `push_provider` + `push_provider_token` but different `token_id`. This cleans up incomplete or duplicate registration attempts.

### 4. setTknStatusConfirmed conditional update

Updates to `NTConfirmed` only if the current status is not already `NTConfirmed` or `NTActive`. This prevents downgrading an already-active token back to confirmed state when a delayed verification push arrives.

### 5. Silent token date tracking

`updateTokenDate` is called on every token read (`getNtfToken_`, `findNtfSubscription`, `getNtfSubscription`). It updates `updated_at` only when the current date differs from the stored date. This tracks token activity without explicit client action.

### 6. getServerNtfSubscriptions marks as pending

After reading subscriptions for resubscription, `getServerNtfSubscriptions` batch-updates their status to `NSPending`. This prevents the same subscriptions from being picked up by a concurrent resubscription pass — it acts as a "claim" mechanism.

Only non-service-associated subscriptions (`NOT ntf_service_assoc`) are returned for individual resubscription.

### 7. Approximate subscription count

`getEntityCounts` uses `pg_class.reltuples` for the subscription count instead of `count(*)`. This returns an approximate value from PostgreSQL's statistics catalog, avoiding a full table scan on potentially large subscription tables.

### 8. withFastDB vs withDB priority pools

`withFastDB` uses `withTransactionPriority ... True` to run on the priority connection pool. Client-facing operations (token registration, subscription commands) use the priority pool, while background operations (batch status updates, resubscription) use the regular pool.

### 9. Server upsert optimization

`addNtfSubscription` first tries a plain SELECT for the SMP server, then falls back to INSERT with ON CONFLICT only if the server doesn't exist. This avoids the upsert overhead in the common case where the server already exists.

### 10. Service association tracking

`batchUpdateSrvSubStatus` atomically updates both subscription status and `ntf_service_assoc` flag. When notifications arrive via a service subscription (`newServiceId` is `Just`), all affected subscriptions are marked as service-associated. `removeServiceAndAssociations` resets all subscriptions for a server to `NSInactive` with `ntf_service_assoc = FALSE`.

### 11. uninterruptibleMask_ wraps most store operations

`withDB_` and `withClientDB` wrap the database transaction in `E.uninterruptibleMask_`. This prevents async exceptions from interrupting a PostgreSQL transaction mid-flight, which could leave a connection in a half-committed state and corrupt the pool. Functions that take a raw `DB.Connection` parameter (`getNtfServiceCredentials`, `setNtfServiceCredentials`, `updateNtfServiceId`) operate within a caller-managed transaction and are not independently wrapped. `getUsedSMPServers` uses `withTransaction` directly (intentionally: it is expected to crash on error at startup).

### 12. Silent error swallowing with sentinel returns

`withDB_` catches all `SomeException`, logs the error, and returns `Left (STORE msg)` — callers never see database failures as exceptions. Additionally, `batchUpdateSrvSubStatus` and `batchUpdateSrvSubErrors` use `fromRight (-1)` to convert database errors into a `-1` count, and `withPeriodicNtfTokens` uses `fromRight 0`, making database failures indistinguishable from "zero results" at the call site.

### 13. getUsedSMPServers uncorrelated EXISTS

The `EXISTS` subquery in `getUsedSMPServers` has no join condition to the outer `smp_servers` table — it returns ALL servers if ANY subscription anywhere has a subscribable status. This is intentional for server startup: the server needs all SMP server records (including `ServiceSub` data) to rebuild in-memory state, and the EXISTS clause is a cheap guard against an empty subscription table.

### 14. Trigger-maintained XOR hash aggregates

Subscription insert, update, and delete trigger functions incrementally maintain `smp_notifier_count` and `smp_notifier_ids_hash` on `smp_servers` using XOR-based hash aggregation of MD5 digests. Every `batchUpdateSrvSubStatus` or cascade-delete from token deletion implicitly fires these triggers. The XOR hash is self-inverting: adding and removing the same notifier ID restores the previous hash. `updateNtfServiceId` resets these counters to zero when the service ID changes, invalidating the previous aggregate.

### 15. updateNtfServiceId asymmetric credential cleanup

Setting a new service ID preserves existing TLS credentials (`ntf_service_cert`, etc.) while only resetting aggregate counters. Setting service ID to `NULL` clears both credentials AND counters. In both cases, if a previous service ID existed, all subscription associations are reset first via `removeServiceAssociation_`, and a `logError` is emitted — treating a service ID change as anomalous.

### 16. Server upsert no-op DO UPDATE for RETURNING

The `insertServer` fallback uses `ON CONFLICT ... DO UPDATE SET smp_host = EXCLUDED.smp_host` — a no-op update solely to make `RETURNING smp_server_id` work. PostgreSQL's `ON CONFLICT DO NOTHING` does not support `RETURNING` for conflicting rows, so this pattern forces a row to always be "affected" and thus returnable. This handles races where two concurrent `addNtfSubscription` calls both miss the initial SELECT.

### 17. getNtfServiceCredentials FOR UPDATE serializes provisioning

`getNtfServiceCredentials` acquires `FOR UPDATE` on the server row even though it is a read operation. The caller needs to atomically check whether credentials exist and then set them in the same transaction. Without `FOR UPDATE`, two concurrent provisioning attempts could both see `Nothing` and both provision, resulting in credential mismatch.

### 18. deleteNtfToken string_agg with hex parsing

`deleteNtfToken` uses `string_agg(s.smp_notifier_id :: TEXT, ',')` to aggregate `BYTEA` notifier IDs into comma-separated text, then parses with `parseByteaString` which drops the `\x` prefix and hex-decodes. `mapMaybe` silently drops any IDs that fail hex decoding, which could mask data corruption.

### 19. withPeriodicNtfTokens streams with DB.fold

`withPeriodicNtfTokens` uses `DB.fold` to stream token rows one at a time through a callback that performs IO (sending push notifications), meaning the database transaction and connection are held open for the entire duration of all notifications. This is deliberately routed through the non-priority pool to avoid blocking client-facing operations.

### 20. Cursor-based pagination with byte-ordering

`getServerNtfSubscriptions` uses `subscription_id > ?` with `ORDER BY subscription_id LIMIT ?`. Since `subscription_id` is `BYTEA`, ordering is by raw byte comparison. The batch status update uses `FROM (VALUES ...)` pattern instead of `WHERE IN (...)`, and the `s.status != upd.status` guard prevents no-op writes from firing XOR hash triggers.
