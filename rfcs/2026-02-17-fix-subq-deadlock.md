# Fix subQ deadlock: blocking writeTBQueue inside connLock

## Problem

Users report that message reception silently and permanently stops across all connections, with no error alerts. The app appears functional but no messages arrive. Recovery requires restart.

Root cause: a deadlock between worker threads holding `connLock` and the `agentSubscriber` (sole `subQ` reader).

### The deadlock mechanism

`subQ` (`TBQueue ATransmission`, capacity 4096 on mobile / 1024 on desktop) is the single pipeline between the agent layer and the chat layer. The `agentSubscriber` thread (`Commands.hs:4373`) is its **sole reader**.

Three code sites hold `connLock` and call blocking `writeTBQueue subQ` without a fullness check. When `subQ` is full, these block while holding the lock. If `agentSubscriber` simultaneously needs the same `connLock` (via `sendMessagesB_` → `withConnLocks`), it blocks too — creating a circular wait:

- **Worker**: holds `connLock(X)`, waits for `subQ` space (needs `agentSubscriber` to read)
- **agentSubscriber**: sole `subQ` reader, waits for `connLock(X)` (needs worker to release)
- **Result**: permanent silent deadlock — no exception, no alert, all connections blocked

### Confirmed deadlock scenarios

**Scenario 1**: Delivery worker during queue rotation test

```
Delivery worker:                    agentSubscriber (sole subQ reader):
  withConnLock(X) [2187]              readTBQueue subQ → processAgentMessageConn
  ...DB operations...                 → sendPendingGroupMessages (on CON/SENT/QCONT)
  notify → writeTBQueue subQ [2238]   → batchSendConnMessages → deliverMessagesB
  [BLOCKED — subQ full]               → withAgent sendMessagesB [synchronous]
                                      → sendMessagesB_ → withConnLocks({..X..}) [1708]
                                      [BLOCKED — connLock(X) held]
```

**Scenario 2**: Async command worker during message ACK with notification

```
Async cmd worker:                   agentSubscriber (sole subQ reader):
  tryWithLock "ICAck" [1930→1824]     readTBQueue subQ → processAgentMessageConn
  → withConnLock(X)                   → sendPendingGroupMessages
  → ack → ackQueueMessage [1899]      → sendMessagesB_ → withConnLocks({..X..})
  → sendMsgNtf [2381]                [BLOCKED — connLock(X) held]
  → writeTBQueue subQ [2386]
  [BLOCKED — subQ full]
```

**Scenario 3**: Synchronous `ackMessage'` API (same mechanism as Scenario 2 but from external API caller)

```
ackMessage' caller:                 agentSubscriber (sole subQ reader):
  withConnLock(X) [2254]              → sendMessagesB_ → withConnLocks({..X..})
  → ack → ackQueueMessage [2267]      [BLOCKED — connLock(X) held]
  → sendMsgNtf [2381]
  → writeTBQueue subQ [2386]
  [BLOCKED — subQ full]
```

### ConnId overlap verified

No guard prevents a connection undergoing queue rotation (AM_QTEST_) or ACK processing from being included in `sendMessagesB_`'s batch. During these operations, the connection has `connStatus == ConnReady`, passing all filters in `memberSendAction`.

### Cascade amplification

Once any single deadlock triggers, `subQ` never drains. ALL other threads that attempt `writeTBQueue subQ` block progressively — their locks are held forever too. The entire threading system freezes within seconds.

### Affected code sites (blocking `writeTBQueue subQ` inside `connLock`)

| Site | File | Lock line | Write line | Events written |
|------|------|-----------|------------|----------------|
| `runSmpQueueMsgDelivery::notify` | Agent.hs | 2187 | 2238 | SWITCH SPCompleted, ERR INTERNAL |
| `runSmpQueueMsgDelivery::internalErr/notifyDel` | Agent.hs | 2187 | 2238 (via notifyDel→notify) | ERR INTERNAL + delMsg |
| `ackQueueMessage::sendMsgNtf` | Agent.hs | 2254 or 1930 | 2386 | MSGNTF |

### Safe patterns that already exist in the codebase

