# Simplex.Messaging.Agent.Client

> Agent infrastructure layer: protocol client lifecycle, worker framework, subscription management, operation suspension, and concurrency primitives.

**Source**: [`Agent/Client.hs`](../../../../../../src/Simplex/Messaging/Agent/Client.hs)

**See also**: [Agent.hs](./Agent.md) — the orchestration layer that consumes these primitives.

## Overview

This module defines `AgentClient`, the central state container for the messaging agent, and all reusable infrastructure that Agent.hs and other consumers (NtfSubSupervisor.hs, FileTransfer/Agent.hs, simplex-chat) build upon. It covers:

- **Protocol client lifecycle**: lazy singleton connections to SMP/NTF/XFTP routers via `SessionVar` pattern, with disconnect callbacks and reconnection workers
- **Worker framework**: `getAgentWorker` (lifecycle, restart rate limiting, crash recovery) + `withWork`/`withWork_`/`withWorkItems` (task retrieval with doWork flag atomics)
- **Subscription state**: active/pending/removed queues, session-aware cleanup on disconnect, batch subscription RPCs with post-hoc session validation
- **Operation suspension**: five `AgentOpState` TVars with cascade ordering for graceful shutdown
- **Concurrency primitives**: per-connection locks, transport session batching, proxy routing

The module is consumed by Agent.hs (which passes specific worker bodies, task queries, and handler logic into these frameworks) and by external consumers that reuse the worker and protocol client infrastructure.

## AgentClient — central state container

`AgentClient` has ~50 fields, almost all TVars or TMaps. Key architectural groupings:

- **Event queues**: `subQ` (events to client application), `msgQ` (messages from SMP routers)
- **Protocol client pools**: `smpClients`, `ntfClients`, `xftpClients` — all are TMaps of `TransportSession` → `SessionVar`, implementing lazy singletons via `getSessVar`
- **Subscription tracking**: `currentSubs` (TSessionSubs, active+pending per transport session), `removedSubs` (failed subscriptions with errors), `subscrConns` (set of connection IDs currently subscribed)
- **Worker pools**: `smpDeliveryWorkers`, `asyncCmdWorkers`, `smpSubWorkers` — TMaps keyed by work address/connection
- **Operation states**: `ntfNetworkOp`, `rcvNetworkOp`, `msgDeliveryOp`, `sndNetworkOp`, `databaseOp`
- **Locking**: `connLocks`, `invLocks`, `deleteLock`, `getMsgLocks`

All TVars are initialized in `newAgentClient`. The `active` TVar is the global kill switch — `closeAgentClient` sets it to `False`, and all protocol client getters check it first.

## Protocol client lifecycle — SessionVar singleton pattern

Protocol client connections (SMP, NTF, XFTP) use a lazy singleton pattern implemented by [Session.hs](../../../Session.md):

1. **`getSessVar`** atomically checks the TMap. Returns `Left newVar` if absent (caller must connect), `Right existingVar` if present (caller waits for the TMVar).
2. **`newProtocolClient`** wraps the connection attempt. On success, fills the `sessionVar` TMVar with `Right client`. On failure, fills with `Left (error, maybeRetryTime)` and re-throws.
3. **`waitForProtocolClient`** reads the TMVar with a timeout. If the stored error has an expiry time that has passed, it removes the SessionVar and retries from scratch — this is the `persistErrorInterval` retry mechanism.

### SessionVar compare-and-swap

`removeSessVar` (Session.hs) only removes a SessionVar from the map if its `sessionVarId` matches the current entry. The `sessionVarId` is a monotonically increasing counter from `workerSeq`. This prevents a stale disconnection callback from removing a *new* client that was created after the old one disconnected. Without this, the sequence "client A disconnects → client B connects → client A's callback runs" would incorrectly remove client B.

### SMP disconnect callback

`smpClientDisconnected` is the most complex disconnect handler (NTF/XFTP have simpler versions that just remove the SessionVar):

