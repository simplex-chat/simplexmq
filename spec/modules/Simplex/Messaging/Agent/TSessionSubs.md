# Simplex.Messaging.Agent.TSessionSubs

> Per-session subscription state machine tracking active and pending queue subscriptions.

**Source**: [`Agent/TSessionSubs.hs`](../../../../../src/Simplex/Messaging/Agent/TSessionSubs.hs)

## Overview

TSessionSubs manages the two-tier (active/pending) subscription state for SMP queues, keyed by transport session. Every subscription confirmation from a router is validated against the current session ID before being promoted to active — if the session has changed (reconnect happened), the subscription is demoted to pending for resubscription.

Service subscriptions (aggregate, router-managed) and queue subscriptions (individual, per-recipient-ID) are tracked separately but follow the same active/pending pattern.

**Consumed by**: [Agent/Client.hs](./Client.md) — `subscribeSMPQueues`, `subscribeSessQueues_`, `resubscribeSMPSession`, `smpClientDisconnected`.

## Session ID gating

The central invariant: a subscription is only active if it was confirmed on the *current* TLS session. Every function that promotes subscriptions to active (`addActiveSub'`, `batchAddActiveSubs`, `setActiveServiceSub`) checks `Just sessId == sessId'` (stored session ID). On mismatch, the subscription goes to pending instead — silently, with no error.

This means subscription RPCs that succeed but return after a reconnect are safely caught: the result carries the old session ID, which won't match the new one stored by `setSessionId`.

## setSessionId — silent demotion on reconnect

`setSessionId` has two behaviors:
- **First call** (stored is `Nothing`): stores the session ID. No side effects.
- **Subsequent call with different ID**: calls `setSubsPending_`, which moves *all* active subscriptions to pending and demotes the active service subscription. The new session ID is stored.
- **Same ID**: no-op (the `unless` guard).

This is the mechanism by which reconnection invalidates all prior subscriptions. Callers don't need to explicitly move subscriptions — setting the new session ID does it atomically.

## addActiveSub' — service-associated queue elision

When `serviceId_` is `Just` and `serviceAssoc` is `True`, the queue is **not** added to `activeSubs`. Instead, `updateActiveService` increments the service subscription's count and XORs the queue's `IdsHash`. The queue is also removed from `pendingSubs`.

This means service-associated queues have no individual representation in `activeSubs` — they exist only as aggregated count + hash in `activeServiceSub`. The router tracks them via the service subscription; the agent doesn't need per-queue state.

When `serviceAssoc` is `False` (or no service ID), the queue goes to `activeSubs` normally.

## updateActiveService — accumulative XOR merge

`updateActiveService` adds to an existing `ServiceSub` rather than replacing it. It increments the queue count (`n + addN`) and appends the IdsHash (`idsHash <> addIdsHash`). The `<>` on `IdsHash` is XOR — this means the hash is order-independent and can be built incrementally as individual subscription confirmations arrive.

The guard `serviceId == serviceId'` silently drops updates if the service ID has changed (e.g., credential rotation happened between individual queue confirmations).

## setSubsPending — mode-dependent redistribution

`setSubsPending` handles two cases based on whether the transport session mode (entity vs shared) matches the session key shape:

1. **Mode matches key shape** (`entitySession == isJust connId_`): in-place demotion via `setSubsPending_` — active subs move to pending within the same `SessSubs` entry. Session ID is cleared (`Nothing`).

2. **Mode mismatch** (e.g., switching from shared session to entity mode): the entire `SessSubs` entry is **deleted** from the map (`TM.lookupDelete`), and all subscriptions are redistributed to new per-entity session keys via `addPendingSub (uId, srv, sessEntId (connId rq))`. This changes the map granularity — one shared entry becomes many entity entries.

Both paths check `Just sessId == sessId'` first — if the stored session ID doesn't match the one being invalidated, no work is done (returns empty).

## getSessSubs — lazy initialization

`getSessSubs` creates a new `SessSubs` entry if none exists for the transport session. This means any write operation (`addPendingSub`, `setSessionId`, etc.) will create map entries as a side effect. Read operations (`hasActiveSub`, `getActiveSubs`) use `lookupSubs` instead, which returns `Nothing`/empty without creating entries.

## updateClientNotices

Adjusts the `clientNoticeId` field on pending subscriptions in bulk. Uses `M.adjust`, so missing recipient IDs are silently skipped. Only modifies pending subs — active subs are not touched because they've already been confirmed.
