# Parallel Message Processing - Eliminate Single-Thread Bottlenecks

## Problem

Message reception flows through two single-thread bottlenecks:

1. **Agent `msgQ` bottleneck**: Multiple SMP server connections write to one shared `TBQueue` (`AgentClient.msgQ` / `SMPClientAgent.msgQ`). A single `subscriber` thread reads and processes all messages sequentially - DB lookups, double-ratchet decryption, DB writes - regardless of which connection they came from.

2. **Chat `subQ` bottleneck**: The agent's `subscriber` thread writes processed events to one shared `TBQueue` (`AgentClient.subQ`). A single `agentSubscriber` thread in simplex-chat reads and processes all events sequentially.

Both bottlenecks serialize work that could run in parallel, since messages from different connections are independent.

## Solution

Replace queues with callbacks at both layers. The producer calls a processing function directly in its own thread.

### Layer 1: SMP client - eliminate `msgQ`

**Current flow:**
```
SMP connection thread -> writeTBQueue msgQ -> subscriber thread -> processSMPTransmissions
```

**New flow:**
```
SMP connection thread -> processMsg callback (with per-client MVar lock)
```

**Why the MVar lock:** Within one SMP client, two threads produce messages:
- The receive loop (`processMsgs` in `Client.hs:686`)
- `writeSMPMessage` (`Client.hs:874`) - called from `processSUBResponse_` when a SUB response includes an inline MSG

These two must be serialized within one client. An MVar lock ensures they take turns calling the callback. Across different clients (different server connections), no lock is shared - natural parallelism.

#### Changes

**`src/Simplex/Messaging/Client.hs`:**
- In `PClient`: replace `msgQ :: Maybe (TBQueue ...)` with `processServerMsg :: Maybe (ServerTransmissionBatch v err msg -> IO ())` and `processLock :: MVar ()`
- `processMsgs`: acquire `processLock`, call `processServerMsg` with the batch
- `writeSMPMessage`: acquire `processLock`, call `processServerMsg`
- `getProtocolClient`: takes `Maybe (ServerTransmissionBatch v err msg -> IO ())` instead of `Maybe (TBQueue ...)`
- `smpClientStub`: sets `processServerMsg = Nothing`
- `serverTransmission`: unchanged

**`src/Simplex/Messaging/Agent/Client.hs`:**
- Remove `msgQ` field from `AgentClient`
- `smpConnectClient`: pass `processSMPTransmissions` wrapper as callback instead of `Just msgQ`
- Remove `AgentQueuesInfo` and `getAgentQueuesInfo` entirely (dead with no queues to monitor)
- Add `inflightCallbacks :: TVar Int` for monitoring instead - increment before callback, decrement in bracket

**`src/Simplex/Messaging/Agent.hs`:**
- Remove `subscriber` function
- Remove `subscriber` from `runAgentThreads`
- `processSMPTransmissions` stays, called directly from SMP client threads
- `agentOperationBracket c AORcvNetwork` moves into the callback wrapper
- Exception handling: wrap callback with `catchOwn` matching current `subscriber`'s error handling

**`src/Simplex/Messaging/Client/Agent.hs`:**
- `SMPClientAgent`: replace `msgQ` with callback field `processServerMsg :: ServerTransmissionBatch SMPVersion ErrorType BrokerMsg -> IO ()`
- `newSMPClientAgent`: takes callback parameter instead of creating `msgQ`
- `connectClient`: passes callback to `getProtocolClient`

**`src/Simplex/Messaging/Notifications/Server.hs`:**
- `ntfSubscriber`: remove `receiveSMP` loop; the processing logic becomes the callback passed via `SMPClientAgent`
- Processing stays in M (via `UnliftIO` or pre-bound env)

**Tests (`tests/SMPProxyTests.hs`):**
- 2 sites: change `getProtocolClient ... (Just msgQ) ...` to pass a callback that writes to a local test TBQueue

### Layer 2: Agent to chat - eliminate `subQ`

**Current flow:**
```
agent processSMPTransmissions -> writeTBQueue subQ -> chat agentSubscriber -> process
```

**New flow:**
```
agent processSMPTransmissions -> processEvent callback [events]
```

**Key design decisions:**
- Callback takes `[ATransmission]` (list), not single event. All events from one connection batch are passed together to maintain ordering within a connection.
- Error notifications (currently `nonBlockingWriteTBQueue`) use `forkIO $ callback [event]` - fire-and-forget, order doesn't matter for errors.
- The `isFullTBQueue subQ` / pending mechanism disappears - the callback receives the full list directly, no need to buffer/flush.
- `AgentClient` keeps `testQ :: Maybe (TBQueue ATransmission)` for tests only.

#### Changes

**`src/Simplex/Messaging/Agent/Client.hs`:**
- Replace `subQ :: TBQueue ATransmission` with:
  - `processEvent :: [ATransmission] -> IO ()` - callback, accepts event list
  - `testQ :: Maybe (TBQueue ATransmission)` - test-only, `Nothing` in production
- Remove `AgentQueuesInfo` / `getAgentQueuesInfo`
- Add `inflightCallbacks :: TVar Int` with bracket: `withInflight c $ processEvent c events`

