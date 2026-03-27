# Simplex.Messaging.Client.Agent

> SMP client connections with subscription management, reconnection, and service certificate support.

**Source**: [`Client/Agent.hs`](../../../../../src/Simplex/Messaging/Client/Agent.hs)

## Overview

This is the "small agent" — used only in routers (SMP proxy, notification router) to manage client connections to other SMP routers. The "big agent" in `Simplex.Messaging.Agent` + `Simplex.Messaging.Agent.Client` serves client applications and adds the full messaging agent layer. See [Two agent layers](../../../../TOPICS.md) topic.

`SMPClientAgent` manages `SMPClient` connections via `smpClients :: TMap SMPServer SMPClientVar` (one per router), tracks active and pending subscriptions, and handles automatic reconnection. It is parameterized by `Party` (`p`) and uses the `ServiceParty` constraint to support both `RecipientService` and `NotifierService` modes.

## Dual subscription model

Four TMap fields track subscriptions in two dimensions:

| | Active | Pending |
|---|---|---|
| **Service** | `activeServiceSubs` (TMap SMPServer (TVar (Maybe (ServiceSub, SessionId)))) | `pendingServiceSubs` (TMap SMPServer (TVar (Maybe ServiceSub))) |
| **Queue** | `activeQueueSubs` (TMap SMPServer (TMap QueueId (SessionId, C.APrivateAuthKey))) | `pendingQueueSubs` (TMap SMPServer (TMap QueueId C.APrivateAuthKey)) |

See comments on `activeServiceSubs` and `pendingServiceSubs` for the coexistence rules. Key constraint: only one service subscription per router. Active subs store the `SessionId` that established them.

## SessionVar compare-and-swap — core concurrency safety

`removeSessVar` (in Session.hs) uses `sessionVarId` (monotonically increasing counter from `sessSeq`) to prevent stale removal. When a disconnected client's cleanup runs after a new client already replaced the map entry, the ID mismatch causes removal to silently no-op. See comment on `removeSessVar`. This is used throughout: `removeClientAndSubs` for client map, `cleanup` for worker map.

## removeClientAndSubs — outside-STM lookup optimization

See comment on `removeClientAndSubs`. Subscription TVar references are obtained outside STM (via `TM.lookupIO`), then modified inside `atomically`. This is safe because the invariant is that subscription TVar entries for a router are never deleted from the outer TMap, only their contents change. Moving lookups inside the STM transaction would cause excessive re-evaluation under contention.

## Disconnect preserves others' subscriptions

`updateServiceSub` only moves active→pending when `sessId` matches the disconnected client (see its comment). If a new client already established different subscriptions on the same router, those are preserved. Queue subs use `M.partition` to split by SessionId — only matching subs move to pending, non-matching remain active.

## Pending never reset to Nothing on disconnect

See comment on `updateServiceSub`. After clearing an active service sub, the code sets pending to the cleared value but does NOT reset pending to `Nothing`. This avoids the race where a concurrent new client session has already set a different pending subscription. Implication: pending subs can only grow (be set) during disconnect, never shrink (be cleared).

## persistErrorInterval — delayed error cleanup

When `connectClient` calls `newSMPClient` and it fails, the error is stored with an expiry timestamp. `waitForSMPClient` checks expiry before retrying. When `persistErrorInterval` is 0, the error is stored without timestamp and the SessionVar is immediately removed from the map.

## Session validation after subscription RPC

Both `smpSubscribeQueues` and `smpSubscribeService` validate `activeClientSession` AFTER the subscription RPC completes, before committing results to state. If the session changed during the RPC (client reconnected), results are discarded and reconnection is triggered. This is optimistic execution with post-hoc validation — the RPC may succeed but its results are thrown away if the session is stale.

## groupSub — subscription result classification

Each queue result is classified by a `foldr` over the (subs, results) zip:

- **Success with matching serviceId**: counted as service-subscribed (`sQs` list)
- **Success without matching serviceId**: counted as queue-only (`qOks` list with SessionId and key)
- **Not in pending map**: silently skipped (handles concurrent activation by another path)
- **Temporary error** (network, timeout): sets the `tempErrs` flag but does NOT remove from pending — queue stays pending for retry on reconnect
- **Permanent error**: removes from pending and added to `finalErrs` — terminal, no automatic retry

Even if multiple temporary errors occur in a batch, only one `reconnectClient` call is made (via the boolean accumulator flag).

## updateActiveServiceSub — accumulative merge

When serviceId and sessionId match the existing active subscription, queue count is added (`n + n'`) and IdsHash is XOR-merged (`idsHash <> idsHash'`). This accumulates across multiple subscription batches for the same service. When they don't match, the subscription is replaced entirely (silently drops old data).

## CAServiceUnavailable — cascade to queue resubscription

When `smpSubscribeService` detects service ID or role mismatch with the connection, it fires `CAServiceUnavailable`. See comment on `CAServiceUnavailable` for the full implication: the app must resubscribe all queues individually, creating new associations. This can happen if the SMP router reassigns service IDs (e.g., after downgrade and upgrade).

## getPending — polymorphic over STM/IO

`getPending` uses rank-2 polymorphism to work in both STM (for the "should we spawn a worker?" check, providing a consistent snapshot) and IO (for the actual reconnection data read, providing fresh data). Between these two calls, new pending subs could be added — the worker loop handles this by re-checking on each iteration.

## Reconnect worker lifecycle

### Spawn decision
`reconnectClient` checks `active` outside STM, then atomically checks for pending subs and gets/creates a worker SessionVar. If no pending subs exist, no worker is spawned — this prevents race with cleanup and adding pending queues in another call.

### Worker cleanup blocks on TMVar fill
See comment on `cleanup`. The STM `retry` loop waits until the async handle is inserted into the TMVar before removing the worker from the map. Without this, cleanup could race ahead of the `putTMVar` in `newSubWorker`, leaving a terminated worker in the map.

### Double timeout on reconnection
`runSubWorker` wraps the entire reconnection in `System.Timeout.timeout` using `tcpConnectTimeout` in addition to the network-layer timeout. Two layers — network for the connection attempt, outer for the entire operation including subscription.

### Reconnect filters already-active queues
During reconnection, `reconnectSMPClient` reads current active queue subs (outside STM, same "vars never removed" invariant) and filters them out before resubscribing. Subscription is chunked by `agentSubsBatchSize` — partial success is possible across chunks.

## Agent shutdown ordering

`closeSMPClientAgent` executes in order: set `active = False`, close all client connections, then swap workers map to empty and fork cancellation threads. The cancel threads use `uninterruptibleCancel` but are fire-and-forget — `closeSMPClientAgent` may return before all workers are actually cancelled.

## addSubs_ — left-biased union

`addSubs_` uses `TM.union` which delegates to `M.union` (left-biased). If a queue subscription already exists, the new auth key from the incoming map wins. Service subs use `writeTVar` (overwrite) since only one service sub exists per router.
