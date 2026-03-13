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
