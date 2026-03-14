# Agent Infrastructure

The Agent's internal machinery: worker lifecycle, command dispatch, message delivery, subscription tracking, operation suspension, protocol client management, and dual-backend store. These cross-module patterns are not visible from any single module spec.

This document covers the "big agent" (`Agent.hs` + `Agent/Client.hs`) used in client applications. The "small agent" (`SMPClientAgent`) used in routers is documented in [clients.md](../clients.md).

For per-module details: [Agent](../modules/Simplex/Messaging/Agent.md) · [Agent Client](../modules/Simplex/Messaging/Agent/Client.md) · [Store Interface](../modules/Simplex/Messaging/Agent/Store/Interface.md) · [NtfSubSupervisor](../modules/Simplex/Messaging/Agent/NtfSubSupervisor.md) · [XFTP Agent](../modules/Simplex/FileTransfer/Agent.md). For the component diagram, see [agent.md](../agent.md).

- [Worker framework](#worker-framework)
- [Async command processing](#async-command-processing)
- [Message delivery](#message-delivery)
- [Subscription tracking](#subscription-tracking)
- [Operation suspension cascade](#operation-suspension-cascade)
- [SessionVar lifecycle](#sessionvar-lifecycle)
- [Dual-backend store](#dual-backend-store)

---

## Worker framework

**Source**: [Agent/Client.hs](../../src/Simplex/Messaging/Agent/Client.hs), [Agent/Env/SQLite.hs](../../src/Simplex/Messaging/Agent/Env/SQLite.hs) (Worker type)

All agent background processing - async commands, message delivery, notification workers, XFTP workers - uses a shared worker infrastructure defined in `Agent/Client.hs`.

**Create-or-reuse**: `getAgentWorker` atomically checks a `TMap` for an existing worker keyed by the work item (connection+server, send queue address, etc.). If absent, creates a new `Worker` with a unique monotonic `workerId` from `workerSeq` and inserts it. If present and `hasWork=True`, signals the existing worker via `tryPutTMVar doWork ()`.

**Fork and run**: `runWorkerAsync` uses bracket on the worker's `action` TMVar. If the taken value is `Nothing`, the worker is idle - start it. If `Just _`, it's already running - put it back and return. The `action` TMVar holds `Just (Weak ThreadId)` to avoid preventing GC of the worker thread.

**Task retrieval race prevention**: `withWork` clears the `doWork` flag *before* calling `getWork` (not after). This prevents a race: query finds nothing → another thread adds work + signals → worker clears flag (losing the signal). By clearing first, any signal that arrives during the query is preserved.

**Error classification**: `withWork` distinguishes two failure modes:
- *Work-item error* (`isWorkItemError`): the task itself is broken (likely recurring). Worker stops and sends `CRITICAL False`.
- *Other error*: any non-work-item error (e.g., transient database issue). Worker re-signals `doWork` and reports `INTERNAL` (retry may succeed).

**Restart rate limiting**: On worker exit, `restartOrDelete` checks the `restarts` counter against `maxWorkerRestartsPerMin`. Under the limit: reset action, re-signal, restart. Over the limit: delete the worker from the map and send `CRITICAL True` (escalation to the application). A restart only proceeds if the `workerId` in the map still matches the current worker - a stale restart from a replaced worker is a no-op.

**Consumers**: Four families use this framework:
- Async command workers - keyed by `(ConnId, Maybe SMPServer)`, in `asyncCmdWorkers` TMap
- Delivery workers - keyed by `SndQAddr`, in `smpDeliveryWorkers` TMap, paired with a `TMVar ()` retry lock
- NTF workers - three pools (`ntfWorkers` per NTF server, `ntfSMPWorkers` per SMP server, `ntfTknDelWorkers` for token deletion) in `NtfSubSupervisor`
- XFTP workers - three worker types (rcv, snd, del) with TMVar-based connection sharing

---

## Async command processing

**Source**: [Agent.hs](../../src/Simplex/Messaging/Agent.hs), [Agent/Protocol.hs](../../src/Simplex/Messaging/Agent/Protocol.hs) (command types), [Agent/Store.hs](../../src/Simplex/Messaging/Agent/Store.hs) (internal command types)

Async commands handle state transitions that require network calls but shouldn't block the API thread: securing queues, deleting old queues during rotation, acknowledging messages. The dispatch loop `runCommandProcessing` runs one worker per `(ConnId, Maybe SMPServer)` key.

**Enqueueing**: API functions call `enqueueCommand`, which persists the command to the `commands` table (crash-safe) and spawns/wakes the worker via `getAsyncCmdWorker`. On agent startup, `resumeAllCommands` fetches all pending commands grouped by connection+server and signals their workers.

**Command types**: Two categories share the same dispatch loop:
- *Client commands* (`AClientCommand`): `NEW`, `JOIN`, `LET` (allow connection), `ACK`, `LSET`/`LGET` (set/get connection link data), `SWCH` (switch queue), `DEL`. Triggered by application API calls.
- *Internal commands* (`AInternalCommand`): `ICAck` (ack to router), `ICAckDel` (ack + delete local message), `ICAllowSecure`/`ICDuplexSecure` (secure after confirmation), `ICQSecure` (secure queue during switch), `ICQDelete` (delete old queue after switch), `ICDeleteConn` (delete connection), `ICDeleteRcvQueue` (delete specific receive queue). Generated *during* message processing to handle state transitions asynchronously.

**Retry and movement**: `tryMoveableCommand` wraps execution with `withRetryInterval`. On `temporaryOrHostError`, it retries with backoff. Individual command handlers can return `CCMoved` (e.g., when a queue has moved to a different router) after updating the command's server field in the store - `tryMoveableCommand` then exits cleanly, letting the moved command be picked up by the appropriate worker.

**Locking**: State-sensitive commands use `tryWithLock` / `tryMoveableWithLock`, which acquire `withConnLock` before execution. This serializes operations on the same connection, preventing races between concurrent command processing and message receipt.

**Event overflow**: Events are written directly to `subQ` if there is room. When `subQ` is full, events overflow into a local `pendingCmds` list and are flushed to `subQ` after the command completes, providing backpressure handling.

---

## Message delivery

**Source**: [Agent.hs](../../src/Simplex/Messaging/Agent.hs), [Agent/RetryInterval.hs](../../src/Simplex/Messaging/Agent/RetryInterval.hs)

Message delivery uses a split-phase encryption design: the ratchet advances in the API thread (serialized), while the actual body encryption happens in the per-queue delivery worker (parallel). This avoids ratchet lock contention across queues.

**Phase 1 - API thread** (`enqueueMessageB`):
1. Encode the agent message with `internalSndId` + `prevMsgHash` (for the receiver's integrity chain)
2. Call `agentRatchetEncryptHeader` - advances the double ratchet, produces a message encryption key (MEK), padded length, and PQ encryption status
3. Store `SndMsg` with `SndMsgPrepData` (MEK, paddedLen, sndMsgBodyId) in the database
4. Create `SndMsgDelivery` record for each send queue
5. `submitPendingMsg` - increments `msgDeliveryOp.opsInProgress` (for suspension tracking) and signals delivery workers via `getDeliveryWorker`

**Phase 2 - delivery worker** (`runSmpQueueMsgDelivery`):
1. `throwWhenNoDelivery` - kills the worker thread if the queue's address has been removed from `smpDeliveryWorkers` (prevents delivery to queues replaced during switch)
2. `getPendingQueueMsg` - fetches the next pending message from the store, resolving the `sndMsgBodyId` reference into the actual message body and constructing `PendingMsgPrepData`
3. Re-encode the message with `internalSndId`/`prevMsgHash`, then `rcEncryptMsg` to encrypt with the stored MEK (no ratchet access needed)
4. `sendAgentMessage` - per-queue encrypt + SEND to the router

**Connection info messages** (`AM_CONN_INFO`, `AM_CONN_INFO_REPLY`) skip split-phase encryption entirely - they are sent as per-queue E2E encrypted confirmation bodies via `sendConfirmation` (encrypted with `agentCbEncrypt`, not with the double ratchet).

**Retry with dual intervals**: Delivery uses `withRetryLock2`, which maintains two retry interval states (slow and fast) but only one wait is active at a time. A background thread sleeps for the current interval, then signals the delivery worker via `tryPutTMVar`. When the router sends `QCONT` (queue buffer cleared), the agent calls `tryPutTMVar retryLock ()` to wake the delivery thread immediately, avoiding unnecessary delay.

**Error handling**:
- `SMP QUOTA` - switch to slow retry, don't penalize (backpressure from router)
- `SMP AUTH` - permanent failure: for data messages, notify and delete; for handshake messages, report connection error; for queue-switch messages, report queue error
- `temporaryOrHostError` - retry with backoff
- Other errors - report to application, delete command

---

## Subscription tracking

**Source**: [Agent/TSessionSubs.hs](../../src/Simplex/Messaging/Agent/TSessionSubs.hs), [Agent/Client.hs](../../src/Simplex/Messaging/Agent/Client.hs)

The agent tracks per-queue subscription state in `TSessionSubs` (defined in `Agent/TSessionSubs.hs`), keyed by `SMPTransportSession = (UserId, SMPServer, Maybe ByteString)` where the `ByteString` carries the entity ID in entity-session mode or `Nothing` in shared mode. Each transport session holds:

```
SessSubs
├── subsSessId    :: TVar (Maybe SessionId)  -- TLS session ID
├── activeSubs    :: TMap RecipientId RcvQueueSub
├── pendingSubs   :: TMap RecipientId RcvQueueSub
├── activeServiceSub  :: TVar (Maybe ServiceSub)
└── pendingServiceSub :: TVar (Maybe ServiceSub)
```

**State machine**: Subscriptions move between three states:

- **Pending → Active**: After subscription RPC succeeds, `addActiveSub'` promotes the queue - but only if the returned session ID matches the stored TLS session ID (`Just sessId == sessId'`). On mismatch (TLS reconnected between RPC send and response), the subscription is silently added to pending instead. No exception - concurrent resubscription paths handle this naturally.

- **Active → Pending**: When `setSessionId` is called with a *different* session ID (TLS reconnect), all active subscriptions are atomically demoted to pending. Session ID is updated to the new value.

- **Pending → Removed**: `failSubscriptions` moves permanently-failed queues (non-temporary SMP errors) to `removedSubs` - a separate `TMap` in `AgentClient`, not part of `TSessionSubs`. The removal is tracked for diagnostic reporting via `getSubscriptions`.

**Service-associated queues**: Queues with `serviceAssoc=True` are *not* added to `activeSubs` individually. Instead, the service subscription's count is incremented and its `idsHash` XOR-accumulates the queue's hash. The router tracks individual queues via the service subscription; the agent only tracks the aggregate. Consequence: `hasActiveSub(rId)` returns `False` for service-associated queues - callers must check the service subscription separately.

**Disconnect cleanup** (`smpClientDisconnected`):
1. `removeSessVar` with CAS check (monotonic `sessionVarId` prevents stale callbacks from removing newer clients)
2. `setSubsPending` - demote active→pending, filtered by matching `SessionId` only
3. Delete proxied relay sessions created by this client
4. Fire `DISCONNECT`, `DOWN` (affected connections), `SERVICE_DOWN` (if service sub existed)
5. Release GET locks for affected queues
6. Resubscribe: either spawn `resubscribeSMPSession` worker (entity-session mode) or directly resubscribe queues and services (other modes)

**Resubscription worker**: Per-transport-session worker with exponential backoff. Loops until `pendingSubs` and `pendingServiceSub` are both empty. Uses `waitForUserNetwork` with bounded wait - proceeds even without network (prevents indefinite blocking). Worker self-cleans via `removeSessVar` on exit.

**UP event deduplication**: After a batch subscription RPC, `UP` events are emitted only for connections that were *not* already in `activeSubs` before the batch. This prevents duplicate notifications for already-subscribed connections.

---

## Operation suspension cascade

**Source**: [Agent/Client.hs](../../src/Simplex/Messaging/Agent/Client.hs)

Five `AgentOpState` TVars track in-flight operations for graceful shutdown. Each holds `{opSuspended :: Bool, opsInProgress :: Int}`.

**Cascade ordering**:
```
AONtfNetwork  (independent - no cascading)

AORcvNetwork → AOMsgDelivery → AOSndNetwork → AODatabase
```

**Mechanics**: `endAgentOperation` decrements `opsInProgress`. If the count reaches zero and the operation is suspended, it calls the cascade action: `AORcvNetwork` suspends `AOMsgDelivery`, which suspends `AOSndNetwork`, which suspends `AODatabase`. At the leaf (`AODatabase`), `notifySuspended` writes `SUSPENDED` to `subQ` and sets `agentState = ASSuspended`.

**Blocking**: `beginAgentOperation` blocks (STM `retry`) while `opSuspended == True`. This means new operations of a suspended type cannot start - they wait until the operation is resumed. `agentOperationBracket` provides structured bracketing (begin on entry, end on exit).

**Two wait modes**:
- `waitWhileSuspended` - blocks only during `ASSuspended`, proceeds during `ASSuspending` (allows in-flight operations to complete)
- `waitUntilForeground` - blocks during both `ASSuspending` and `ASSuspended` (stricter, for operations that need full foreground)

**Usage**: `withStore` brackets all database access with `AODatabase`. Message delivery uses `AOSndNetwork` + `AOMsgDelivery`. Receive processing uses `AORcvNetwork`. This ensures that suspending receive processing cascades through delivery to database, and nothing touches the database after all operations drain.

---

## SessionVar lifecycle

**Source**: [Agent/Client.hs](../../src/Simplex/Messaging/Agent/Client.hs)

Protocol client connections (SMP, XFTP, NTF) use a lazy singleton pattern via `SessionVar` - a `TMVar` in a `TMap` keyed by transport session.

**Connection**: `getSessVar` atomically checks the TMap. Returns `Left newVar` (absent - caller must connect) or `Right existingVar` (present - wait for result). `newProtocolClient` wraps the connection attempt: on success, fills the TMVar with `Right client` and writes `CONNECT` event; on failure, fills with `Left (error, maybeRetryTime)` and re-throws.

**Error caching**: Failed connections cache the error with an expiry timestamp based on `persistErrorInterval`. Future attempts during the interval immediately receive the cached error without reconnecting - this prevents connection storms when a router is down. When `persistErrorInterval == 0`, the SessionVar is removed immediately on failure (fresh connection on next attempt).

**Compare-and-swap**: Each SessionVar has a monotonic `sessionVarId` from `workerSeq`. `removeSessVar` only removes if the `sessionVarId` matches the current map entry. This prevents a stale disconnect callback (from an old client) from removing a newer client that connected after the old one disconnected.

**Service credential synchronization** (`updateClientService`): On SMP reconnect, the agent reconciles service credentials between client and router state - updating, creating, or removing service associations as needed. Router version downgrade (router loses service support) triggers client-side service deletion.

**XFTP special case**: `getProtocolServerClient` ignores the caller's `NetworkRequestMode` parameter for XFTP, always using `NRMBackground` timing. XFTP connections always use background retry timing regardless of the caller's request.

---

## Dual-backend store

**Source**: [Agent/Store/SQLite.hs](../../src/Simplex/Messaging/Agent/Store/SQLite.hs), [Agent/Store/Postgres.hs](../../src/Simplex/Messaging/Agent/Store/Postgres.hs), [Agent/Store/AgentStore.hs](../../src/Simplex/Messaging/Agent/Store/AgentStore.hs)

The agent supports SQLite and PostgreSQL via CPP compilation flags (`#if defined(dbPostgres)`). Three wrapper modules (`Interface.hs`, `Common.hs`, `DB.hs`) re-export the appropriate backend. A single binary compiles with one active backend.

**Key behavioral differences**:

| Aspect | SQLite | PostgreSQL |
|--------|--------|------------|
| Row locking | Single-writer model (no locking needed) | `FOR UPDATE` on reads preceding writes |
| Batch queries | Per-row `forM` loops | `IN ?` with `In` wrapper |
| Constraint violations | `SQL.ErrorConstraint` pattern match | `constraintViolation` function |
| Transaction savepoints | Not needed | Used in `createWithRandomId'` (failed statement aborts entire transaction without them) |
| Busy/locked errors | `ErrorBusy`/`ErrorLocked` → `SEDatabaseBusy` → `CRITICAL True` | All SQL errors → `SEInternal` |

**Store access bracketing**: `withStore` wraps all database operations with `agentOperationBracket AODatabase`, connecting the store to the suspension cascade. `withStoreBatch` / `withStoreBatch'` run multiple operations in a single transaction with per-operation error catching.

**Known bug**: `checkConfirmedSndQueueExists_` uses `#if defined(dpPostgres)` (typo - should be `dbPostgres`), so the `FOR UPDATE` clause is never included on either backend.
