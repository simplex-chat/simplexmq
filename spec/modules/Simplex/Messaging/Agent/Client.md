# Simplex.Messaging.Agent.Client

> Agent infrastructure layer: protocol client lifecycle, worker framework, subscription management, operation suspension, and concurrency primitives.

**Source**: [`Agent/Client.hs`](../../../../../../src/Simplex/Messaging/Agent/Client.hs)

**See also**: [Agent.hs](./Agent.md) — the orchestration layer that consumes these primitives.

## Overview

This module defines `AgentClient`, the central state container for the SimpleX agent, and all reusable infrastructure that Agent.hs and other consumers (NtfSubSupervisor.hs, FileTransfer/Agent.hs, simplex-chat) build upon. It covers:

- **Protocol client lifecycle**: lazy singleton connections to SMP/NTF/XFTP routers via `SessionVar` pattern, with disconnect callbacks and reconnection workers
- **Worker framework**: `getAgentWorker` (lifecycle, restart rate limiting, crash recovery) + `withWork`/`withWork_`/`withWorkItems` (task retrieval with doWork flag atomics)
- **Subscription state**: active/pending/removed queues, session-aware cleanup on disconnect, batch subscription RPCs with post-hoc session validation
- **Operation suspension**: five `AgentOpState` TVars with cascade ordering for graceful shutdown
- **Concurrency primitives**: per-connection locks, transport session batching, proxy routing

The module is consumed by Agent.hs (which passes specific worker bodies, task queries, and handler logic into these frameworks) and by external consumers that reuse the worker and protocol client infrastructure.

## AgentClient — central state container

`AgentClient` has ~43 fields, almost all TVars or TMaps. Key architectural groupings:

- **Event queues**: `subQ` (events to client application), `msgQ` (messages from SMP routers)
- **Protocol client pools**: `smpClients`, `ntfClients`, `xftpClients` — all are TMaps of `TransportSession` → `SessionVar`, implementing lazy singletons via `getSessVar`
- **Subscription tracking**: `currentSubs` (TSessionSubs, active+pending per transport session), `removedSubs` (failed subscriptions with errors), `subscrConns` (set of connection IDs currently subscribed)
- **Worker pools**: `smpDeliveryWorkers`, `asyncCmdWorkers` — TMaps keyed by work address/connection. `smpSubWorkers` — TMaps keyed by transport session for resubscription.
- **Operation states**: `ntfNetworkOp`, `rcvNetworkOp`, `msgDeliveryOp`, `sndNetworkOp`, `databaseOp`
- **Locking**: `connLocks`, `invLocks`, `deleteLock`, `getMsgLocks`, `clientNoticesLock`
- **Service state**: `useClientServices` (per-user boolean controlling whether service certificates are used)
- **Proxy routing**: `smpProxiedRelays` (maps destination transport session → proxy router used)
- **Network state**: `userNetworkInfo`, `userNetworkUpdated`, `useNetworkConfig` (slow/fast pair)

All TVars are initialized in `newAgentClient`. The `active` TVar is the global kill switch — `closeAgentClient` sets it to `False`, and all protocol client getters check it first.

## Protocol client lifecycle — SessionVar singleton pattern

Protocol client connections (SMP, NTF, XFTP) use a lazy singleton pattern implemented by [Session.hs](../../../Session.md):

1. **`getSessVar`** atomically checks the TMap. Returns `Left newVar` if absent (caller must connect), `Right existingVar` if present (caller waits for the TMVar).
2. **`newProtocolClient`** wraps the connection attempt. On success, fills the `sessionVar` TMVar with `Right client` and writes a `CONNECT` event to `subQ`. On failure, fills with `Left (error, maybeRetryTime)` and re-throws.
3. **`waitForProtocolClient`** reads the TMVar with a timeout. If the stored error has an expiry time that has passed, it removes the SessionVar and retries from scratch — this is the `persistErrorInterval` retry mechanism.

### Error caching with persistErrorInterval

When `newProtocolClient` fails and `persistErrorInterval > 0`, the error is cached with an expiry timestamp (`Just ts`). Future connection attempts during the interval immediately receive the cached error from `waitForProtocolClient` without attempting a connection. When `persistErrorInterval == 0`, the SessionVar is removed immediately on failure, so the next attempt starts a fresh connection. This prevents connection storms to unreachable routers.

### SessionVar compare-and-swap

