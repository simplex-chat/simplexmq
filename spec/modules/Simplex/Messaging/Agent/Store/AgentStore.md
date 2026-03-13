# Simplex.Messaging.Agent.Store.AgentStore

> Core CRUD operations for agent persistence — users, connections, queues, messages, ratchets, notifications, and file transfers.

**Source**: [`Agent/Store/AgentStore.hs`](../../../../../../src/Simplex/Messaging/Agent/Store/AgentStore.hs)

## Overview

At ~3700 lines, this is the largest module in the codebase. It implements all database operations for the agent, compiled with CPP for both SQLite and PostgreSQL backends. Most functions are straightforward SQL CRUD, but several patterns are non-obvious.

The module re-exports `withConnection`, `withTransaction`, `withTransactionPriority`, `firstRow`, `firstRow'`, and `maybeFirstRow` from the backend-specific Common module. It also exports `fromOnlyBI` (a local helper) and `getWorkItem`/`getWorkItems`.

## Dual-backend compilation

The module uses `#if defined(dbPostgres)` throughout. Key behavioral differences:
- **Row locking**: PostgreSQL uses `FOR UPDATE` on reads that precede writes (e.g., `getConnForUpdate`, `getRatchetForUpdate`, `retrieveLastIdsAndHashRcv_`). SQLite relies on its single-writer model instead.
- **Batch queries**: PostgreSQL uses `IN ?` with `In` wrapper for batch operations. SQLite falls back to per-row `forM` loops.
- **Constraint handling**: PostgreSQL uses `constraintViolation`, SQLite checks `SQL.ErrorConstraint`.

## getWorkItem / getWorkItems — worker store pattern

`getWorkItem` implements the store-side pattern for the [worker framework](../Client.md): `getId → getItem → markFailed`. If `getId` throws an IO exception, `handleWrkErr` wraps it as `SEWorkItemError` (via `mkWorkItemError`), which signals the worker to suspend rather than retry. If `getItem` fails (returning Left or throwing), `tryGetItem` calls `markFailed` (also wrapped by `handleWrkErr`) and rethrows the original error. This prevents crash loops on corrupt data.

`getWorkItems` extends this to batch work items, where each item failure is independent.

**Consumed by**: `getPendingQueueMsg`, `getPendingServerCommand`, `getNextNtfSubNTFActions`, `getNextNtfSubSMPActions`, `getNextDeletedSndChunkReplica`, `getNextNtfTokenToDelete`, `getNextRcvChunkToDownload`, `getNextRcvFileToDecrypt`, `getNextSndChunkToUpload`, `getNextSndFileToPrepare`.

## Notification subscription — supervisor/worker coordination

`updateNtfSubscription`, `setNullNtfSubscriptionAction`, and `deleteNtfSubscription` all check `updated_by_supervisor` before writing. When `True`, the worker only updates local fields (ntf IDs, status) and skips action/server fields that the supervisor may have changed. This prevents the worker from overwriting supervisor decisions during concurrent execution.

`markUpdatedByWorker` resets the flag to `False` before each work item is processed, so the worker "claims" the subscription for the duration of its operation.

## createServer / getServerKeyHash_ — key hash migration

`createServer` returns `Maybe KeyHash`: `Nothing` means the server was newly created with the passed hash; `Just kh` means the server already existed and the passed hash differs from the stored one. This `Just` value is stored as `server_key_hash` on queues to allow per-queue key hash overrides.

The `COALESCE(q.server_key_hash, s.key_hash)` pattern appears throughout queries — queues can override the server-level hash, enabling gradual migration when a router's identity key changes.

## updateRcvMsgHash / updateSndMsgHash — race condition guard

Both functions include `AND last_internal_*_msg_id = ?` in their UPDATE WHERE clause. This prevents a race: if another message was processed between `updateIds` and `updateHash` (incrementing the last ID), the hash update is silently skipped rather than corrupting the chain. See comments on these functions.

## deleteConn — conditional delivery wait

Four paths:
1. No timeout: immediate delete.
2. Timeout + no pending deliveries: immediate delete.
3. Timeout + pending deliveries + `deleted_at_wait_delivery` expired: delete.
4. Timeout + pending deliveries + not expired: return `Nothing` (skip deletion).

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

## createCommand — silent drop for deleted connections

When `createCommand` encounters a constraint violation (the referenced connection was already deleted), it logs the error and returns successfully rather than throwing. This means commands targeting deleted connections are silently dropped. The rationale: the connection is already gone, so there's nothing useful to do with the error.

## updateNewConnRcv — retry tolerance

`updateNewConnRcv` accepts both `NewConnection` and `RcvConnection` connection states. The `RcvConnection` case is explicitly commented as "to allow retries" — if the initial queue insertion succeeded but the caller didn't get the response, a retry would find the connection already upgraded. `updateNewConnSnd` does not have this tolerance.

## setLastBrokerTs — monotonic advance

The WHERE clause includes `AND (last_broker_ts IS NULL OR last_broker_ts < ?)`, which ensures the timestamp only moves forward. Out-of-order message processing (e.g., from different queues) cannot regress the broker timestamp.

## deleteDeliveredSndMsg — FOR UPDATE + count zero check

On PostgreSQL, acquires a `FOR UPDATE` lock on the message row before counting pending deliveries. This prevents a race where two concurrent delivery completions both see count > 0 before either deletes, then both try to delete. Only deletes the message when the count reaches exactly 0.

## createWithRandomId' — savepoint-based retry

Uses `withSavepoint` around each insertion attempt rather than bare execute. This is critical for PostgreSQL: a failed statement within a transaction aborts the entire transaction, but savepoints allow rolling back just the failed INSERT and retrying with a new ID.

## Explicit row-lock functions

`lockConnForUpdate`, `lockRcvFileForUpdate`, and `lockSndFileForUpdate` are PostgreSQL-only explicit lock acquisition that compile to no-ops on SQLite. They acquire `FOR UPDATE` locks on rows that need serialized access without modifying them.

## XFTP work item retry ordering

`getNextRcvChunkToDownload` and `getNextSndChunkToUpload` order by `retries ASC, created_at ASC`. This prioritizes chunks with fewer retries, ensuring a repeatedly-failing chunk doesn't starve others. Same pattern for `getNextDeletedSndChunkReplica`.

## getRcvFileRedirects — error resilience

When loading redirect chains, errors loading individual redirect files are silently swallowed (`either (const $ pure Nothing) (pure . Just)`). This prevents a corrupt redirect from blocking access to the main file.

## enableNtfs defaults to True when NULL

Both `toRcvQueue` and `rowToConnData` default `enableNtfs` to `True` when the database value is NULL (`maybe True unBI enableNtfs_`). This is a backward-compatibility default for connections created before the field existed.

## primaryFirst — queue ordering

The `primaryFirst` comparator sorts queues with the primary queue first (`Down` on primary flag), then by `dbReplaceQId` to place the "replacing" queue second. This ensures all queue lists are consistently ordered for connection reconstruction.

## getAnyConn_ — connection GADT reconstruction

Reconstructs the type-level `Connection'` GADT by combining connection mode with the presence/absence of receive and send queues. The `CMContact` mode only maps to `ContactConnection` (receive-only); all other combinations use `CMInvitation` mode. When neither rcv nor snd queues exist, the result is always `NewConnection` regardless of mode.

## deleteNtfSubscription — soft delete when supervisor active

When `updated_by_supervisor` is true, `deleteNtfSubscription` doesn't actually delete the row. Instead, it nulls out the IDs and sets status to `NASDeleted`, preserving the row for the supervisor to observe. Only when the supervisor has not intervened does it perform a real DELETE.