1. `removeSessVar` atomically removes the client if still current
2. If `active`, moves active subscriptions to pending (only those matching the disconnecting client's `sessionId` — see next section)
3. Removes proxied relay sessions that this client created
4. Fires `DOWN` events for affected connections
5. Triggers `resubscribeSMPSession` to spawn a reconnection worker

### Session-aware subscription cleanup

`removeClientAndSubs` (inside `smpClientDisconnected`) uses `SS.setSubsPending` with the disconnecting client's `sessionId`. Only subscriptions whose session ID matches the disconnecting client are moved to pending. If a new client already connected and made its own subscriptions active, those are *not* disturbed. This prevents the race: "old client disconnects → new client subscribes → old client's cleanup incorrectly demotes new client's subscriptions."

## ProtocolServerClient typeclass

Unifies SMP/NTF/XFTP client management with associated types:
- `Client msg` — the connected client type (SMP wraps in `SMPConnectedClient` with proxied relay map; NTF and XFTP use the raw protocol client)
- `ProtoClient msg` — the underlying protocol client for logging/closing

SMP is special: `SMPConnectedClient` bundles the protocol client with `proxiedRelays :: TMap SMPServer ProxiedRelayVar`, a per-connection map of relay sessions for proxy routing.

## Worker framework

Defined here, consumed by Agent.hs, NtfSubSupervisor.hs, FileTransfer/Agent.hs, and simplex-chat. Two separable parts:

### getAgentWorker — lifecycle management

Creates or reuses a worker for a given key. Workers are stored in a TMap keyed by their work address.

- **Create-or-reuse**: atomically checks the map. If absent, creates a new `Worker` (with `doWork` TMVar pre-filled with `()`). If present and `hasWork=True`, signals the existing worker.
- **Fork**: `runWorkerAsync` takes the `action` TMVar. If `Nothing` (worker idle), it starts work. If `Just weakThreadId` (worker running), it puts the value back and returns. This bracket ensures at-most-one concurrent execution.
- **Restart rate limiting**: on worker exit (success or error), checks `restartCount` against `maxWorkerRestartsPerMin`. If under the limit, restarts with `hasWorkToDo` signal. If over the limit, deletes the worker from the map and sends a `CRITICAL True` error.
- **Worker identity**: `workerId` (from `workerSeq`) prevents a stale restart from interfering with a new worker that replaced it in the map.

`getAgentWorker'` is the generic version with custom worker wrapper — used by `smpDeliveryWorkers` which pairs each Worker with a `TMVar ()` retry lock.

### withWork / withWork_ / withWorkItems — task retrieval

Takes `getWork` (fetch next task) and `action` (process it) as separate parameters. The consumer's worker body loops: `waitForWork doWork` → `withWork doWork getTask handleTask`.

**Critical: doWork flag race prevention.** `noWorkToDo` (clearing the flag) happens BEFORE `getWork` (querying for tasks), not after. This prevents the race where: (1) worker queries, finds nothing, (2) another thread adds work and sets the flag, (3) worker clears the flag — losing the signal. By clearing first, any concurrent signal after the query will be preserved.

**Error classification**: `withWork_` distinguishes work-item errors from store errors:
- **Work item error** (`isWorkItemError`): the worker stops and sends `CRITICAL False`. The next iteration would likely produce the same error, so stopping prevents infinite loops.
- **Store error**: the flag is re-set and an `INTERNAL` error is reported. The assumption is that store errors are transient (e.g., DB busy) and retrying may succeed.

`withWorkItems` handles batched work — a list of items where some may have individual errors. If all items are work-item errors, the worker stops. If only some are, the worker continues with the successful items and reports errors.

### runWorkerAsync — at-most-one execution

Uses a bracket on the `action` TMVar:
- `takeTMVar action` — blocks if another thread is starting the worker (TMVar empty during start)
- If the taken value is `Nothing` — worker is idle, start it. Store `Just weakThreadId` in the TMVar.
- If `Just _` — worker is already running, put it back and return.

The `Weak ThreadId` in `action` is a weak reference — it doesn't prevent the worker thread from being garbage collected. This is the cleanup mechanism: if the thread dies without explicitly clearing `action`, the weak reference becomes stale and the next `runWorkerAsync` call will detect it as idle.

## Operation suspension cascade

Five `AgentOpState` TVars track whether each operation category is suspended and how many operations are in-flight:

```
AONtfNetwork  (independent)
AORcvNetwork  → AOMsgDelivery → AOSndNetwork → AODatabase
```

The cascade means:
- `endAgentOperation AORcvNetwork` suspends `AOMsgDelivery`, which cascades to `AOSndNetwork` → `AODatabase`
- `endAgentOperation AOMsgDelivery` suspends `AOSndNetwork` → `AODatabase`
- `endAgentOperation AOSndNetwork` suspends `AODatabase`
- Each leaf in the cascade calls `notifySuspended` (writes `SUSPENDED` to `subQ`, sets `agentState` to `ASSuspended`)

**`beginAgentOperation`** retries (blocks in STM) if the operation is suspended. This provides backpressure: new operations wait until the operation is resumed.

**`agentOperationBracket`** wraps an operation with begin/end. All database access goes through `withStore` which brackets with `AODatabase`. This ensures graceful shutdown propagates: suspending `AORcvNetwork` eventually suspends all downstream operations, and `notifySuspended` only fires when all in-flight operations have completed.

**`waitWhileSuspended`** vs **`waitUntilForeground`**: `waitWhileSuspended` proceeds during `ASSuspending` (allowing in-flight operations to complete), while `waitUntilForeground` blocks during both `ASSuspending` and `ASSuspended`.

## Subscription management

### subscribeQueues — batch-by-transport-session

`subscribeQueues` is the main entry point for subscribing to receive queues:

1. `checkQueues` filters out queues with active GET locks (prevents concurrent GET + SUB on the same queue)
2. `batchQueues` groups queues by transport session
3. `addPendingSubs` marks all queues as pending before the RPC
4. `mapConcurrently` subscribes each session batch in parallel

### subscribeSessQueues_ — post-hoc session validation

After the subscription RPC completes, `subscribeSessQueues_` validates `activeClientSession` — checking that the SessionVar still holds the same client that was used for the RPC. If the client was replaced during the RPC (reconnection happened), the results are discarded and resubscription is triggered. This is optimistic execution with post-hoc validation: do the work, then check if it's still valid.

### processSubResults — partitioning

Subscription results are partitioned into four categories:
1. **Failed with client notice** — queue has a server-side notice (e.g., queue status change)
2. **Failed permanently** — non-temporary error, queue is removed from pending and added to `removedSubs`
3. **Failed temporarily** — error is transient, queue stays in pending for retry on reconnect
4. **Subscribed** — moved from pending to active. Further split into: queues whose service ID matches the session service (added as service-associated) and others.
5. **Ignored** — queue was not in the pending map (already activated by a concurrent path), counted for statistics only

### Resubscription worker

`resubscribeSMPSession` spawns a worker per transport session that retries pending subscriptions with exponential backoff (`withRetryForeground`). The worker:

1. Reads pending subs and pending service sub
2. Waits for foreground and network
3. Resubscribes service and queues
4. Loops until no pending subs remain

**Cleanup blocks on TMVar fill** — the `cleanup` STM action retries (`whenM (isEmptyTMVar $ sessionVar v) retry`) until the async handle is inserted. This prevents the race where cleanup runs before the worker async is stored, which would leave a terminated worker in the map.

## Proxy routing — sendOrProxySMPCommand

Implements SMP proxy/direct routing with fallback:

1. `shouldUseProxy` checks `smpProxyMode` (Always/Unknown/Unprotected/Never) and whether the destination server is "known" (in the user's server list)
2. If proxying: `getSMPProxyClient` creates or reuses a proxy connection, then `connectSMPProxiedRelay` establishes the relay session. On `NO_SESSION` error, re-creates the relay session through the same proxy.
3. If proxying fails with a host error and `smpProxyFallback` allows it: falls back to direct connection
4. `deleteRelaySession` carefully validates that the current relay session matches the one that failed before removing it (prevents removing a concurrently-created replacement session)

## withStore — database access bracket

`withStore` wraps database access with `agentOperationBracket c AODatabase`, ensuring the operation suspension cascade is respected. SQLite errors are classified:
- `ErrorBusy`/`ErrorLocked` → `SEDatabaseBusy` → `CRITICAL True` (prompts user restart)
- Other SQL errors → `SEInternal`

`SEAgentError` is a special wrapper that allows agent-level errors to be threaded through store operations — used when "transaction-like" access is needed but the operation involves agent logic, not just DB queries. See source comment: "network IO should NOT be used inside AgentStoreMonad."

## Server selection — getNextServer / withNextSrv

Server selection has two-level diversity:
1. **Operator diversity**: prefer servers from operators not already used (tracked by `usedOperators` set)
2. **Host diversity**: prefer servers with hosts not already used (tracked by `usedHosts` set)

`filterOrAll` ensures that if all servers are "used," the full list is returned rather than an empty one.

`withNextSrv` is designed for retry loops — it re-reads user servers on each call (allowing configuration changes during retries) and tracks `triedHosts` across attempts. When all hosts are tried, the tried set is reset (`S.empty`), creating a round-robin effect.

## Network configuration — slow/fast selection

`getNetworkConfig` selects between slow and fast network configs based on `userNetworkInfo`:
- `UNCellular` or `UNNone` → slow config (1.5× timeouts via `slowNetworkConfig`)
- `UNWifi`, `UNEthernet`, `UNOther` → fast config

Both configs are stored together in `useNetworkConfig :: TVar (NetworkConfig, NetworkConfig)`. The slow config is derived from the fast config in `newAgentClient`.

## closeAgentClient — shutdown sequence

1. Sets `active = False` — all protocol client getters will throw `INACTIVE`
2. Closes all protocol server clients (SMP, NTF, XFTP) by swapping maps to empty and forking close threads
3. Clears proxied relays
4. Cancels resubscription workers — forks cancellation threads (fire-and-forget, `closeAgentClient` may return before all workers are cancelled)
5. Clears delivery and async command workers
6. Clears subscription state

The cancellation of resubscription workers reads the TMVar first (to get the Async handle), then calls `uninterruptibleCancel`. This is wrapped in a forked thread to avoid blocking the shutdown sequence.

## Transport session modes

`TransportSessionMode` (`TSMEntity` vs other) determines whether the transport session key includes the entity ID (connection/queue ID). When `TSMEntity`, each queue gets its own TLS connection to the router. When not, queues to the same router share a connection. This is controlled by `sessionMode` in the network config.

`mkSMPTSession` and related functions compute the transport session key based on the current mode. This affects connection multiplexing — entity-mode sessions provide better privacy (router can't correlate queues) at the cost of more connections.

## getMsgLocks — GET exclusion

`getQueueMessage` creates a TMVar lock keyed by `(server, rcvId)` and takes it before sending GET. This prevents concurrent GET and SUB on the same queue (SUB is checked via `hasGetLock` in `checkQueues`). The lock is released by `releaseGetLock` after ACK or on error.

## Error classification — temporaryAgentError

Classifies errors as temporary (retryable) or permanent. Notable non-obvious classifications:
- `TEHandshake BAD_SERVICE` is temporary — it indicates a DB error on the router, not a permanent rejection
- `CRITICAL True` is temporary — `True` means the error shows a restart button, implying the user should retry
- `INACTIVE` is temporary — the agent may be reactivated