`removeSessVar` (Session.hs) only removes a SessionVar from the map if its `sessionVarId` matches the current entry. The `sessionVarId` is a monotonically increasing counter from `workerSeq`. This prevents a stale disconnection callback from removing a *new* client that was created after the old one disconnected. Without this, the sequence "client A disconnects → client B connects → client A's callback runs" would incorrectly remove client B.

### SMP connection — service credentials and session setup

`smpConnectClient` connects an SMP client, with two important post-connection steps:

1. **Session ID registration**: `SS.setSessionId` records the TLS session ID in `currentSubs`, linking the transport session to the actual TLS connection for later session validation.

2. **Service credential synchronization** (`updateClientService`): After connecting, compares client-side and router-side service state. Four cases:
   - Both have service and IDs match → update DB (no-op if same)
   - Both have service but IDs differ → update DB and remove old queue-service associations
   - Client has service, router doesn't → delete client service (handles router version downgrade)
   - Router has service, client doesn't → log error (should not happen in normal flow)

On connection failure, `smpConnectClient` triggers `resubscribeSMPSession` before re-throwing the error. This ensures pending subscriptions get retry logic even when the initial connection attempt fails.

### SMP disconnect callback

`smpClientDisconnected` is the most complex disconnect handler (NTF/XFTP have simpler versions that remove the SessionVar and write a `DISCONNECT` event):

1. `removeSessVar` atomically removes the client if still current
2. If `active`, moves active subscriptions to pending (only those matching the disconnecting client's `sessionId` — see next section)
3. Removes proxied relay sessions that this client created
4. Fires `DISCONNECT`, `DOWN`, and `SERVICE_DOWN` events for affected connections
5. Releases GET locks for affected queues
6. Triggers resubscription (see below)

**Resubscription mode switching**: The disconnect handler chooses between two resubscription paths based on whether the session mode matches the entity presence: `(mode == TSMEntity) == isJust cId`. When they match, it calls `resubscribeSMPSession` which handles both service and queue resubscription in a single worker. When they don't match (e.g., entity-mode session disconnects but there's also a shared session), it separately resubscribes the service and queues, because they belong to different transport sessions.

### Session-aware subscription cleanup

`removeClientAndSubs` (inside `smpClientDisconnected`) uses `SS.setSubsPending` with the disconnecting client's `sessionId`. Only subscriptions whose session ID matches the disconnecting client are moved to pending. If a new client already connected and made its own subscriptions active, those are *not* disturbed. This prevents the race: "old client disconnects → new client subscribes → old client's cleanup incorrectly demotes new client's subscriptions."

## ProtocolServerClient typeclass

Unifies SMP/NTF/XFTP client management with associated types:
- `Client msg` — the connected client type (SMP wraps in `SMPConnectedClient` with proxied relay map; NTF and XFTP use the raw protocol client)
- `ProtoClient msg` — the underlying protocol client for logging/closing

SMP is special: `SMPConnectedClient` bundles the protocol client with `proxiedRelays :: TMap SMPServer ProxiedRelayVar`, a per-connection map of relay sessions for proxy routing.

XFTP is special in a different way: its `getProtocolServerClient` ignores the `NetworkRequestMode` parameter and always uses `NRMBackground` for `waitForProtocolClient`. This means XFTP connections always use background timing regardless of the caller's request mode.

## Worker framework

Defined here, consumed by Agent.hs, NtfSubSupervisor.hs, FileTransfer/Agent.hs, and simplex-chat. Two separable parts:

### getAgentWorker — lifecycle management

Creates or reuses a worker for a given key. Workers are stored in a TMap keyed by their work address.

- **Create-or-reuse**: atomically checks the map. If absent, creates a new `Worker` (with `doWork` TMVar pre-filled with `()`). If present and `hasWork=True`, signals the existing worker.
- **Fork**: `runWorkerAsync` takes the `action` TMVar. If `Nothing` (worker idle), it starts work. If `Just weakThreadId` (worker running), it puts the value back and returns. This bracket ensures at-most-one concurrent execution.
- **Restart rate limiting**: on worker exit (success or error), `restartOrDelete` checks `restartCount` against `maxWorkerRestartsPerMin`. If under the limit, resets `action` to `Nothing` (idle), signals `hasWorkToDo`, and reports `INTERNAL` error. If over the limit, deletes the worker from the map and sends a `CRITICAL True` error. The restart only happens if the worker's `workerId` still matches the map entry — a stale restart from a replaced worker silently no-ops.