**`src/Simplex/Messaging/Agent.hs`:**
- `processSMPTransmissions`: accumulate events in a local list (currently uses `pendingMsgs` TVar + flush pattern). Call `processEvent` once at end with the full list.
- `runCommandProcessing`: same - call `processEvent` once with all events for the command batch. Remove `isFullTBQueue`/pending logic.
- All `notify`/`notify'` helpers within `processSMPTransmissions` write to a local `TVar [ATransmission]` instead of directly to `subQ`. Flushed at end as single `processEvent` call.
- Error sites (currently `nonBlockingWriteTBQueue`): use `forkIO $ processEvent c [event]`
- Other direct `writeTBQueue subQ` sites (CONNECT/DISCONNECT events, SUSPENDED, etc.): call `processEvent c [event]` directly.
- Remove `subscriber` function entirely.
- Exception safety: `processEvent` call wrapped in bracket that catches "own" exceptions and logs them.

**`src/Simplex/Messaging/Agent/Client.hs`:**
- `notifySub'` (line 838): change to `forkIO $ processEvent c [event]` (non-blocking error notification)

**`src/Simplex/Messaging/Agent/NtfSubSupervisor.hs`:**
- 1 site: change `nonBlockingWriteTBQueue subQ event` to `forkIO $ processEvent c [event]`

**`src/Simplex/FileTransfer/Agent.hs`:**
- 1 site (line 351): `notify` helper changes to `processEvent c [event]`

**`simplex-chat/src/Simplex/Chat/Library/Commands.hs`:**
- Remove `agentSubscriber` thread
- Pass chat's `process` function (adapted to accept `[ATransmission]`) as `processEvent` callback at agent initialization

**Tests:**
- `pGet` changes from `readTBQueue (subQ c)` to `readTBQueue (fromJust $ testQ c)` - 1 line
- Agent test setup: `processEvent = mapM_ (atomically . writeTBQueue q)` where `q` is `testQ`
- ~348 test call sites unchanged

## Concurrency Safety

- **Per-SMP-connection:** MVar in each SMP client serializes `processMsgs` and `writeSMPMessage`
- **Cross-connection:** Different SMP clients have different MVars, run in different threads - fully parallel
- **Per-connection-id:** `withConnLock connId` in `processSMPTransmissions` handles per-connection locking
- **Chat callback:** Must be safe for concurrent calls from different agent threads. Chat dispatches by entity type and connection ID; individual handlers use their own locks.
- **Exception safety:** Callback wrapped with bracket pattern - catches own exceptions, logs, decrements inflight counter. Exceptions don't kill SMP client threads.

## Implementation Order

Both layers change in one PR since they share `Client.hs`.

### Phase 1: SMP client callback (`Client.hs` + both agent types)

- [ ] 1.1 `Client.hs`: Replace `msgQ` with `processServerMsg` callback + `processLock` MVar in `PClient`
- [ ] 1.2 `Client.hs`: Update `processMsgs`, `writeSMPMessage`, `getProtocolClient`, `smpClientStub`
- [ ] 1.3 `Client/Agent.hs`: Replace `msgQ` in `SMPClientAgent` with callback field, update `newSMPClientAgent`, `connectClient`
- [ ] 1.4 `Agent/Client.hs`: Remove `msgQ` from `AgentClient`, update `smpConnectClient` to pass `processSMPTransmissions` as callback
- [ ] 1.5 `Agent.hs`: Remove `subscriber` thread from `runAgentThreads`, add exception wrapper to callback
- [ ] 1.6 `Notifications/Server.hs`: Convert `receiveSMP` from loop to callback passed to `SMPClientAgent`
- [ ] 1.7 `SMPProxyTests.hs`: Update 2 call sites to use callback + local test queue

### Phase 2: Agent event callback (`subQ` -> `processEvent`)

- [ ] 2.1 `Agent/Client.hs`: Add `processEvent :: [ATransmission] -> IO ()` and `testQ :: Maybe (TBQueue ATransmission)`, remove `subQ`, remove `AgentQueuesInfo`
- [ ] 2.2 `Agent.hs`: Rewrite `processSMPTransmissions` to accumulate events in local list and call `processEvent` once at end
- [ ] 2.3 `Agent.hs`: Update `runCommandProcessing` - remove pending/isFullTBQueue pattern, call `processEvent` with list
- [ ] 2.4 `Agent.hs`, `Agent/Client.hs`, `NtfSubSupervisor.hs`, `FileTransfer/Agent.hs`: Update all `writeTBQueue subQ` / `nonBlockingWriteTBQueue subQ` sites (~32 total)
- [ ] 2.5 `Agent/Client.hs`: Add inflight counter with bracket
- [ ] 2.6 Update `pGet` to read from `testQ` (1 line), update test agent setup
- [ ] 2.7 `simplex-chat`: Pass chat's `process` as callback, remove `agentSubscriber`
- [ ] 2.8 Fix any multi-server test ordering issues

## Risks

- **Chat thread safety:** Chat's `process` may not be safe for concurrent calls. Audit needed.
- **Backpressure:** Slow callback blocks SMP client receive thread. Acceptable - the connection that produced the message waits. Cross-connection interference eliminated.
- **Ordering:** Within one SMP connection - preserved (MVar + list callback). Across connections - non-deterministic (same as today, since `msgQ` interleaving was arbitrary). Most tests use 1 server.