1. **`isFullTBQueue` + pending TVar** (used at `runCommandProcessing` lines 1782-1784/1937, and `runProcessSMP` lines 3027-3029/3216):
   ```haskell
   -- Before processing (e.g. line 1782):
   pending <- newTVarIO []
   -- During processing — safe notify (e.g. line 1937):
   notify cmd =
     let t = (corrId, connId, AEvt (sAEntity @e) cmd)
      in atomically $ ifM (isFullTBQueue subQ) (modifyTVar' pendingCmds (t :)) (writeTBQueue subQ t)
   -- After processing — flush (e.g. line 1784):
   mapM_ (atomically . writeTBQueue subQ) . reverse =<< readTVarIO pending
   ```

2. **`nonBlockingWriteTBQueue`** (used at Client.hs:789, NtfSubSupervisor.hs:507):
   ```haskell
   nonBlockingWriteTBQueue q x = do
     sent <- atomically $ tryWriteTBQueue q x
     unless sent $ void $ forkIO $ atomically $ writeTBQueue q x
   ```
   Note: `nonBlockingWriteTBQueue` does NOT preserve ordering — the spawned background thread may complete out of order relative to subsequent direct writes from the same calling thread.

### Exhaustive proof: no other deadlock scenarios exist

All 15 `withConnLock` sites in Agent.hs were analyzed. Only 3 write to `subQ`:

| withConnLock site | Writes subQ? | Safe? |
|-------------------|-------------|-------|
| switchConnectionAsync' (899) | No | ✓ |
| setConnShortLinkAsync' (995) | No | ✓ |
| setConnShortLink' (1031) | No | ✓ |
| deleteConnShortLink' (1075) | No | ✓ |
| allowConnection' (1407) | No | ✓ |
| acceptContact' (1417) | No | ✓ |
| sendMessagesB_ (1708, `withConnLocks`) | No | ✓ |
| tryWithLock/runSmpCommand (1930) | Yes (1937) | ✓ — `isFullTBQueue` check |
| tryMoveableWithLock/runSmpCommand (1931) | Yes (1937) | ✓ — `isFullTBQueue` check |
| **runSmpQueueMsgDelivery AM_QTEST_ (2187)** | **Yes (2238)** | **✗ — DEADLOCK** |
| **ackMessage' (2254)** | **Yes (2386)** | **✗ — DEADLOCK** |
| switchConnection' (2298) | No | ✓ |
| abortConnectionSwitch' (2328) | No | ✓ |
| synchronizeRatchet' (2351) | No | ✓ |
| suspendConnection' (2390) | No | ✓ |
| **processSMP (3037)** | Yes (3216) | ✓ — `isFullTBQueue` check |

Note: `processSMP` (line 3037) holds `connLock` and its local `notify` (line 3216) writes to `subQ`, but it uses the safe `isFullTBQueue` pattern. Its `ack` (line 3196) uses `enqueueCmd` (DB-only), NOT `ackQueueMessage`. The actual `ackQueueMessage` runs later from the async command worker via ICAck/ICAckDel.

Other lock pairs checked — no circular dependencies:
- `connLock × DB MVar`: DB never acquires connLock
- `entityLock × connLock`: consistent ordering (entity first in chat, conn in agent)
- `connLock(X) × connLock(Y)`: single agentSubscriber thread, one `withConnLocks` at a time

---

## Deadlock call graph: agentSubscriber → connLock

All deadlock paths require `agentSubscriber` to synchronously acquire `connLock`. Exhaustive analysis shows that **every such path converges on a single agent function**: `sendMessagesB_` → `withConnLocks` (Agent.hs:1708). No other agent API function called synchronously from the agentSubscriber acquires connLock.

Verified (FACT): `ackMessageAsync` → `enqueueCommand` only (no connLock). `toggleConnectionNtfs` → no lock. `deleteConnectionAsync` → `deleteLock` not `connLock`. `joinConnectionAsync` → `withInvLock` not `connLock`.

Also verified (FACT): `Lock = TMVar Text` (Lock.hs:24) is **non-reentrant** — double acquisition on the same thread deadlocks.

### All 22 trigger paths

Every path goes through `deliverMessage`/`deliverMessages`/`deliverMessagesB` → `withAgent sendMessagesB` → `sendMessagesB_` → `withConnLocks`:

| # | Trigger | Chat function | ConnIds locked | Risk |
|---|---------|--------------|----------------|------|
| 1 | Group CON (Invitee) | `introduceToAll` → broadcast XGrpMemNew | **ALL member connIds** | **HIGHEST** |
| 2 | Group MSG XGrpLinkAcpt | `introduceToRemaining` → broadcast | **ALL member connIds** | **HIGHEST** |
| 3 | Group CON (Invitee) | `sendIntroductions` → batch intros to new member | new member connId | Medium |
| 4 | Group CON (Invitee) | `sendHistory` → batch to new member | new member connId | Medium |
| 5 | Group CON | `sendPendingGroupMessages` | member connId | Medium |
| 6 | Group SENT | `sendPendingGroupMessages` | member connId | Medium |
| 7 | Group QCONT | `sendPendingGroupMessages` | member connId | Medium |
| 8 | Group CON (PendingReview) | `introduceToModerators` → to moderators | moderator connIds | Medium |
| 9 | Group CON (PreMember) | `sendXGrpMemCon` → to host | host connId | Low |
| 10 | Group CON (PreMember) | `probeMatchingMemberContact` → probes + hashes | member + N matching connIds | Medium |
| 11 | Direct CON | `probeMatchingMembers` → probes + hashes | contact + N matching connIds | Medium |
| 12 | Direct JOINED | `sendAutoReply` | contact connId | Low |
| 13 | Group JOINED | `sendGroupAutoReply` | member connId | Low |
| 14 | Group INV | `sendXGrpMemInv` → to host | host connId | Low |
| 15 | Group INV (legacy) | `sendGrpInvitation` → to contact | contact connId | Low |
| 16 | Group MSG XGrpMemInv | `xGrpMemInv` → `sendGroupMemberMessage` | re-member connId | Low |
| 17 | Group MSG XGrpMemDel | `forwardToMember` | deleted member connId | Low |
| 18 | Group MSG XGrpLinkMem | `probeMatchingMemberContact` | member + N matching connIds | Medium |
| 19 | Group MSG (dup relay) | `saveGroupRcvMsg` error → `sendDirectMemberMessage` | forwarder connId | Low |
| 20 | SFDONE | `sendFileDescriptions` → to recipients | recipient connIds | Medium |
| 21 | Group MSG XGrpLinkAcpt | `sendHistory` → to accepted member | accepted member connId | Medium |
| 22 | Direct MSG (autoAccept) | `autoAcceptFile` → inline accept reply | contact connId | Low (test-only config) |

### Key observations

1. **Single bottleneck**: All 22 paths converge on `sendMessagesB_` → `withConnLocks` (Agent.hs:1708). The deadlock is between this lock acquisition and any worker thread holding `connLock` + blocking on `writeTBQueue subQ`.