`getAgentWorker'` is the generic version with custom worker wrapper — used by `smpDeliveryWorkers` which pairs each Worker with a `TMVar ()` retry lock.

### withWork / withWork_ / withWorkItems — task retrieval

Takes `getWork` (fetch next task) and `action` (process it) as separate parameters. The consumer's worker body loops: `waitForWork doWork` → `withWork doWork getTask handleTask`.

**Critical: doWork flag race prevention.** `noWorkToDo` (clearing the flag) happens BEFORE `getWork` (querying for tasks), not after. This prevents the race where: (1) worker queries, finds nothing, (2) another thread adds work and sets the flag, (3) worker clears the flag — losing the signal. By clearing first, any concurrent signal after the query will be preserved.

**Error classification**: `withWork_` distinguishes work-item errors from store errors:
- **Work item error** (`isWorkItemError`): the worker stops and sends `CRITICAL False`. The next iteration would likely produce the same error, so stopping prevents infinite loops.
- **Store error**: the flag is re-set and an `INTERNAL` error is reported. The assumption is that store errors are transient (e.g., DB busy) and retrying may succeed.

`withWorkItems` handles batched work — a list of items where some may have individual errors. If all items are work-item errors, the worker stops. If only some are, the worker continues with the successful items and reports errors via `ERRS` event.

### runWorkerAsync — at-most-one execution

Uses a bracket on the `action` TMVar:
- `takeTMVar action` — blocks if another thread is starting the worker (TMVar empty during start)
- If the taken value is `Nothing` — worker is idle, start it. Store `Just weakThreadId` in the TMVar via `forkIO`.
- If `Just _` — worker is already running, put it back and return.

The `Weak ThreadId` in `action` is a weak reference — it doesn't prevent the worker thread from being garbage collected. It is used by `cancelWorker`, which calls `deRefWeak` to get the thread ID and kills it; if the thread was already GC'd, the kill is a no-op. The primary lifecycle management is through the `restartOrDelete` chain in `getAgentWorker'`, not the weak reference.

### throwWhenNoDelivery — delivery worker self-termination

Delivery workers call `throwWhenNoDelivery` to check if their entry still exists in the `smpDeliveryWorkers` map. If the worker was removed (delivery complete), it throws `ThreadKilled` to terminate the worker thread. This is distinct from `throwWhenInactive` (which checks global `active` state) — it allows individual workers to be stopped without shutting down the entire agent.

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

**`agentOperationBracket`** wraps an operation with begin/end. It takes a `check` function that runs before `beginAgentOperation` — typically `throwWhenInactive`, which throws `ThreadKilled` if the agent is inactive. All database access goes through `withStore` which brackets with `AODatabase`. This ensures graceful shutdown propagates: suspending `AORcvNetwork` eventually suspends all downstream operations, and `notifySuspended` only fires when all in-flight operations have completed.

**`waitWhileSuspended`** vs **`waitUntilForeground`**: `waitWhileSuspended` proceeds during `ASSuspending` (allowing in-flight operations to complete), while `waitUntilForeground` blocks during both `ASSuspending` and `ASSuspended`.

**`waitForUserNetwork`**: bounded wait for network — if the network doesn't come online within `userNetworkInterval`, proceeds anyway. Uses `registerDelay` for the timeout.

## Subscription management

### subscribeQueues — batch-by-transport-session

`subscribeQueues` is the main entry point for subscribing to receive queues:

1. `checkQueues` filters out queues with active GET locks (prevents concurrent GET + SUB on the same queue)
2. `batchQueues` groups queues by transport session
3. `addPendingSubs` marks all queues as pending before the RPC
4. `mapConcurrently` subscribes each session batch in parallel

### subscribeSessQueues_ — post-hoc session validation and atomicity

After the subscription RPC completes, `subscribeSessQueues_` validates `activeClientSession` — checking that the SessionVar still holds the same client that was used for the RPC. If the client was replaced during the RPC (reconnection happened), the results are discarded (errors converted to temporary `BROKER NETWORK` to ensure retry) and resubscription is triggered.

The post-RPC processing runs under `uninterruptibleMask_` for atomicity. The sequence is:
1. **Atomically**: `processSubResults` partitions results and updates subscription state; if there are client notices, takes `clientNoticesLock` TMVar
2. **IO**: `processRcvServiceAssocs` updates service associations in the DB
3. **IO**: `processClientNotices` updates notice state, always releases `clientNoticesLock` in `finally`

