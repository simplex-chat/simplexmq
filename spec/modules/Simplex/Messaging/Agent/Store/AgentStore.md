# Simplex.Messaging.Agent.Store.AgentStore

> Core CRUD operations for agent persistence — users, connections, queues, messages, ratchets, notifications, and file transfers.

**Source**: [`Agent/Store/AgentStore.hs`](../../../../../../src/Simplex/Messaging/Agent/Store/AgentStore.hs)

## Overview

At ~3700 lines, this is the largest module in the codebase. It implements all database operations for the agent, compiled with CPP for both SQLite and PostgreSQL backends. Most functions are straightforward SQL CRUD, but several patterns are non-obvious.

The module re-exports `withConnection`, `withTransaction`, `withTransactionPriority`, `firstRow`, `firstRow'`, `maybeFirstRow`, and `fromOnlyBI` from the backend-specific Common module.

## Dual-backend compilation

The module uses `#if defined(dbPostgres)` throughout. Key behavioral differences:
- **Row locking**: PostgreSQL uses `FOR UPDATE` on reads that precede writes (e.g., `getConnForUpdate`, `getRatchetForUpdate`, `retrieveLastIdsAndHashRcv_`). SQLite relies on its single-writer model instead.
- **Batch queries**: PostgreSQL uses `IN ?` with `In` wrapper for batch operations. SQLite falls back to per-row `forM` loops.
- **Constraint handling**: PostgreSQL uses `constraintViolation`, SQLite checks `SQL.ErrorConstraint`.

## getWorkItem / getWorkItems — worker store pattern

`getWorkItem` implements the store-side pattern for the [worker framework](../Client.md): `getId → getItem → markFailed`. If `getId` or `getItem` throws an IO exception, `handleWrkErr` wraps it as `SEWorkItemError` (via `mkWorkItemError`), which signals the worker to suspend rather than retry. This prevents crash loops on corrupt data.

`getWorkItems` extends this to batch work items, where each item failure is independent.

**Consumed by**: `getPendingQueueMsg`, `getPendingServerCommand`, `getNextNtfSubNTFActions`, `getNextNtfSubSMPActions`, `getNextDeletedSndChunkReplica`, `getNextNtfTokenToDelete`.

## Notification subscription — supervisor/worker coordination

`updateNtfSubscription`, `setNullNtfSubscriptionAction`, and `deleteNtfSubscription` all check `updated_by_supervisor` before writing. When `True`, the worker only updates local fields (ntf IDs, status) and skips action/server fields that the supervisor may have changed. This prevents the worker from overwriting supervisor decisions during concurrent execution.

`markUpdatedByWorker` resets the flag to `False` before each work item is processed, so the worker "claims" the subscription for the duration of its operation.

## createServer / getServerKeyHash_ — key hash migration

`createServer` returns `Maybe KeyHash`: `Nothing` means the server was newly created with the passed hash; `Just kh` means the server already existed and the passed hash differs from the stored one. This `Just` value is stored as `server_key_hash` on queues to allow per-queue key hash overrides.

The `COALESCE(q.server_key_hash, s.key_hash)` pattern appears throughout queries — queues can override the server-level hash, enabling gradual migration when a router's identity key changes.

## updateRcvMsgHash / updateSndMsgHash — race condition guard

Both functions include `AND last_internal_*_msg_id = ?` in their UPDATE WHERE clause. This prevents a race: if another message was processed between `updateIds` and `updateHash` (incrementing the last ID), the hash update is silently skipped rather than corrupting the chain. See comments on these functions.

## deleteConn — conditional delivery wait

Three deletion paths:
1. No timeout: immediate delete.
2. Timeout + no pending deliveries: immediate delete.
3. Timeout + pending deliveries + `deleted_at_wait_delivery` expired: delete.
4. Timeout + pending deliveries + not expired: return `Nothing` (skip).

This allows graceful delivery completion before connection cleanup.

## createSndConn — confirmed queue guard

See comment on `createSndConn`. Checks `checkConfirmedSndQueueExists_` before creating, because `insertSndQueue_` uses `ON CONFLICT DO UPDATE` which would silently replace an existing confirmed send queue. The pre-check prevents this destructive upsert.

## insertRcvQueue_ / insertSndQueue_ — queue ID preservation

Both functions check if a queue already exists (by server + queue ID) and reuse the existing database `queue_id`. If not found, they generate the next sequential ID (`MAX + 1`). This preserves database IDs across retries of queue creation.

## createClientService — service_id reset on upsert

The `ON CONFLICT DO UPDATE` clause sets `service_id = NULL` when credentials are updated. This forces re-registration with the router after credential rotation — the old service ID is invalidated.

## deleteSndMsgDelivery — conditional message retention

After removing the delivery record, checks whether any pending deliveries remain for the message. If none remain and the receipt status is `MROk`, the entire message is deleted. Otherwise, if `keepForReceipt` is true, only the message body is cleared (for debugging receipt mismatches). Handles shared `snd_message_bodies` with `FOR UPDATE` locking on PostgreSQL to prevent concurrent deletion races.

## createWithRandomId' — bounded retry

Generates random 12-byte IDs (base64url encoded) and retries up to 3 times on constraint violations (unique ID collision). Returns `SEUniqueID` if all attempts fail.

## setRcvQueuePrimary / setSndQueuePrimary — two-step primary swap

First clears primary flag on all queues in the connection, then sets it on the target queue. Also clears `replace_*_queue_id` on the new primary — this completes the queue rotation by removing the "replacing" marker.