2. **Highest-risk paths** (#1, #2): Broadcasting to ALL group members in `introduceToAll` / `introduceToRemaining` acquires `withConnLocks` on ALL member connIds in a single batch. For large groups, this holds the agentSubscriber thread for a long time, during which subQ fills, which causes worker threads holding connLock on any of those connIds to deadlock.

3. **Medium-risk paths** (#5-7): `sendPendingGroupMessages` fires on every CON/SENT/QCONT. These are frequent and lock the member's connId, which is the SAME connId that a delivery worker or ACK worker may hold while writing to subQ.

---

## Analysis: `withConnLocks` in `sendMessagesB_`

### FACT: the lock protects ratchet encryption state

`sendMessagesB_` (Agent.hs:1708-1713) acquires `withConnLocks` and executes:

1. **`getConn_`** — reads connection metadata, send queues from DB
2. **`setConnPQSupport`** — updates PQ encryption flag per connection
3. **`enqueueMessagesB`** → `enqueueMessageB` → `storeSentMsg_` which calls:
   - **`updateSndIds`** (AgentStore.hs:899) — increments `internalSndId` (sequential send counter)
   - **`agentRatchetEncryptHeader`** (Agent.hs:3698) — reads current ratchet via `getRatchetForUpdate`, encrypts message header via `rcEncryptHeader`, writes advanced ratchet state via `updateRatchet`
   - **`createSndMsg`** + **`createSndMsgDelivery`** — inserts message and delivery records

All operations run within `unsafeWithStore` → `withTransaction` (single DB transaction per batch).

### FACT: the lock CANNOT be removed

Without `withConnLocks`, concurrent `sendMessagesB_` calls targeting the same connection would:
- Read the same ratchet state, both encrypt, one overwrite the other → **ratchet desync** (unrecoverable)
- Get duplicate `internalSndId` values → **message ID collision**
- Race on `setConnPQSupport` → **PQ state inconsistency**

The lock serializes ALL operations on the connection's encryption state. Removing it would introduce data corruption.

Note: `sendMessage` (singular, line 530) uses the same `sendMessagesB_` function — there is no lock-free send path.

### Eliminated strategies

- **Strategy C (remove lock)**: The lock protects ratchet encryption. Removing it causes unrecoverable ratchet desync. Eliminated.
- **Strategy A (async dispatch)**: All 22 chat-layer callers use `deliverMessagesB` return values (delivery IDs, PQ state) synchronously. `forkIO` loses results. Eliminated.
- **Strategy W (isFullTBQueue + pending TVar)**: The existing pattern (lines 1937, 3216) buffers events in a local TVar and flushes after lock release. Between lock release and flush, another thread can acquire the same connLock and write events to subQ — reordering events within the same connection. This trades a visible deadlock for invisible ordering bugs. Eliminated.
- **Strategy O (per-connection overflow queues)**: Bounded overflow queues with "drop when full" were analyzed. Drop consequences are unacceptable at 5 of 6 write sites — CONF, INFO, CON cause permanent connection failure after ACK; INV loses connection invitations; SENT/MERR leave messages stuck forever. Unbounded overflow defeats backpressure. Eliminated.

---

## Solution: move subQ writes outside connLock

### Root cause

The `writeTBQueue subQ` calls at the 3 deadlock sites are inside `connLock` by accident of code structure, not necessity. `connLock` protects ratchet encryption state and DB consistency. The `notify` calls write informational events to `subQ` — they do not modify any state that `connLock` protects.

Moving the writes outside the lock scope eliminates the deadlock: blocking `writeTBQueue subQ` without holding `connLock` is safe — agentSubscriber is free to acquire the lock, process events, and drain `subQ`.

### Why reordering doesn't matter at these sites

The chat layer handlers for the 3 deadlock site events do NOT advance the ratchet:

| Event | Chat handler | Calls sendMessagesB_? |
|-------|-------------|----------------------|
| SWITCH SPCompleted | Creates internal chat item, updates UI | **No** |
| ERR INTERNAL | Logs error to view | **No** |
| MSGNTF | `toView CEvtNtfMessage` → empty output | **No** |

Events that DO trigger ratchet advances (CON, SENT, QCONT → `sendPendingGroupMessages` → `sendMessagesB_`) are all already written OUTSIDE `connLock` in the current code.

Ratchet state lives in the DB, not in subQ events. agentSubscriber processes events sequentially regardless of arrival order. The SENT-before-SWITCH race already exists in the current code (new queue worker writes SENT outside connLock while old queue worker writes SWITCH inside connLock).

### Fix: Site 1 — `runSmpQueueMsgDelivery` AM_QTEST_ (line 2187)

Restructure `withConnLock` to return the event, write outside.

**Current code** (Agent.hs:2187-2214):
```haskell
AM_QTEST_ -> withConnLock c connId "runSmpQueueMsgDelivery AM_QTEST_" $ do
  withStore' c $ \db -> setSndQueueStatus db sq Active
  SomeConn _ conn <- withStore c (`getConn` connId)
  case conn of
    DuplexConnection cData' rqs sqs -> do
      let addr = qAddress sq
      case findQ addr sqs of
        Just SndQueue {dbReplaceQueueId = Just replacedId, primary} ->
          case removeQP (\sq' -> dbQId sq' == replacedId && not (sameQueue addr sq')) sqs of
            Nothing -> internalErr msgId "sent QTEST: queue not found in connection"
            Just (sq', sq'' : sqs') -> do
              checkSQSwchStatus sq' SSSendingQTEST
              atomically $ TM.delete (qAddress sq') $ smpDeliveryWorkers c
              withStore' c $ \db -> do
                when primary $ setSndQueuePrimary db connId sq
                deletePendingMsgs db connId sq'
                deleteConnSndQueue db connId sq'
              let sqs'' = sq'' :| sqs'
                  conn' = DuplexConnection cData' rqs sqs''
              cStats <- connectionStats c conn'
              notify $ SWITCH QDSnd SPCompleted cStats       -- DEADLOCK
            _ -> internalErr msgId "sent QTEST: ..."         -- DEADLOCK (via notifyDel → notify)
        _ -> internalErr msgId "sent QTEST: ..."             -- DEADLOCK
    _ -> internalErr msgId "QTEST sent not in duplex ..."    -- DEADLOCK
```

**New code:**
```haskell
AM_QTEST_ -> do
  evt_ <- withConnLock c connId "runSmpQueueMsgDelivery AM_QTEST_" $ do
    withStore' c $ \db -> setSndQueueStatus db sq Active
    SomeConn _ conn <- withStore c (`getConn` connId)
    case conn of
      DuplexConnection cData' rqs sqs -> do
        let addr = qAddress sq
        case findQ addr sqs of
          Just SndQueue {dbReplaceQueueId = Just replacedId, primary} ->
            case removeQP (\sq' -> dbQId sq' == replacedId && not (sameQueue addr sq')) sqs of
              Nothing -> pure $ Left "sent QTEST: queue not found in connection"
              Just (sq', sq'' : sqs') -> do
                checkSQSwchStatus sq' SSSendingQTEST
                atomically $ TM.delete (qAddress sq') $ smpDeliveryWorkers c
                withStore' c $ \db -> do
                  when primary $ setSndQueuePrimary db connId sq
                  deletePendingMsgs db connId sq'
                  deleteConnSndQueue db connId sq'
                let sqs'' = sq'' :| sqs'
                    conn' = DuplexConnection cData' rqs sqs''
                cStats <- connectionStats c conn'
                pure $ Right $ SWITCH QDSnd SPCompleted cStats
              _ -> pure $ Left "sent QTEST: there is only one queue in connection"
          _ -> pure $ Left "sent QTEST: queue not in connection or not replacing another queue"
      _ -> pure $ Left "QTEST sent not in duplex connection"
  -- subQ write is now OUTSIDE connLock — blocking writeTBQueue is safe
  case evt_ of
    Right evt -> notify evt
    Left err -> internalErr msgId err
```

All DB operations remain inside the lock. Only `notify`/`internalErr` (which write to subQ) move outside. `internalErr` calls `notifyDel` = `notify >> delMsg` — both `notify` (subQ write) and `delMsg` (`deleteSndMsgDelivery`, keyed on unique msgId) are safe outside the lock. The existing double-delete pattern (`delMsg` inside `internalErr` + `delMsgKeep` at line 2216) is preserved.

### Fix: Sites 2 & 3 — `ackQueueMessage::sendMsgNtf` (line 2386)

Change `ackQueueMessage` to return the MSGNTF event instead of writing it to subQ. Callers write to subQ after releasing connLock.

**Current code** (Agent.hs:2371-2386):
```haskell
ackQueueMessage :: AgentClient -> RcvQueue -> SMP.MsgId -> AM ()
ackQueueMessage c rq@RcvQueue {userId, connId, server} srvMsgId = do
  atomically $ incSMPServerStat c userId server ackAttempts
  tryAllErrors (sendAck c rq srvMsgId) >>= \case
    Right _ -> sendMsgNtf ackMsgs
    Left (SMP _ SMP.NO_MSG) -> sendMsgNtf ackNoMsgErrs
    Left e -> ...
  where
    sendMsgNtf stat = do
      atomically $ incSMPServerStat c userId server stat
      whenM (liftIO $ hasGetLock c rq) $ do
        atomically $ releaseGetLock c rq
        brokerTs_ <- eitherToMaybe <$> tryAllErrors (withStore c $ \db -> getRcvMsgBrokerTs db connId srvMsgId)
        atomically $ writeTBQueue (subQ c) ("", connId, AEvt SAEConn $ MSGNTF srvMsgId brokerTs_)
```

**New code** — return `Maybe ATransmission` instead of writing:
```haskell
ackQueueMessage :: AgentClient -> RcvQueue -> SMP.MsgId -> AM (Maybe ATransmission)
ackQueueMessage c rq@RcvQueue {userId, connId, server} srvMsgId = do
  atomically $ incSMPServerStat c userId server ackAttempts
  tryAllErrors (sendAck c rq srvMsgId) >>= \case
    Right _ -> sendMsgNtf ackMsgs
    Left (SMP _ SMP.NO_MSG) -> sendMsgNtf ackNoMsgErrs
    Left e -> ... >> pure Nothing
  where
    sendMsgNtf stat = do
      atomically $ incSMPServerStat c userId server stat
      ifM (liftIO $ hasGetLock c rq)
        (do atomically $ releaseGetLock c rq
            brokerTs_ <- eitherToMaybe <$> tryAllErrors (withStore c $ \db -> getRcvMsgBrokerTs db connId srvMsgId)
            pure $ Just ("", connId, AEvt SAEConn $ MSGNTF srvMsgId brokerTs_))
        (pure Nothing)
```

**Caller 1: `ackMessage'`** (Agent.hs:2253-2267) — return event from `withConnLock`, write after:
```haskell
ackMessage' c connId msgId rcptInfo_ = do
  t_ <- withConnLock c connId "ackMessage" $ do
    SomeConn _ conn <- withStore c (`getConn` connId)
    case conn of
      DuplexConnection {} -> do
        t_ <- ack
        sendRcpt conn
        del
        pure t_
      RcvConnection {} -> do
        t_ <- ack
        del
        pure t_
      SndConnection {} -> throwE $ CONN SIMPLEX "ackMessage"
      ContactConnection {} -> throwE $ CMD PROHIBITED "ackMessage: ContactConnection"
      NewConnection _ -> throwE $ CMD PROHIBITED "ackMessage: NewConnection"
  -- subQ write is OUTSIDE connLock
  case t_ of
    Just t -> atomically $ writeTBQueue (subQ c) t
    Nothing -> pure ()
```

**Caller 2: `ICAck` / `ICAckDel`** (Agent.hs:1823-1824) — inline `tryWithLock` as `tryCommand` + `withConnLock`, write subQ between the two scopes:

`tryWithLock name = tryCommand . withConnLock c connId name` — by inlining, the subQ write can be placed outside `withConnLock` but inside `tryCommand` (retaining retry/error handling).

```haskell
ICAck rId srvMsgId -> withServer $ \srv ->
  tryCommand $ do
    t_ <- withConnLock c connId "ICAck" $ ack srv rId srvMsgId
    -- subQ write is OUTSIDE connLock — cannot deadlock with agentSubscriber
    forM_ t_ $ atomically . writeTBQueue subQ

ICAckDel rId srvMsgId msgId -> withServer $ \srv ->
  tryCommand $ do
    t_ <- withConnLock c connId "ICAckDel" $ do
      t_ <- ack srv rId srvMsgId
      withStore' c (\db -> deleteMsg db connId msgId)
      pure t_
    -- subQ write is OUTSIDE connLock — cannot deadlock with agentSubscriber
    forM_ t_ $ atomically . writeTBQueue subQ
```

Where `ack` now returns `AM (Maybe ATransmission)`:
```haskell
ack srv rId srvMsgId = do
  rq <- withStore c $ \db -> getRcvQueue db connId srv rId
  ackQueueMessage c rq srvMsgId
```

All subQ writes for MSGNTF are now outside connLock. FIFO ordering is preserved — no `nonBlockingWriteTBQueue`, no forked threads. The same thread that held the lock writes to subQ sequentially after releasing it.

### Race analysis

Window between connLock release and subQ write at Site 1:

| Thread | Can acquire connLock(X)? | Writes subQ? | Consequence |
|--------|-------------------------|-------------|-------------|
| agentSubscriber via sendMessagesB_ | Yes | **No** (encrypts only) | No race |
| processSMP for connId X | Yes | Yes (pending flush) | MSG before SWITCH — cosmetic |
| runCommandProcessing for connId X | Yes | Yes (pending flush) | Command response before SWITCH — cosmetic |
| New queue delivery worker | No (SENT outside lock) | Yes | SENT before SWITCH — cosmetic, **already exists in current code** |

All races are cosmetic UI ordering. None affect ratchet state, protocol correctness, or message delivery.

### Summary of changes

| File | Change | Lines affected |
|------|--------|---------------|
| Agent.hs | Restructure AM_QTEST_ to return event from `withConnLock`, write outside | ~2187-2214 |
| Agent.hs | Change `ackQueueMessage` return type to `AM (Maybe ATransmission)`, return event instead of writing | ~2371-2386 |
| Agent.hs | `ackMessage'`: return event from `withConnLock`, write outside | ~2253-2267 |
| Agent.hs | `ICAck`/`ICAckDel`: inline `tryCommand` + `withConnLock`, write subQ between scopes | ~1823-1824 |
| Agent.hs | `ack` helper: propagate new return type | ~1899-1901 |

No new data structures. No new modules. No changes to other write sites (1937, 3216 — already safe). ~25 lines changed total.