The `clientNoticesLock` TMVar serializes notice processing across concurrent subscription batches.

**UP events for newly-active connections only**: After processing, UP events are sent only for connections that were NOT already active before this batch — existing active subscriptions (from `SS.getActiveSubs`) are excluded to prevent duplicate notifications.

**Client close on all-temporary-error**: When ALL subscription results are temporary errors, no connections were already active, and the session is still current, the SMP client session is closed. This forces a fresh connection on the next attempt rather than reusing a potentially broken one.

### processSubResults — partitioning

Subscription results are partitioned into five categories:
1. **Failed with client notice** — error has an associated router-side notice (e.g., queue status change). Queue is treated as failed (removed from pending, added to `removedSubs`) AND the notice is recorded for processing.
2. **Failed permanently** — non-temporary error without notice, queue is removed from pending and added to `removedSubs`
3. **Failed temporarily** — error is transient, queue stays in pending unchanged for retry on reconnect
4. **Subscribed** — moved from pending to active. Further split into: queues whose service ID matches the session service (added as service-associated) and others. If the queue had a tracked `clientNoticeId`, it is cleared (notice resolved by successful subscription).
5. **Ignored** — queue was not in the pending map (already activated by a concurrent path), counted for statistics only

### Resubscription worker

`resubscribeSMPSession` spawns a worker per transport session that retries pending subscriptions with exponential backoff (`withRetryForeground`). The worker:

1. Reads pending subs and pending service sub
2. Waits for foreground and network
3. Resubscribes service and queues
4. Loops until no pending subs remain

**Spawn guard**: Before creating a new worker, `resubscribeSMPSession` checks `SS.hasPendingSubs`. If there are no pending subs, it returns without spawning. This prevents creating idle workers.

**Cleanup blocks on TMVar fill** — the `cleanup` STM action retries (`whenM (isEmptyTMVar $ sessionVar v) retry`) until the async handle is inserted. This prevents the race where cleanup runs before the worker async is stored, which would leave a terminated worker in the map.

## Proxy routing — sendOrProxySMPCommand

Implements SMP proxy/direct routing with fallback:

