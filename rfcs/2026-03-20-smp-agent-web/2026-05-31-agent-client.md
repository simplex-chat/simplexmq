# Agent Client Middle Layer: Transpilation Plan

**Parent**: [Agent Plan](./2026-05-22-agent.md)
**Depends on**: Store (complete, 98 tests), SMP Client (complete, 99 tests), Ratchet (complete), Agent Protocol Types (complete)

## Rule

Every TypeScript function is a faithful transpilation of a specific Haskell function. Same name, same steps, same call chain. No inferences, no simplifications, no "browser-friendly" shortcuts. The concurrency primitives differ (Promises vs STM, event callbacks vs TBQueue), but the logic, state transitions, and decision paths must be identical.

## Architecture mapping

| Haskell | TypeScript | Notes |
|---------|-----------|-------|
| `TVar a` | mutable variable (object property) | Single-threaded, no atomicity needed |
| `TMap k v` | `Map<K, V>` | No STM, direct mutation |
| `TBQueue a` | `ABQueue<T>` | `subQ` for user events, `msgQ` for server messages |
| `TMVar a` | `Promise` + resolver, or flag | For worker doWork signaling |
| `STM` transaction | synchronous code block | Single-threaded JS, no races |
| `forkIO` / `async` | `setTimeout(0)` / microtask | Event loop scheduling |
| `Worker` thread | delivery loop function | Triggered by `submitPendingMsg`, runs via microtask |
| `ReaderT Env IO` (AM') | closure over agent state | Config + store + DRG captured in closure |
| `ExceptT AgentErrorType` (AM) | thrown errors / Result type | TBD: throw vs return Either |

## Files to create

| File | Purpose |
|------|---------|
| `smp-web/src/agent/queue.ts` | Sem, ABQueue (copied from simplex-chat) |
| `smp-web/src/agent/tmvar.ts` | TMVar — single-cell blocking variable |
| `smp-web/src/agent/session.ts` | SessionVar, getSessVar (Promise-based) |
| `smp-web/src/agent/retry.ts` | RetryInterval, RetryInterval2, withRetryLock2 |
| `smp-web/src/agent/subscriptions.ts` | TSessionSubs transpilation |
| `smp-web/src/agent/client.ts` | AgentClient state, session management, worker infrastructure, queue operations |
| `smp-web/src/agent/agent.ts` | Top-level agent API (joinConnection, sendMessage, etc.) |
| `smp-web/tests/agent-repl.ts` | Agent-level REPL for cross-language testing |

## Implementation order

Each step produces a testable artifact.

### Step 1: Pure infrastructure (TS-only tests)
- `queue.ts` — Sem, ABQueue (copied verbatim from simplex-chat)
- `tmvar.ts` — TMVar (new)
- `session.ts` — SessionVar, getSessVar, removeSessVar, tryReadSessVar
- `retry.ts` — RetryInterval types + nextRetryDelay + withRetryInterval + withRetryLock2
- `subscriptions.ts` — TSessionSubs (all 22 functions)
- **Test**: TS unit tests for each module — no server needed

### Step 2: AgentClient state + worker infrastructure (TS-only tests)
- AgentClient record, newAgentClient
- Worker, newWorker, getAgentWorker, runWorkerAsync, waitForWork, hasWorkToDo, withWork
- AgentOpState, operation bracket, suspend/resume
- Locking (withConnLock, withInvLock)
- Server selection (userServers, pickServer, getNextServer, withNextSrv)
- Store wrappers (withStore, withStore', storeError)
- **Test**: TS tests — create agent client, test worker lifecycle, test server selection

### Step 3: SMP session management + queue operations (cross-language via agent-repl)
- getSMPServerClient, smpConnectClient, smpClientDisconnected
- getSMPProxyClient, withProxySession
- withClient_, withClient, withSMPClient
- sendOrProxySMPMessage, sendOrProxySMPCommand
- newRcvQueue, newRcvQueue_
- agentCbEncrypt, agentCbEncryptOnce, agentCbDecrypt
- sendConfirmation, sendInvitation, sendAgentMessage
- secureQueue, secureSndQueue, sendAck
- decryptSMPMessage
- subscribeQueues, subscribeQueues_, subscribeSessQueues_, processSubResults
- addNewQueueSubscription, resubscribeSMPSession
- **Test via agent-repl**: Haskell creates queue → TS subscribes, TS creates queue → Haskell sends → TS receives+decrypts, TS sends → Haskell receives

### Step 4: Agent message flow (cross-language end-to-end)
- agentRatchetEncrypt, agentRatchetEncryptHeader, agentRatchetDecrypt
- encodeAgentMsgStr
- enqueueMessageB, storeConfirmation, enqueueConfirmation
- submitPendingMsg, getDeliveryWorker, runSmpQueueMsgDelivery
- enqueueCommand, runCommandProcessing
- **Test via agent-repl**: TS encrypts agent message → Haskell decrypts, Haskell encrypts → TS decrypts

### Step 5: Connection handshake + full agent API (cross-language end-to-end)
- newConnToJoin, joinConn, joinConnSrv, startJoinInvitation
- compatibleInvitationUri, compatibleContactUri
- secureConfirmQueue(Async), agentSecureSndQueue
- mkAgentConfirmation, createReplyQueue, newRcvConnSrv, createRcvQueue
- newSndQueue, connectReplyQueues
- allowConnection'
- processSMPTransmissions, subscriber
- decryptClientMessage, agentClientMsg
- smpConfirmation, helloMsg, smpInvitation
- sendMessage', sendMessagesB_
- ackMessage', ackQueueMessage
- subscribeConnection(s)
- **Test**: TS joins invitation URI created by Haskell agent → handshake completes → messages flow both ways → ack

---

## Piece -1: Concurrency primitives

### `Sem` and `ABQueue` — copy from simplex-chat

Copy verbatim from `/code/simplex-chat/packages/simplex-chat-client/typescript/src/queue.ts` into `smp-web/src/agent/queue.ts`.

`Sem` — counting semaphore. `wait()` blocks if permits=0. `signal()` increments and wakes a waiter.
`ABQueue` — async bounded queue. Two semaphores (enq for items, deq for slots). Backpressure on full. Close via sentinel. Implements AsyncIterator.

Used for:
- `subQ` — agent events to user. Agent writes, user reads via `dequeue()` loop or async iterator.
- `msgQ` — WebSocket onmessage enqueues, subscriber loop dequeues and calls `processSMPTransmissions`.
- Queues prevent deadlock: without them, processing a received message that triggers a send, which triggers another event, could cause unbounded reentrancy in single-threaded JS.

### `TMVar<T>` — new, in `smp-web/src/agent/tmvar.ts`

Single-cell mutable variable, empty or full. Blocking take/put/read.

```typescript
class TMVar<T> {
  private val: T | undefined
  private full: boolean
  private takeQ: Array<(v: T) => void> = []  // waiters for value to appear
  private putQ: Array<(v: T) => void> = []   // waiters for cell to empty

  static empty<T>(): TMVar<T>     // create empty
  static new<T>(v: T): TMVar<T>   // create full

  take(): Promise<T>         // block until full, take value, leave empty
  put(v: T): Promise<void>   // block until empty, put value
  read(): Promise<T>         // block until full, return value without taking
  tryTake(): T | undefined   // non-blocking take
  tryPut(v: T): boolean      // non-blocking put, returns false if full
  tryRead(): T | undefined   // non-blocking read
  isEmpty(): boolean
}
```

Used for:
- `doWork :: TMVar ()` — worker signal. `waitForWork` = `read()`. `noWorkToDo` = `tryTake()`. `hasWorkToDo` = `tryPut(undefined)`.
- `action :: TMVar (Maybe ThreadId)` — worker running state. `runWorkerAsync` takes, checks, starts async loop.
- Retry lock in `withRetryLock2`.

The doWork race condition: worker clears FIRST (`tryTake`), THEN checks store. If work found, re-sets (`tryPut`). Any signal arriving during the store check (via `await` yielding to onmessage → `hasWorkToDo`) stays set because it happened after the clear. If we did read-then-clear-if-empty, the clear could swallow a signal set between the store check and the clear.

### Locks — `Sem(1)` or Promise chain

For `withConnLock`, `withInvLock`: `Map<string, Lock>`. Each Lock is either:
- `Sem(1)` — acquire = `wait()`, release = `signal()`, wrap in try/finally
- Or Promise chain (each `withLock` appends to previous promise)

`Sem(1)` is simpler and correct. Wrap in helper:

```typescript
async function withLock(locks: Map<string, Sem>, key: string, fn: () => Promise<T>): Promise<T> {
  let sem = locks.get(key)
  if (!sem) { sem = new Sem(1); locks.set(key, sem) }
  await sem.wait()
  try { return await fn() } finally { sem.signal() }
}
```

### SessionVar — Promise with exposed resolver

`SessionVar` tracks pending protocol client connections. First caller creates a Promise, connects, resolves it. Subsequent callers await the same Promise.

```typescript
interface SessionVar<T> {
  id: number
  ts: number
  promise: Promise<T>
  resolve: (v: T) => void
  reject: (e: Error) => void
  value: T | undefined  // set after resolve, for tryRead
}
```

`getSessVar`: if key exists in Map, return Right (existing). Else create new with unresolved Promise, insert, return Left (new).
`removeSessVar`: delete if ID matches.
`tryReadSessVar`: return `value` if set.

No TMVar needed — Promise coalesces reads naturally.

---

## Piece 0: SessionVar (`session.ts`)

Transpile from `Simplex/Messaging/Session.hs` (43 lines).

| Function | Haskell lines | Purpose |
|----------|--------------|---------|
| `SessionVar` type | 18-22 | `{sessionVar: TMVar a, sessionVarId: number, sessionVarTs: Date}` |
| `getSessVar` | 24-33 | Get existing or create new empty session var for key |
| `removeSessVar` | 35-39 | Remove if ID matches (guards against removing replaced session) |
| `tryReadSessVar` | 41-42 | Non-blocking read of session var value |

Browser: `TMVar a` → `{value: T | undefined, resolve: (() => void) | null}`. `getSessVar` returns Left (new, empty) or Right (existing).

---

## Piece 1: RetryInterval (`retry.ts`)

Transpile from `Agent/RetryInterval.hs` (119 lines).

| Function | Haskell lines | Purpose |
|----------|--------------|---------|
| `RetryInterval` type | 27-31 | `{initialInterval, increaseAfter, maxInterval}` (microseconds) |
| `RetryInterval2` type | 33-36 | `{riSlow, riFast}` |
| `RI2State` type | 38-41 | `{slowInterval, fastInterval}` |
| `RetryIntervalMode` type | 51 | `RISlow \| RIFast` |
| `nextRetryDelay` | 114-118 | Pure: if elapsed < increaseAfter, keep delay; else min(delay*3/2, max) |
| `updateRetryInterval2` | 44-49 | Update RI2 from saved state |
| `withRetryInterval` | 54-55 | Wrapper around withRetryIntervalCount |
| `withRetryIntervalCount` | 57-66 | Loop: action(n, delay, loop); loop sleeps then recurses with updated delay |
| `withRetryLock2` | 90-112 | Two-mode retry with lock: action gets RI2State + loop function that takes mode |

Browser adaptation: `threadDelay'` → `setTimeout` wrapped in Promise. `TMVar` lock → Promise-based signal. Logic identical.

---

## Piece 2: TSessionSubs (`subscriptions.ts`)

Transpile from `Agent/TSessionSubs.hs` (202 lines). Every function, every branch.

Transport session key: `(UserId, SMPServer)` — serialized to string for Map key. One session per server, no per-entity multiplexing.

| Function | Haskell lines | Purpose |
|----------|--------------|---------|
| `TSessionSubs` type | 49-51 | `Map<string, SessSubs>` (string = serialized transport session) |
| `SessSubs` type | 53-57 | `{sessId: SessionId \| null, activeSubs: Map<string, RcvQueueSub>, pendingSubs: Map<string, RcvQueueSub>}` |
| `emptyIO` | 59-61 | Create empty TSessionSubs |
| `clear` | 63-65 | Clear all |
| `getSessSubs` | 71-77 | Get or create SessSubs for a transport session |
| `hasActiveSub` | 79-81 | Check if rcvId has active subscription |
| `hasPendingSub` | 83-85 | Check if rcvId has pending subscription |
| `addPendingSub` | 91-92 | Add to pendingSubs |
| `setSessionId` | 94-99 | Set session ID; if changed, move active→pending |
| `addActiveSub` | 101-110 | If sessId matches, add to active + remove from pending; else add to pending |
| `batchAddActiveSubs` | 112-121 | Batch version of addActiveSub |
| `batchAddPendingSubs` | 123-126 | Batch add to pending |
| `deletePendingSub` | 128-129 | Delete from pending |
| `batchDeletePendingSubs` | 131-134 | Batch delete from pending |
| `deleteSub` | 136-137 | Delete from both active and pending |
| `batchDeleteSubs` | 139-143 | Batch delete from both |
| `hasPendingSubs` | 145-146 | Check if any pending exist for session |
| `getPendingSubs` | 148-150 | Get all pending for session |
| `getActiveSubs` | 152-154 | Get all active for session |
| `setSubsPending` | 159-177 | Move active→pending on disconnect; handles session mode transitions |
| `setSubsPending_` | 179-187 | Internal: write new sessId, move active→pending |
| `updateClientNotices` | 189-192 | Update clientNoticeId on pending subs |
| `foldSessionSubs` | 194-195 | Fold over all sessions |
| `mapSubs` | 197-201 | Map over active and pending |

Critical: `setSubsPending` has mode-dependent logic (TSMEntity vs TSMUser/TSMServer). Must be transpiled exactly.

---

## Piece 3: AgentClient state + worker infrastructure (`client.ts`)

### AgentClient state

Transpile from `AgentClient` record (Client.hs:328-378) and `newAgentClient` (Client.hs:498-584).

| Field | Haskell type | TS type | Purpose |
|-------|-------------|---------|---------|
| `active` | `TVar Bool` | `boolean` | Is agent active |
| `subQ` | `TBQueue ATransmission` | `ABQueue` | Events to user |
| `msgQ` | `TBQueue (ServerTransmissionBatch ...)` | `ABQueue` | WebSocket onmessage enqueues, subscriber dequeues |
| `smpServers` | `TMap UserId (UserServers 'PSMP)` | `Map<UserId, UserServers>` | Server configs per user |
| `smpClients` | `TMap SMPTransportSession SMPClientVar` | `Map<string, SMPClient \| Promise<SMPClient>>` | Active SMP connections |
| `smpProxiedRelays` | `TMap SMPTransportSession SMPServerWithAuth` | `Map<string, SMPServerWithAuth>` | Proxy routing |
| `useNetworkConfig` | `TVar (NetworkConfig, NetworkConfig)` | `{slow: NetworkConfig, fast: NetworkConfig}` | Network config |
| `userNetworkInfo` | `TVar UserNetworkInfo` | `UserNetworkInfo` | Online/offline state |
| `subscrConns` | `TVar (Set ConnId)` | `Set<string>` | Connections being subscribed |
| `currentSubs` | `TSessionSubs` | `TSessionSubs` | Active/pending subscriptions |
| `removedSubs` | `TMap ...` | `Map<string, Map<string, SMPClientError>>` | Failed subscriptions |
| `workerSeq` | `TVar Int` | `number` | Worker ID sequence |
| `smpDeliveryWorkers` | `TMap SndQAddr (Worker, TMVar ())` | `Map<string, DeliveryWorker>` | Per-queue delivery workers |
| `asyncCmdWorkers` | `TMap (ConnId, Maybe SMPServer) Worker` | `Map<string, Worker>` | Async command workers |
| `rcvNetworkOp` | `TVar AgentOpState` | `AgentOpState` | Receive operation state |
| `msgDeliveryOp` | `TVar AgentOpState` | `AgentOpState` | Delivery operation state |
| `sndNetworkOp` | `TVar AgentOpState` | `AgentOpState` | Send operation state |
| `agentState` | `TVar AgentState` | `AgentState` | Foreground/suspended/suspending |
| `connLocks` | `TMap ConnId Lock` | `Map<string, Promise<void>>` | Connection locks |
| `invLocks` | `TMap ByteString Lock` | `Map<string, Promise<void>>` | Invitation locks |
| `agentEnv` | `Env` | closure | Config + store + RNG |

Fields NOT needed for MVP: `ntfServers`, `ntfClients`, `xftpServers`, `xftpClients`, `smpSubWorkers`, `clientNotices`, `clientNoticesLock`, `getMsgLocks`, `deleteLock`, `proxySessTs`, `*Stats`, `srvStatsStartedAt`, `acThread`, `presetDomains`, `presetServers`.

### Worker infrastructure

| Function | Haskell location | Purpose |
|----------|-----------------|---------|
| `Worker` type | Env/SQLite.hs:317-322 | `{workerId, doWork: TMVar (), action: TMVar (Maybe ThreadId), restarts}` |
| `RestartCount` type | Env/SQLite.hs:324-327 | `{restartMinute, restartCount}` |
| `updateRestartCount` | Env/SQLite.hs:329-332 | Reset count if minute changed, else increment |
| `newWorker` | Client.hs:439-445 | Create worker with doWork TMVar |
| `getAgentWorker` | Client.hs:387-389 | Get-or-create worker for key |
| `getAgentWorker'` | Client.hs:391-437 | Full version with restart logic |
| `runWorkerAsync` | Client.hs:447-454 | Start worker if not running |
| `waitForWork` | Client.hs:2118-2119 | Block until doWork has value |
| `hasWorkToDo` / `hasWorkToDo'` | Client.hs:2171-2176 | Signal work available (tryPutTMVar) |
| `withWork` / `withWork_` | Client.hs:2122-2140 | Wait for work, get item from store, run action |

Browser adaptation: `TMVar ()` → boolean flag + resolver. `forkIO` → `setTimeout(0)`. Worker restart logic must be preserved exactly.

### Operation state management

| Function | Haskell location | Purpose |
|----------|-----------------|---------|
| `AgentOpState` type | Client.hs:470 | `{opSuspended, opsInProgress}` |
| `AgentState` type | Client.hs:472-473 | `ASForeground \| ASSuspending \| ASSuspended` |
| `agentOperationBracket` | Client.hs:2232-2245 | Begin/end operation with suspend check |
| `beginAgentOperation` | Client.hs:2223-2230 | Increment opsInProgress |
| `endAgentOperation` | Client.hs:2179-2197 | Decrement opsInProgress, cascade suspend |
| `waitUntilActive` | Client.hs:956-957 | Block until agent is active |
| `throwWhenInactive` | Client.hs:959-962 | Throw if not active |
| `waitWhileSuspended` | Client.hs:2248-2253 | Block while suspended |
| `waitForUserNetwork` | Client.hs:924-928 | Block until network online |
| `noWorkToDo` | Client.hs:2167-2168 | Clear work flag (tryTakeTMVar) |

### Store wrappers

| Function | Haskell location | Purpose |
|----------|-----------------|---------|
| `withStore` | Client.hs:2259-2270 | Run store action, convert StoreError to AgentErrorType |
| `withStore'` | Client.hs:2255-2257 | Simplified withStore (always Right) |
| `storeError` | Client.hs (exported) | StoreError → AgentErrorType |

### Server selection

| Function | Haskell location | Purpose |
|----------|-----------------|---------|
| `userServers` | Client.hs:2312-2318 | Get user's server map |
| `pickServer` | Client.hs:2318-2325 | Pick server from NonEmpty list |
| `getNextServer` | Client.hs:2325-2350 | Get next server avoiding used hosts |
| `withNextSrv` | Client.hs:2375-2407 | Retry with next server on failure |

### Locking

| Function | Haskell location | Purpose |
|----------|-----------------|---------|
| `withConnLock` | Client.hs:1003-1006 | Per-connection mutex |
| `withConnLocks` | Client.hs:1020-1022 | Multiple connection mutex |
| `withInvLock` | Client.hs:1012-1015 | Per-invitation mutex |

Browser: locks via Promise chains. Single-threaded JS means no actual contention, but the ordering semantics must be preserved for async operations.

---

## Piece 4: SMP session management

| Function | Haskell location | Purpose |
|----------|-----------------|---------|
| `getSMPServerClient` | Client.hs:642-651 | Get or create SMP WebSocket client for transport session |
| `getSMPProxyClient` | Client.hs:653-702 | Get or create proxied relay session |
| `smpConnectClient` | Client.hs:704-718 | Actually connect SMP client via WebSocket |
| `smpClientDisconnected` | Client.hs:720-754 | Handle disconnect: move subs to pending, notify, resubscribe |
| `resubscribeSMPSession` | Client.hs:756-790 | Create resubscription worker |
| `mkTransportSession` | Client.hs:1345-1348 | Build transport session key |
| `mkSMPTransportSession` | Client.hs:1357-1360 | Build SMP transport session from queue |
| `getSessionMode` | Client.hs:1369-1370 | Get current session mode |
| `withClient_` | Client.hs:1037-1045 | Bracket: get client → run action → handle errors |
| `withClient` | Client.hs:1071-1073 | withClient_ + liftClient |
| `withSMPClient` | Client.hs:1079-1082 | withClient for SMP queues |
| `withLogClient_` | Client.hs:1064-1069 | withClient_ with logging |
| `withProxySession` | Client.hs:1047-1062 | Bracket for proxied operations |
| `sendOrProxySMPMessage` | Client.hs:1084-1094 | Decide direct vs proxy for SEND |
| `sendOrProxySMPCommand` | Client.hs:1096-1180 | Decide direct vs proxy for commands (SKEY etc) |
| `ipAddressProtected` | Client.hs:1181-1185 | Check if server is in protected domains |
| `liftClient` | Client.hs:1201-1203 | Convert protocol client error |
| `protocolClientError` | Client.hs:1205-1235 | Error conversion |
| `waitForProtocolClient` | Client.hs:847-868 | Wait for pending client connection |
| `newProtocolClient` | Client.hs:870-896 | Create protocol client with error handling |
| `activeClientSession` | Client.hs:1663-1666 | Check if client session is current (compares sessionId) |
| `removeSubscription` | Client.hs:1752-1755 | Remove single subscription from currentSubs + subscrConns |
| `removeSubscriptions` | Client.hs:1757-1763 | Remove multiple subscriptions |
| `hasActiveSubscription` | Client.hs:1736-1740 | Check if queue has active sub |
| `hasPendingSubscription` | Client.hs:1742-1747 | Check if queue has pending sub |
| `getClientConfig` | Client.hs:904-908 | Get protocol client config (slow/fast network) |
| `getNetworkConfig` | Client.hs:910-918 | Get current network config |
| `getFastNetworkConfig` | Client.hs:920-922 | Get fast network config |
| `slowNetworkConfig` | Client.hs:586-592 | Derive slow config from fast |
| `batchQueues` | Client.hs:1679-1684 | Group queues by transport session |
| `sendTSessionBatches` | Client.hs:1674-1678 | Send batched operations per session (mapConcurrently) |
| `sendClientBatch` | Client.hs:1686-1688 | Send batch to single client session (wrapper) |
| `sendClientBatch_` | Client.hs:1690-1722 | Send batch to single client: get client, run action, handle errors |
| `checkQueues` | Client.hs:1590-1595 | Filter out prohibited queues (GET lock check) |
| `subscribeSessQueues_` | Client.hs:1611-1651 | Send SUB batch via sendClientBatch_ + process results |

---

## Piece 5: Queue operations (use session management)

| Function | Haskell location | Purpose |
|----------|-----------------|---------|
| `newRcvQueue` | Client.hs:1373-1377 | Generate keys, create queue on SMP server |
| `newRcvQueue_` | Client.hs:1394-1474 | Full queue creation: auth keys, DH, createSMPQueue, build RcvQueue record |
| `subscribeQueues` | Client.hs:1543-1556 | Batch subscribe rcv queues grouped by transport session |
| `subscribeQueues_` | Client.hs:1556-1720 | Subscribe batch for one session |
| `processSubResults` | Client.hs:1476-1510 | Process subscribe results: partition into failed/subscribed/notices |
| `addNewQueueSubscription` | Client.hs:1724-1728 | Add queue to active subs after creation |
| `sendConfirmation` | Client.hs:1788-1794 | Per-queue E2E encrypt confirmation → SEND via sendOrProxySMPMessage |
| `sendInvitation` | Client.hs:1796-1806 | Per-queue E2E encrypt invitation → SEND via sendOrProxySMPMessage |
| `sendAgentMessage` | Client.hs:1948-1952 | Per-queue E2E encrypt message → SEND via sendOrProxySMPMessage |
| `agentCbEncrypt` | Client.hs:2074-2082 | Per-queue E2E encrypt with stored DH secret |
| `agentCbEncryptOnce` | Client.hs:2085-2095 | Per-queue E2E encrypt with ephemeral DH (for invitations) |
| `agentCbDecrypt` | Client.hs:2099-2102 | Per-queue E2E decrypt |
| `secureQueue` | Client.hs:1830-1833 | Send KEY command |
| `secureSndQueue` | Client.hs:1835-1841 | Send SKEY command via sendOrProxySMPCommand |
| `sendAck` | Client.hs:1904-1907 | Send ACK command |
| `decryptSMPMessage` | Client.hs:1824-1828 | Decrypt received SMP message body |
| `suspendQueue` | Client.hs:1926-1929 | Send OFF command |
| `deleteQueue` | Client.hs:1931-1934 | Send DEL command |
| `deleteQueues` | Client.hs:1936-1945 | Batch DEL |
| `getQueueMessage` | Client.hs:1808-1822 | Send GET + decrypt (for polling, if needed) |
| `notifySub` / `notifySub'` | Client.hs:791-797 | Write event to subQ |
| `cryptoError` | Client.hs:2104-2115 | CryptoError → AgentErrorType |

---

## Piece 6: Agent API (top level)

| Function | Haskell location | Purpose |
|----------|-----------------|---------|
| `joinConn` | Agent.hs:1260-1263 | Top-level join: pick server, delegate |
| `joinConnSrv` (invitation) | Agent.hs:1342-1357 | Lock, startJoinInvitation, secureConfirmQueue |
| `joinConnSrv` (contact) | Agent.hs:1358-1388 | Lock, create rcv queue, sendInvitation |
| `startJoinInvitation` | Agent.hs:1270-1310 | Version check, ratchet params, snd queue, createRatchet_ |
| `compatibleInvitationUri` | Agent.hs:1321-1328 | Version range compatibility |
| `compatibleContactUri` | Agent.hs:1330-1336 | Version range compatibility |
| `secureConfirmQueue` | Agent.hs:3653-3671 | Secure + send confirmation synchronously |
| `secureConfirmQueueAsync` | Agent.hs:3645-3651 | Secure + store confirmation for async delivery |
| `agentSecureSndQueue` | Agent.hs:3673-3684 | SKEY decision logic |
| `mkAgentConfirmation` | Agent.hs:3686-3691 | Build AgentConnInfoReply with reply queue |
| `storeConfirmation` | Agent.hs:3698-3712 | Ratchet encrypt + store as SndMsg |
| `enqueueConfirmation` | Agent.hs:3693-3696 | Store + submit for delivery |
| `createReplyQueue` | Agent.hs:1415-1424 | Create rcv queue for reply |
| `newRcvConnSrv` | Agent.hs:1155-1220 | Full create-connection-with-rcv-queue |
| `createRcvQueue` | Agent.hs:972-983 | Wrapper: newRcvQueue_ + updateNewConnRcv + addNewQueueSubscription |
| `newConnToJoin` | Agent.hs:1237-1253 | Create ConnData for join, store connection |
| `newSndQueue` | Agent.hs:3769-3802 | Build SndQueue from SMPQueueInfo |
| `getNextSMPServer` | Agent.hs (via Client.hs) | Pick server for new queue, avoiding contact's server |
| `connReqQueue` | Agent.hs:1265-1268 | Extract first queue from ConnectionRequestUri |
| `versionPQSupport_` | Agent.hs:1338-1340 | PQ support based on agent+e2e versions |
| `sendMessage'` | Agent.hs:1705-1706 | Top-level send |
| `sendMessagesB_` | Agent.hs:1725-1760 | Get conn, prepare, delegate |
| `enqueueMessageB` | Agent.hs:1989-2048 | Core: updateSndIds, encode, ratchetEncryptHeader, createSndMsg, createSndMsgDelivery |
| `encodeAgentMsgStr` | Agent.hs:2050-2054 | Encode AgentMessage to bytes |
| `agentRatchetEncrypt` | Agent.hs:3742-3746 | Ratchet encrypt message body |
| `agentRatchetEncryptHeader` | Agent.hs:3748-3754 | Get encrypt key from ratchet |
| `agentRatchetDecrypt` | Agent.hs:3757-3767 | Ratchet decrypt with skipped keys |
| `submitPendingMsg` | Agent.hs:2087-2090 | Signal delivery worker |
| `getDeliveryWorker` | Agent.hs:2079-2085 | Get-or-create delivery worker for queue |
| `runSmpQueueMsgDelivery` | Agent.hs:2092-2270 | Delivery loop: getPendingQueueMsg, dispatch on msgType, send, handle errors |
| `ackMessage'` | Agent.hs:2285-2323 | ACK + delete + optional receipt |
| `ackQueueMessage` | Agent.hs:2410-2430 | Send ACK to server, handle response |
| `subscriber` | Agent.hs:2912-2919 | Read from msgQ, dispatch |
| `processSMPTransmissions` | Agent.hs:2997-3297 | Incoming message dispatcher |
| `decryptClientMessage` | Agent.hs:3282-3296 | Per-queue E2E decrypt + parse envelope |
| `agentClientMsg` | Agent.hs:3207-3225 | Ratchet decrypt, parse, store RcvMsg |
| `smpConfirmation` | Agent.hs:3298-3370 | Process received confirmation |
| `helloMsg` | Agent.hs:3372-3393 | Process HELLO |
| `smpInvitation` | Agent.hs:3515-3570 | Process received invitation |
| `allowConnection'` | Agent.hs:1427-1434 | Accept confirmation, enqueue ICAllowSecure |
| `connectReplyQueues` | Agent.hs:3630-3643 | Process reply queues from confirmation |
| `enqueueCommand` | Agent.hs:1764-1767 | Store command + start worker |
| `runCommandProcessing` | Agent.hs:1789-1902 | Async command worker loop |
| `enqueueMessage` / `enqueueMessages` | Agent.hs:~2370+ | Convenience wrappers |
| `resumeMsgDelivery` | Agent.hs:2072-2076 | Resume delivery worker for a snd queue |
| `resumeConnCmds` | Agent.hs:1773-1776 | Resume async command workers for connections |
| `resumeAllCommands` | Agent.hs:1778-1781 | Resume all pending async commands on startup |
| `enqueueSavedMessage` | Agent.hs:2056-2057 | Create delivery for additional snd queues |
| `checkMsgIntegrity` | Agent.hs:3603-3610 | Verify message sequence integrity (local fn in processSMPTransmissions) |
| `subscribeConnection'` | Agent.hs:1472-1474 | Subscribe single connection (delegates to subscribeConnections') |
| `subscribeConnections'` | Agent.hs:1488-1490 | Get conn subs from store, delegate to subscribeConnections_ |
| `subscribeConnections_` | Agent.hs:1492-1527 | Core: partition conns, resume delivery, subscribe rcv queues |

---

## Resolved decisions

1. **Store field naming**: No mapping. IDB returns snake_case (`row.conn_id`), agent code uses it directly.
2. **Error handling**: Throw custom `AgentError` exception with typed error data matching Haskell `AgentErrorType`. Catches process errors by type.
3. **subQ**: Keep ABQueue. Agent writes events, user reads. Queues prevent deadlock — without them, a callback within message processing that triggers a send could deadlock single-threaded JS.
4. **msgQ**: Keep ABQueue. WebSocket onmessage enqueues, subscriber loop dequeues. Prevents reentrancy.
5. **Structured commands in IDB**: Store as JS objects. New fields optional.
6. **Transport session key**: `(userId, server)` tuple. One WebSocket per server. No TSMEntity. All TSMEntity-specific branches dropped.
7. **Join flows**: Both invitation and contact needed. Contact for widget's primary flow (joining address). Invitation for internal group member connections.
8. **Async join**: `joinConnSrvAsync` / `secureConfirmQueueAsync` as primary path.
9. **Version ranges**: Match Haskell defaults.
10. **Config defaults**: Match Haskell defaults.
11. **`ep/conc-msgs` branch**: Ignore. Use queues.
12. **Connection type dispatch**: Compute from `conn_mode` field + queue presence. `conn_mode = "INV"` with rcv+snd queues = duplex, with only rcv = rcv, etc.
13. **`withAgentEnv`**: No-op in TS — env in closure.
14. **`getConnSubs` for subscribe**: Use `getConn` (returns conn + queues) in subscribe flow.
15. **Client notices**: Skip in `subscribeSessQueues_`.

---

## Store methods to add

These store methods are not yet in `store.ts` / `store-idb.ts` but are needed by the agent layer:

| Method | AgentStore.hs lines | Used by |
|--------|-------------------|---------|
| `createSndRatchet` | 1271-1287 | `startJoinInvitation` — stores ratchet + e2e pub keys for sending side |
| `getSndRatchet` | 1289-1300 | `startJoinInvitation` — retry path, get previously created snd ratchet |
| `updateNewConnSnd` | 424-431 | `startJoinInvitation` — add snd queue to new connection |
| `createSndConn` | 433-440 | May be needed for contact join flow |
| `setRcvQueueStatus` | already exists | — |
| `setSndQueueStatus` | already exists | — |
| `setRcvSwitchStatus` | skip (queue switching) | — |
| `setSndSwitchStatus` | skip (queue switching) | — |

---

## What to skip for MVP

| Feature | Functions to skip |
|---------|------------------|
| Queue switching | `switchConnection`, QADD/QKEY/QUSE/QTEST handlers, `switchDuplexConnection` |
| Ratchet sync | `synchronizeRatchet`, EREADY handler, `newRatchetKey` |
| Notifications | All NTF functions, `newQueueNtfSubscription` |
| File transfer | All XFTP functions |
| Remote control | All RC functions |
| Connection creation | `createConnection`, `newConn`, short links creation |
| Delivery receipts sending | `sendRcpt` in ackMessage (receiving A_RCVD is kept) |
| Multiple rcv queues | Queue replacement logic in processSMPTransmissions |
| Cleanup manager | `cleanupManager`, `deleteRcvMsgHashesExpired`, etc. |
| Server management | `setProtocolServers`, `testProtocolServer` |
| Client notices | `processClientNotices`, `subscribeClientService` |
| Statistics | All `inc*ServerStat` calls, `getAgentServersSummary` |
| Connection comparison | `compareConnections`, `syncConnections` |

## Testing strategy

### Principle: every step produces testable output

Cross-language tests from Haskell give the highest confidence because they verify wire compatibility. Pure TS tests verify internal logic. The goal is to have Haskell tests at every step where the TS code touches the network.

### Step 1 tests: pure TS (no server)

File: `tests/infra-test.ts` (run with `node`, like store-test.ts)

- **RetryInterval**: `nextRetryDelay` returns correct values for various elapsed/delay combinations. `withRetryIntervalCount` calls action with increasing delays.
- **TSessionSubs**: Full lifecycle: add pending → set session ID → add active (moves from pending) → disconnect (moves back to pending) → reconnect. Test `setSubsPending` mode logic (entity vs user session). Test batch operations.
- **SessionVar**: `getSessVar` returns Left for new, Right for existing. `removeSessVar` only removes matching ID.

### Step 2 tests: TS with store (no server)

File: `tests/worker-test.ts`

- Create AgentClient with real IndexedDB store (fake-indexeddb).
- Test worker lifecycle: create worker → signal work → worker runs → no work → worker waits → signal again.
- Test server selection: configure servers → `getNextServer` rotates avoiding used hosts.
- Test locking: `withConnLock` serializes async operations on same connId.

### Step 3 tests: agent-repl + Haskell (real SMP server)

File: `tests/agent-repl.ts` — new REPL with higher-level commands.

The agent-repl exposes mid-level operations that Haskell can drive:

```
AGENT_INIT <serverUrl> <userId>
  → creates AgentClient, connects to server

CREATE_RCV_QUEUE <connIdHex>
  → newRcvQueue on server, returns rcvId, sndId, sndQueueUri
  → Haskell can then SEND to this queue

SUBSCRIBE <connIdHex>
  → subscribeQueues for connection's rcv queue

SEND_AGENT_MSG <sndQueueHex> <msgBodyHex>
  → agentCbEncrypt + sendAgentMessage

RECV
  → wait for MSG from WebSocket, decryptSMPMessage, return parsed body

SECURE_SND <sndQueueHex>
  → secureSndQueue (SKEY)

SEND_CONFIRMATION <sndQueueHex> <confirmationHex>
  → sendConfirmation

ACK <rcvIdHex> <msgIdHex>
  → sendAck
```

Haskell test scenarios:
1. **Queue creation**: TS creates rcv queue → Haskell verifies by sending to it → TS receives
2. **Subscribe + receive**: TS subscribes → Haskell sends MSG → TS decrypts and returns
3. **Send**: TS sends agent message → Haskell receives and decrypts
4. **SKEY**: TS sends SKEY → Haskell verifies queue secured
5. **Proxy send**: TS sends via proxy → Haskell receives

These tests verify the entire session management + queue operations layer without needing the full agent handshake.

### Step 4 tests: agent-repl + Haskell (ratchet operations)

Extend agent-repl:

```
RATCHET_ENCRYPT <connIdHex> <plaintextHex>
  → agentRatchetEncrypt, return encrypted agent envelope

RATCHET_DECRYPT <connIdHex> <encryptedHex>
  → agentRatchetDecrypt, return plaintext

ENQUEUE_MSG <connIdHex> <msgBodyHex>
  → enqueueMessageB (encrypt + store + create delivery)

DELIVER
  → runSmpQueueMsgDelivery one iteration (getPendingQueueMsg + send)
```

Haskell test scenarios:
1. **Ratchet encrypt cross-language**: Initialize ratchet in both → TS encrypts → Haskell decrypts (and vice versa). Already have ratchet cross-language tests, extend to agent envelope level.
2. **Enqueue + deliver**: TS enqueues message → delivery worker sends → Haskell receives and decrypts entire agent message envelope.
3. **Receive + store**: Haskell sends agent message → TS receives, decrypts, stores RcvMsg → verify stored correctly.

### Step 5 tests: full handshake (end-to-end)

Extend agent-repl or create dedicated test:

```
JOIN <connectionRequestUri> <connInfo>
  → full joinConnection flow

ALLOW <confId> <connInfo>
  → allowConnection

SEND <connIdHex> <msgBody>
  → sendMessage

ACK_MSG <connIdHex> <msgId>
  → ackMessage
```

Haskell test scenarios:
1. **Join invitation**: Haskell creates invitation → TS joins → handshake completes (CONF, HELLO exchange) → messages flow both ways.
2. **Join contact**: Haskell creates contact address → TS joins → Haskell accepts → messages flow.
3. **Multiple connections**: TS joins two different connections on different servers simultaneously.
4. **Reconnect**: Connection established → WebSocket drops → resubscribe → messages resume.

### Test infrastructure

All cross-language tests go in `tests/SMPWebTests.hs`, extending the existing 99 tests. Each agent-repl command is a single stdin/stdout exchange (like client-repl). Haskell `callNode` drives the TS process.

Estimated test count per step:
- Step 1: ~15 TS tests (retry: 5, subs: 8, session: 2)
- Step 2: ~8 TS tests (worker: 4, server selection: 2, locking: 2)
- Step 3: ~8 Haskell tests (queue create, subscribe, send, receive, SKEY, proxy)
- Step 4: ~6 Haskell tests (ratchet encrypt/decrypt, enqueue+deliver, receive+store)
- Step 5: ~6 Haskell tests (join invitation, join contact, send/receive/ack, reconnect)
