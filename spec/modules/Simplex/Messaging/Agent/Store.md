# Simplex.Messaging.Agent.Store

> Domain entity types for agent persistence — queues, connections, messages, commands, and store errors.

**Source**: [`Agent/Store.hs`](../../../../../src/Simplex/Messaging/Agent/Store.hs)

## Overview

This module defines the data types that represent agent state. It contains no database operations — those are in [AgentStore.hs](./Store/AgentStore.md). The key abstractions are:

- **Queue types** (`StoredRcvQueue`, `StoredSndQueue`) parameterized by `DBStored` phantom type for new vs persisted distinction
- **Connection GADT** (`Connection'`) encoding the connection state machine at the type level
- **Message containers** (`RcvMsgData`, `SndMsgData`, `PendingMsgData`) for the message lifecycle
- **Store errors** (`StoreError`) including two sentinel errors with special semantics

## Connection' — type-level state machine

The `Connection'` GADT encodes connection lifecycle as a type parameter: `CNew` → `CRcv`/`CSnd` → `CDuplex`, plus `CContact` for reusable contact connections. `SomeConn` wraps an existential to store connections of unknown type.

`TestEquality SConnType` deliberately omits `SCNew` — `testEquality SCNew SCNew` returns `Nothing`. This is intentional: `NewConnection` has no queues and is not a valid target for type-level connection matching in store operations.

## canAbortRcvSwitch — race condition boundary

See comments on `canAbortRcvSwitch`. The `RSSendingQUSE` and `RSReceivedMessage` states cannot be aborted because the sender may have already deleted the original queue. Aborting (deleting the new queue) at that point would break the connection with no recovery path.

## ratchetSyncAllowed / ratchetSyncSendProhibited — cross-repo contract

See comments on `ratchetSyncAllowed`. Both functions carry the comment "this function should be mirrored in the clients" — simplex-chat must implement identical logic. The agent enforces these state checks, but the chat client also needs them for UI decisions (e.g., disabling send when `ratchetSyncSendProhibited`).

## SEWorkItemError — worker suspension sentinel

`SEWorkItemError` is a sentinel error that triggers worker suspension when encountered during work item retrieval. The `AnyStoreError` typeclass exposes `isWorkItemError` for the worker framework ([Agent/Client.hs](./Client.md)) to detect this case. The comment "do not use!" means it should not be thrown for normal error conditions — only when the work item itself is corrupt/unreadable and the worker should stop rather than retry.

## SEAgentError — store-level error wrapping

`SEAgentError` wraps `AgentErrorType` inside store operations. This allows store functions to return agent-level errors (e.g., connection state violations detected during a DB transaction) without breaking the `ExceptT StoreError` type. The "to avoid race conditions" rationale: checking a condition and acting on it must happen in the same DB transaction, so the agent error is returned through the store error channel.

## InvShortLink — secure-on-read semantics

See comment on `InvShortLink`. Stored separately from the connection because 1-time invitation short links have a "secure-on-read" property: accessing the link data on the router marks it as read, preventing undetected observation. The `sndPrivateKey` is persisted to allow retries of the link creation without generating new keys.

## RcvQueueSub — subscription-optimized projection

`RcvQueueSub` strips cryptographic fields from `RcvQueue`, keeping only what's needed for subscription tracking in [TSessionSubs](./TSessionSubs.md). This reduces memory pressure when tracking thousands of subscriptions in STM.

## rcvSMPQueueAddress exposes sender-facing ID

`rcvSMPQueueAddress` constructs the `SMPQueueAddress` from a receive queue using `sndId` (not `rcvId`). The address shared with senders in connection requests contains the sender ID, the public key derived from `e2ePrivKey`, and `queueMode`. The `rcvId` is never exposed externally.

## enableNtfs is duplicated between queue and connection

`enableNtfs` exists on both `StoredRcvQueue` and `ConnData`. The comment marks it as "duplicated from ConnData." The queue-level copy enables subscription operations (which work at the queue level) to check notification status without loading the full connection.

## deleteErrors — queue deletion retry counter

`StoredRcvQueue` has a `deleteErrors :: Int` field that counts failed deletion attempts. This allows the agent to give up on queue deletion after repeated failures rather than retrying indefinitely.

## Two-level message preparation

`SndMsgData` optionally carries `SndMsgPrepData` with a `sndMsgBodyId` reference to a separately stored message body. `PendingMsgData` optionally carries `PendingMsgPrepData` with the actual `AMessage` body. This split allows large message bodies to be stored once and referenced by ID during the send pipeline, avoiding redundant serialization.

## Per-message retry backoff

`PendingMsgData` includes `msgRetryState :: Maybe RI2State` — each pending message independently tracks its retry backoff state. This means messages that fail to send don't reset the retry timers of other pending messages in the same connection.

## Soft deletion and optional contact connection

`ConnData` has `deleted :: Bool` for soft deletion — connections are marked deleted before queue cleanup completes. `Invitation` has `contactConnId_ :: Maybe ConnId` (note the trailing underscore) — invitations can outlive their originating contact connection.

## SEBadQueueStatus is vestigial

`SEBadQueueStatus` is documented in the source as "Currently not used." It was intended for queue status transition validation but was never implemented.
