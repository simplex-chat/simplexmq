# Simplex.Messaging.Notifications.Server.Store

> STM-based in-memory store for notification tokens, subscriptions, and last-notification accumulation.

**Source**: [`Notifications/Server/Store.hs`](../../../../../../src/Simplex/Messaging/Notifications/Server/Store.hs)

## Non-obvious behavior

### 1. Two-level token registration index

`tokenRegistrations` uses a nested TMap: `DeviceToken -> TMap ByteString NtfTokenId`, where the inner key is the serialized verify key. This allows **multiple concurrent registrations** per device token (with different keys), protecting against malicious registration attempts if a token is compromised. The inner key is derived via `C.toPubKey C.pubKeyBytes`.

### 2. stmRemoveInactiveTokenRegistrations cleans up rivals

When a token is activated, `stmRemoveInactiveTokenRegistrations` removes ALL other registrations for the same device token, including their token records, last notifications, and all subscriptions. Only the activating token's registration survives.

### 3. stmStoreTokenLastNtf guards against stale tokens

`stmStoreTokenLastNtf` performs a non-STM IO lookup first, then enters STM. Within the STM block, it re-checks the map to handle the race where another thread modified the map between the IO lookup and STM entry. It only inserts for tokens that exist in the `tokens` map — stale token IDs are silently ignored.

### 4. tokenLastNtfs accumulates via prepend

New notifications are prepended to the `NonEmpty PNMessageData` list via `(<|)`. The list is unbounded in the STM store — bounding is handled at the push delivery layer (the Postgres store limits to 6).
