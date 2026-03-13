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

New notifications are prepended to the `NonEmpty PNMessageData` list via `(<|)`.

### 5. stmDeleteNtfToken prunes empty registration maps

When `stmDeleteNtfToken` removes a token, it deletes the entry from the inner `TMap` of `tokenRegistrations`, then checks whether that inner map is now empty via `TM.null`. If empty, it removes the outer `DeviceToken` key entirely, preventing unbounded growth of empty inner maps. In contrast, `stmRemoveInactiveTokenRegistrations` does **not** perform this cleanup — the surviving active token's registration always remains.

### 6. stmRemoveTokenRegistration is identity-guarded

`stmRemoveTokenRegistration` looks up the registration entry for the token's own verify key and only deletes it if the stored `NtfTokenId` matches the token's own ID. This guard prevents a token from accidentally removing a **different** token's registration that was inserted under the same `(DeviceToken, verifyKey)` pair due to a re-registration race.

### 7. stmDeleteNtfToken silently succeeds on missing tokens

`stmDeleteNtfToken` uses `lookupDelete` chained with monadic bind over `Maybe`. If the token ID does not exist in the `tokens` map, the registration-cleanup branch is silently skipped, and the function still proceeds to delete from `tokenLastNtfs` and `deleteTokenSubs`. It returns an empty list rather than signaling an error — the caller cannot distinguish "deleted a token with no subscriptions" from "token never existed."

### 8. deleteTokenSubs returns SMP queues for upstream unsubscription

`deleteTokenSubs` atomically collects all `SMPQueueNtf` values from the deleted subscriptions and returns them. This is how the router layer knows which SMP notifier subscriptions to tear down. `stmRemoveInactiveTokenRegistrations` discards this list (`void $`), meaning rival-token cleanup does **not** trigger SMP unsubscription — only explicit token deletion does.

### 9. stmAddNtfSubscription always returns Just (vestigial Maybe)

`stmAddNtfSubscription` has return type `STM (Maybe ())` with a comment "return Nothing if subscription existed before," but **unconditionally returns `Just ()`**. `TM.insert` overwrites any existing subscription silently. The `Maybe` return type is vestigial — the function never detects duplicates.

### 10. stmDeleteNtfSubscription leaves empty tokenSubscriptions entries

When `stmDeleteNtfSubscription` removes a subscription, it deletes the `subId` from the token's `Set NtfSubscriptionId` in `tokenSubscriptions` but never checks whether the set became empty. Tokens with all subscriptions individually deleted accumulate empty set entries — these are only cleaned up when the token itself is deleted via `deleteTokenSubs`.

### 11. stmSetNtfService — key-value service association

`stmSetNtfService` uses `maybe TM.delete TM.insert` to either remove or set the service association for an SMP router. This is purely a key-value update with no cascading effects on subscriptions.

### 12. Subscription index triple-write invariant

`stmAddNtfSubscription` writes to three maps atomically: `subscriptions` (subId → data), `subscriptionLookup` (smpQueue → subId), and `tokenSubscriptions` (tokenId → Set subId). Single-subscription deletion (`stmDeleteNtfSubscription`) cleans the first two but only removes from the Set in the third. Bulk-token deletion (`deleteTokenSubs`) deletes the outer `tokenSubscriptions` entry entirely. Different deletion paths have different completeness guarantees.