1. `shouldUseProxy` checks `smpProxyMode` (Always/Unknown/Unprotected/Never) and whether the destination router is "known" (in the user's router list)
2. If proxying: `getSMPProxyClient` creates or reuses a proxy connection, then `connectSMPProxiedRelay` establishes the relay session. On `NO_SESSION` error, re-creates the relay session through the same proxy.
3. If proxying fails with a host error and `smpProxyFallback` allows it: falls back to direct connection
4. `deleteRelaySession` carefully validates that the current relay session matches the one that failed before removing it (prevents removing a concurrently-created replacement session)

**NO_SESSION retry limit**: On `NO_SESSION`, `sendViaProxy` is called recursively with `Just proxySrv` to reuse the same proxy router. If the recursive call also gets `NO_SESSION`, it throws `proxyError` instead of recursing again — `proxySrv_` is `Just`, so the `Nothing` branch (which recurses) is not taken. This limits retry to exactly one attempt.

**Proxy selection caching** (`smpProxiedRelays`): When `getSMPProxyClient` selects a proxy for a destination, it atomically inserts the proxy→destination mapping into `smpProxiedRelays`. If a mapping already exists (another thread selected a proxy for the same destination), the existing mapping is used. On relay creation failure with non-host errors, both the relay session and proxy mapping are removed. On host errors, they are preserved to allow fallback logic.

## Service credentials lifecycle

`getServiceCredentials` manages per-user, per-router service certificate credentials:

1. Checks `useClientServices` — if the user has services disabled, returns `Nothing`
2. Looks up existing credentials in DB via `getClientServiceCredentials`
3. If none exist, generates new TLS credentials on-the-fly (`genCredentials`) and stores them
4. Extracts the private signing key from the X.509 certificate

The generated credentials are Ed25519 self-signed certificates with `simplex` organization, valid for ~2740 years. The certificate chain and hash are bundled into `ServiceCredentials` for the SMP handshake.

## withStore — database access bracket

`withStore` wraps database access with `agentOperationBracket c AODatabase`, ensuring the operation suspension cascade is respected. SQLite errors are classified:
- `ErrorBusy`/`ErrorLocked` → `SEDatabaseBusy` → `CRITICAL True` (prompts user restart)
- Other SQL errors → `SEInternal`

`SEAgentError` is a special wrapper that allows agent-level errors to be threaded through store operations — used when "transaction-like" access is needed but the operation involves agent logic, not just DB queries. See source comment: "network IO should NOT be used inside AgentStoreMonad."

`withStoreBatch` / `withStoreBatch'` run multiple DB operations in a single transaction, catching exceptions per-operation to report individual failures. The entire batch is within one `agentOperationBracket`.

## Router selection — getNextServer / withNextSrv

Router selection has two-level diversity:
1. **Operator diversity**: prefer routers from operators not already used (tracked by `usedOperators` set)
2. **Host diversity**: prefer routers with hosts not already used (tracked by `usedHosts` set)

`filterOrAll` ensures that if all routers are "used," the full list is returned rather than an empty one.

`withNextSrv` is designed for retry loops — it re-reads user routers on each call (allowing configuration changes during retries) and tracks `triedHosts` across attempts. When all hosts are tried, the tried set is reset (`S.empty`), creating a round-robin effect.

## Locking primitives

**`withConnLock`**: Per-connection lock via `connLocks` TMap. Non-obvious: `withConnLock'` with empty `ConnId` is a no-op (identity function) — allows agent operations on entities without real connection IDs to skip locking.

**`withConnLocks`**: Takes a `Set ConnId` and acquires locks for all connections. Uses `withGetLocks` which acquires all locks concurrently via `forConcurrently`. Note: concurrent acquisition of overlapping lock sets from different threads could theoretically deadlock, so callers must ensure non-overlapping lock sets or use a higher-level coordination.

**`getMapLock`**: Creates a lock on first access and caches it in the TMap. Locks are never removed — the TMap grows monotonically.

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
5. Clears delivery and async command workers (delivery workers are also cancelled via `cancelWorker`)
6. Clears subscription state

The cancellation of resubscription workers reads the TMVar first (to get the Async handle), then calls `uninterruptibleCancel`. This is wrapped in a forked thread to avoid blocking the shutdown sequence.

**`closeClient_` edge case**: When closing individual clients, `closeClient_` handles `BlockedIndefinitelyOnSTM` — which occurs if the SessionVar TMVar was never filled (connection attempt in progress when shutdown started). The exception is caught and treated as a no-op.

**`reconnectServerClients` vs `closeProtocolServerClients`**: `closeProtocolServerClients` swaps the map to empty and closes all clients — no new connections can be made to those sessions. `reconnectServerClients` reads the map without clearing it and closes current clients — the disconnect callbacks trigger reconnection, effectively forcing fresh connections while keeping the session entries.

## Transport session modes

`TransportSessionMode` (`TSMEntity` vs other) determines whether the transport session key includes the entity ID (connection/queue ID). When `TSMEntity`, each queue gets its own TLS connection to the router. When not, queues to the same router share a connection. This is controlled by `sessionMode` in the network config.

`mkSMPTSession` and related functions compute the transport session key based on the current mode. This affects connection multiplexing — entity-mode sessions provide better privacy (router can't correlate queues) at the cost of more connections.

## getMsgLocks — GET exclusion

`getQueueMessage` creates a TMVar lock keyed by `(server, rcvId)` and takes it before sending GET. This prevents concurrent GET and SUB on the same queue (SUB is checked via `hasGetLock` in `checkQueues`). The lock is released by `releaseGetLock` after ACK or on error.

The lock creation uses `TM.alterF` to atomically create-or-reuse: if no lock exists, creates a new `TMVar ()` and immediately takes it; if one exists, takes it. This avoids a race between two concurrent GET attempts on the same queue.

## Error classification — temporaryAgentError

Classifies errors as temporary (retryable) or permanent. Notable non-obvious classifications:
- `TEHandshake BAD_SERVICE` is temporary — it indicates a DB error on the router, not a permanent rejection
- `CRITICAL True` is temporary — `True` means the error shows a restart button, implying the user should retry. `CRITICAL False` is permanent.
- `INACTIVE` is temporary — the agent may be reactivated
- `SMP.PROXY NO_SESSION` via proxy is temporary — session can be re-established
- `SMP.STORE _` is temporary — router-side store error, not a client issue

`temporaryOrHostError` extends `temporaryAgentError` to also include host-related errors (`HOST`, `TRANSPORT TEVersion`). Used in subscription management where host errors should trigger resubscription rather than permanent failure.
