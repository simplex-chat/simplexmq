# Simplex.Messaging.Server.NtfStore

> In-memory notification store: per-notifier message notification lists with expiration.

**Source**: [`NtfStore.hs`](../../../../../src/Simplex/Messaging/Server/NtfStore.hs)

## storeNtf — outside-STM lookup with STM fallback

`storeNtf` uses `TM.lookupIO` outside STM, then falls back to `TM.lookup` inside STM if the notifier entry doesn't exist. This is the same outside-STM lookup pattern used in the router (`Server.hs`) and `Client/Agent.hs` — avoids transaction re-evaluation from unrelated map changes. The double-check inside STM prevents races when two messages arrive concurrently for a new notifier.

## deleteExpiredNtfs — last-is-earliest optimization

Notifications are prepended (cons), so the last element in the list is the earliest. `deleteExpiredNtfs` checks `last ntfs` first — if the earliest notification is not expired, none are, and the entire list is skipped without filtering. This avoids traversing notification lists that have no expired entries.

The outer `readTVarIO` check for empty list avoids entering an STM transaction at all for notifiers with no notifications.
