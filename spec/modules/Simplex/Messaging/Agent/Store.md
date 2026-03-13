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
