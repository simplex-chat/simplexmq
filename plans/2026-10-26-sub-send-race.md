# SUB/SEND registration race

Base: c0c416da. Paths are under `src/Simplex/Messaging/`.

| Abbreviation | File |
|---|---|
| S | `Server.hs` |
| Env | `Server/Env/STM.hs` |
| MT | `Server/MsgStore/Types.hs` |
| MSTM | `Server/MsgStore/STM.hs` |
| MPG | `Server/MsgStore/Postgres.hs` |
| QPG | `Server/QueueStore/Postgres.hs` |
| QSTM | `Server/QueueStore/STM.hs` |
| MIG | `Server/QueueStore/Postgres/Migrations.hs` |
| PGC | `Agent/Store/Postgres/Common.hs` |

INFERENCE marks a statement about PostgreSQL, GHC STM or library semantics whose source was not read.

Pull requests:

| Branch | Base | Contents |
|---|---|---|
| `ep/smp-delivery-thread-state` | master | D7 (§3.7) with T4 |
| `ep/smp-sub-race` | master | the fix (§3.1-3.6), the move (§3.5 item 1), D4, D8, T1, T2, T5 |
| `ep/smp-sub-lock-pg` | `ep/smp-sub-race` | D9, D10 |

- D4 stays with the fix. Before the fix, rows were not locked by SUB batches; with it, the unordered association UPDATE (QPG:397-399) and a SUB batch can lock the same rows in opposite orders (§4 item 1).
- D8 stays with the fix. Under the fix, the SUB-batch connection is held longer: for row-lock waits, both statements, the registrations and COMMIT (§4 item 3). `dbPool` is also used by command verification, SEND, ACK and expiry (§4 item 5). Without D8, every `dbPool` holder still holds one connection at a time: the SUB callback is STM only.
- D9 and D10 shorten the row-lock window (§4 items 3, 4).
- D7 changes only `deliverThread` (S:2129-2142), which is unchanged by the fix.

Review tags:
- `[I<n>]` interleavings review
- `[L<n>]` locking review
- `[C-A<n>]`, `[C-B<n>]` contention review

## 1. Race

1. The first message of each SUB queue is read in `prepareBatchSubs` (S:1443 → MPG:197-214, MSTM:136-137).
2. The Sub is inserted into the client's map, and `CSClient` is queued to `subQ` (S:1753, 1894-1895, 1860).
3. The client is registered in `queueSubscribers` later, by serverThread (S:265-267, 287 → Env:375-382).
4. A push is made by SEND only when the queue was empty (S:2050), and only to a registered subscriber (S:2082-2088, 2103-2105).
5. A message written between steps 1 and 3 is neither returned nor pushed; later messages are written with `was_empty = false` (MIG:857). CI signature: `QSub {QNoSub, qDelivered = Nothing}`, `qiSize = 1`.
6. SUBS has the same window: `CSService` is queued (S:1963) while `deliverServiceMessages` is forked (S:1906).

## 2. Options

1. Chosen. One SUB-batch transaction: lock rows, read records and messages, verify, register, commit.
   - Cost: one locking statement per batch; registry writes from commands threads; SENDs to queues of an in-flight batch delayed until its commit.
2. Read transaction kept open until serverThread registers.
   - Cost: pool connections held while up to 128 batches are queued in `rcvQ` (Server/Main.hs:458).
3. SUB held under the lock until serverThread registers.
   - Cost: lock hold time includes the unbounded `subQ` backlog (Env:350); a completion variable per batch.
4. Per-queue Haskell lock map for SUB and SEND (`withLockMap`, Agent/Client.hs:1100-1109).
   - Cost: a map write per SUB and per SEND; a second lock beside the `write_message` row lock.
5. Advisory transaction locks in place of row locks (variant of option 1, D1).
   - Cost: a `write_message` migration; lock-table capacity.
6. Rejected by you earlier:
   - registration before read or verification;
   - a second read after registration;
   - queue reads in serverThread;
   - a hand-off from SEND to serverThread;
   - stm-containers.

The cost of option 1 is the lowest. Under options 2 and 3, a lock or a connection is held for a time set by queue backlogs. Under option 4, a second lock is added beside an existing one. Under option 5, SEND is changed.

## 3. Design

### 3.1 Invariant

In one atomic step, while writes to the queue are excluded and after its first message is read:
- the Sub is inserted into `subscriptions` with `delivered` set to the message read;
- the registry entry is written into `queueSubscribers` or `serviceSubscribers`.

The registry is read by SEND only after its write is committed (S:2050, 2082-2088). For every message, one of three cases holds [I8]:
- the message is included in the SUB read;
- the new Sub is returned by SEND's registry lookup;
- the message was pushed to the previous subscriber before the registration (duplicate delivery across connections, as on master).

A double push to the new subscriber is prevented by setting `delivered` in the same step.

### 3.2 PostgreSQL store

A per-queue STM callback is added to `tryPeekMsgs` (MPG:197-214).

```
uninterruptibleMask_ $ withTransactionPriority dbStore True     -- D8, PGC:94-97
  SET LOCAL synchronous_commit TO OFF                            -- D9
  locked <- SELECT <queueRecQuery columns> FROM msg_queues
              WHERE recipient_id IN ? AND deleted_at IS NULL
              ORDER BY recipient_id FOR UPDATE                    -- statement 1
  msgs <- SELECT q.recipient_id, m.msg_id, m.msg_ts, m.msg_quota, m.msg_ntf_flag, m.msg_body
            FROM msg_queues q
            CROSS JOIN LATERAL (
              SELECT msg_id, msg_ts, msg_quota, msg_ntf_flag, msg_body FROM messages
              WHERE recipient_id = q.recipient_id ORDER BY message_id ASC LIMIT 1
            ) m
            WHERE q.recipient_id IN ?                             -- statement 2, D10
  for each (q, verifiedRec) with rId in locked:
    a <- atomically (f q verifiedRec lockedRec msg_)               -- verify + register
  COMMIT                                                          -- row locks released
```

1. Ordering against SEND. The same row is locked by `write_message` (MIG:850-853).
   - SEND transaction committed first: the message is read by statement 2 and returned with `delivered` set. Either no Sub or a Sub with `delivered = Just` is returned by SEND's later lookup, and the push is skipped.
   - SUB transaction committed first: SEND's write is delayed until that commit. The Sub is then returned by SEND's lookup with `delivered = Nothing` and state `NoSub` (D7), and the message is pushed.
2. Statement 2 is kept separate. In a single `... JOIN LATERAL messages ... FOR UPDATE` statement, only the locked row is re-checked after a wait, and `messages` rows are read from the snapshot taken before the wait (INFERENCE). A new snapshot is taken for statement 2 under READ COMMITTED (INFERENCE).
3. Lock order. With `ORDER BY recipient_id`, rows are sorted by PostgreSQL before `LockRows` (INFERENCE), so locks are acquired in ascending order.
4. Batch size. The transmission count of a received block is parsed from one byte (S:1152 → Protocol.hs:2443, 2415, 2423 → Encoding.hs:113-114, 174-179). One `rcvQ` item is written per block (S:1168), so at most 255 rows are locked per transaction.
5. Verification against the locked record. The record is used in SUB verification only through `recipientKeys` (S:1303). Callback results:
   - accepted when the locked keys equal the verified snapshot's keys;
   - AUTH when the keys differ (D5);
   - `BLOCKED info` on `EntityBlocked`.
6. A queue without a locked row (deleted) is absent from the result map; AUTH is returned for it in `processCommand`.
7. Callback restrictions: STM only; store calls, `retry` and `TBQueue` writes are excluded.

### 3.3 STM store

```haskell
tryPeekMsgs _ qs f = liftIO $ M.fromList . catMaybes <$> mapM run qs
  where
    run (q, qr) = atomically $ readTVar (queueRec q) $>>= \qr' -> Just . (recipientId q,) <$> (f q qr qr' =<< peek q)
    peek STMQueue {msgQueue'} = readTVar msgQueue' $>>= tryPeekMsg_
```

1. `writeMsg` is one transaction over `msgQueue'` and the queue TVars (MSTM:115-127).
2. Under STM serializability (INFERENCE), either the message is included in the SUB transaction, or the registration is returned by SEND's `readTVarIO` lookup after SEND's commit.
3. `queueRec` is read in the same transaction, so DEL (QSTM:281), RKEY (QSTM:199-205) and blocking are covered.

The journal store was removed in f1f07904.

### 3.4 Interface

1. MT:59:
   ```haskell
   tryPeekMsgs :: s -> [(StoreQueue s, QueueRec)] -> (StoreQueue s -> QueueRec -> QueueRec -> Maybe Message -> STM a) -> ExceptT ErrorType IO (Map RecipientId a)
   ```
2. Callback arguments: verified record, locked record, first message.
3. Single caller: S:1443.

### 3.5 Synchronous registration

1. `updateSubscribers` with its helpers (S:271-327) and `endPreviousSubscriptions` with `removeWhenNoSubs` (S:329-356) are moved to top level.
   - Parameters added: `ServerSubscribers s`, `clientSubs`, `clientServiceSubs`, `unsub_`.
   - SMP calls pass `Just clnt`; the ntf loop keeps the `getServerClient` lookup (S:266).
   - `subClients` is written only when the client ID is absent (S:278, 295).
2. Registered in the SMP commands thread:
   - SUB and NEW+`SMSubscribe` (`CSClient`, S:1860, 1787);
   - SUBS (`CSService`, S:1963);
   - DEL (`CSDeleted`, S:2259) [I3].
3. Items are no longer queued to the SMP serverThread, and its start (S:188) is removed. The ntf serverThread is kept for NSUB, NSUBS and ntf `CSDeleted` (S:1729, 1740, 2266).
4. Registration and END handling are run under one `uninterruptibleMask_`.
5. END path: events are added to `pendingEvents` (S:331) and written to `sndQ` by sendPendingEvtsThread (S:436-443). `cancelSub` is run after COMMIT.
6. The own-map lookup, the Sub insert and the registry upsert are run in one STM transaction. On the [I4] path, a displaced client is re-registered with its existing Sub between the displacing batch's COMMIT and its `endPrevSMP`; that Sub is then removed by `endSub` (S:344), and END is sent to both clients (§4 item 11).

```haskell
registerSMP cs = updateSubscribers subscribers subscriptions serviceSubsCount (Just clnt) (cs, clientId)
endPrevSMP = endPreviousSubscriptions subscribers subscriptions serviceSubsCount (Just cancelSub)

prepareBatchSubs clntServiceId_ batch = do
  ts <- liftIO getSystemSeconds
  let (subQs, rcvAssocQs, ntfAssocQs) = foldr partitionSubs (M.empty, [], []) batch -- subQs: rId -> (q, verified rec)
  liftIO . E.uninterruptibleMask_ $ do
    prevs <- newTVarIO []
    r <- runExceptT $ do
      rcvAssocs <- ifNotNull rcvAssocQs $ setService SRecipientService clntServiceId_
      ntfAssocs <- ifNotNull ntfAssocQs $ setService SNotifierService clntServiceId_
      let subQs' = M.filterWithKey (\rId _ -> all isRight $ M.lookup rId rcvAssocs) subQs
      subs <- ifNotNull (M.elems subQs') $ \qs -> tryPeekMsgs ms qs (subscribeLocked prevs ts)
      pure (subs, rcvAssocs, ntfAssocs)
    readTVarIO prevs >>= endPrevSMP                                                     -- [I7, L3]
    pure r

subscribeLocked prevs ts q qr qr' msg_
  | recipientKeys qr' /= recipientKeys qr = pure $ Left AUTH
  | EntityBlocked info <- status qr' = pure $ Left $ BLOCKED info
  | otherwise = Right <$> subscribeQueue prevs ts q qr msg_

subscribeQueue prevs ts q QueueRec {rcvServiceId} msg_ =                              -- STM, from S:1749-1778
  TM.lookup rId (subscriptions clnt) >>= \case
    Just Sub {subThread = ProhibitSub} -> pure SubProhibited
    Just s | rcvServiceId == clntServiceId ->                                            -- [I4]
      SubDone True True [] msg_ <$ maybe (writeTVar (delivered s) Nothing) (\msg -> setDelivered s msg ts) msg_
    s_ -> do
      ((hasSub, sub_), srvStats) <- sharedSubscribeQueue rId q rcvServiceId subscriptions serviceSubsCount (newSubscription NoSub) (\cs -> registerSMP cs >>= modifyTVar' prevs . (++))
      forM_ s_ $ \s -> writeTVar (delivered s) Nothing
      forM_ msg_ $ \msg -> maybe (lookupInsertSub rId) pure sub_ >>= \sub -> setDelivered sub msg ts
      pure $ SubDone (isJust s_) hasSub srvStats msg_
```

1. `processCommand` SUB (S:1606-1608):
   - the result is taken from `M.lookup entId subs`; AUTH is returned for a missing entry;
   - SOK, MSG and the counters `qSubProhibited`, `qSubDuplicate`, `qSub` and the service counters are produced as today;
   - `False` is passed to `withQueue_` by `withQueue'` (S:1825-1827): `updateQueueTime` is kept, and BLOCKED is decided on the locked record.
2. `sharedSubscribeQueue` (S:1848-1898) is converted to STM, with a `register :: ClientSub -> STM ()` parameter.
   - SUB: the `registerSMP` wrapper above.
   - NSUB: `\cs -> writeTQueue (subQ ntfSubscribers) (cs, clientId)`, under `atomically`.
3. The association update is kept before the lock (S:1441); the association decision is based on the verified snapshot's `rcvServiceId`. Association races are deferred (D2).
4. The `Just s` short-circuit is taken only when the snapshot's association equals the client's [I4]. Otherwise the registration is run with the existing Sub (count, `CSClient`, `endQueueSub`).
5. On both existing-Sub paths, `delivered` is set to `Nothing` or to the message read, as on master (S:1763, 1769-1772).

### 3.6 SUBS, NSUB, NSUBS

1. S:1963 is replaced by a `register :: ClientSub -> IO ()` parameter of `sharedSubscribeService` (S:1942-1964).
   - SUBS: `E.uninterruptibleMask_ (atomically (registerSMP cs) >>= endPrevSMP)`; the service is registered before the fork at S:1906 (D3).
   - NSUBS: `atomically . writeTQueue (subQ ntfSubscribers) . (,clientId)`.
2. SUBS fold [I6]: in `deliverQueueMsg` (S:1922-1936), the Sub lookup, the insert and `setDelivered` are run in one STM transaction; `msgQ` is written after it.
   ```haskell
   Just (qr, msg) -> do
     ts <- getSystemSeconds
     new <- atomically $ TM.lookup rId (subscriptions clnt) >>= \case
       Just _ -> pure False
       Nothing -> do
         sub <- newSubscription NoSub
         setDelivered sub msg ts
         TM.insert rId sub (subscriptions clnt)
         pure True
     if new
       then atomically (writeTBQueue msgQ [(NoCorrId, rId, MSG (encryptMsg qr msg))]) $> (qCnt + 1, msgCnt + 1, dupCnt, evts)
       else pure (qCnt + 1, msgCnt, dupCnt + 1, evts)
   ```
3. The ntf serverThread is kept for NSUB and NSUBS. Notifications are kept in the store until a delivery transaction is committed (S:397-411), so delivery is only deferred by a registration delay. NSUBS is kept asynchronous: with a synchronous NSUBS registration, the new connection would be ENDed by a queued NSUB `CSClient` of an older connection.

### 3.7 Delivery thread state (D7) [I1]

`NoSub` is written in every outcome of `deliverThread` (S:2129-2142):

```haskell
deliverThread = getSubscribed >>= maybe (atomically $ writeTVar st NoSub) deliverIfSame
deliverIfSame rcv = do
  ts <- getSystemSeconds
  atomically $ do
    whenM (sameClient rc rcv) $ readTVar delivered >>= \case
      Just _ -> pure ()
      Nothing -> deliver sndQ' s ts
    writeTVar st NoSub
```

The blocked transaction is re-run after the `delivered` write of a duplicate SUB, and `NoSub` is written in that run. For this reason the SUB-side part of the [I1] correction (state reset and `cancelSub`) is omitted.

### 3.8 Diff (expected line deltas)

Commits:
1. Tests T1, T2 (failing or timing-dependent before the fix) and T5 (passing before the fix, §4 item 9).
2. Pure move of the serverThread helpers.
3. The fix, with D4, D8, D9, D10.
4. D7 with T4.

D7 with T4 moved to `ep/smp-delivery-thread-state`, and D9 with D10 to `ep/smp-sub-lock-pg` (section "Pull requests").

| File | Function | Delta |
|---|---|---|
| S | `serverThread` (S:251-356) → ntf loop | −88 +4 |
| S | top-level `updateSubscribers`, `endPreviousSubscriptions` | +92 |
| S | SMP serverThread start (S:188) | −1 |
| S | `client`: `clntServiceId` to `where`; `registerSMP`, `endPrevSMP` | ±1 +4 |
| S | `prepareBatchSubs` (S:1427-1448) | −8 +19 |
| S | `processCommand` SUB (S:1606-1608), `withQueue'` (S:1825-1827) | ±4 |
| S | `subscribeQueueAndDeliver` + `getSub` (S:1749-1778) → `subscribeQueue` + response builder | −30 +34 |
| S | `subscribeNewQueue` (S:1780-1787) | −8 +6 |
| S | `subscribeNotifications` (S:1841-1846) | −6 +8 |
| S | `sharedSubscribeQueue` (S:1848-1898) → STM | −51 +32 |
| S | `sharedSubscribeService` (S:1942-1964) + callers (S:1902, 1940) | −2 +5 |
| S | `deliverQueueMsg` (S:1922-1936) | −8 +12 |
| S | `delQueueAndMsgs` (S:2259) | ±1 |
| S | `deliverThread`, `deliverIfSame` (S:2129-2142), D7 | −3 +6 |
| S | `SubResult` type | +3 |
| Env | `lookupDeleteSubscribedClient` (Env:389-391) | +1 |
| MT | `tryPeekMsgs` (MT:59) | ±1 |
| MSTM | `tryPeekMsgs` (MSTM:136-137) | −2 +5 |
| MPG | `tryPeekMsgs` (MPG:197-214), imports | −17 +27 |
| QPG | export `queueRecQuery`; priority `withDB` variant; ordered lock in `setQueueServices` (D4) | +8 |
| tests/ServerTests.hs | T1, T2, T4, T5 | +170 |

### 3.9 Deviations in the implementation

1. `clntServiceId` stays a `let` binding of `client`. A `where` binding would be shadowed by the `processCommand` parameter of the same name, which is `Nothing` for forwarded commands (S:2207).
   - `subscribeLocked` and `subscribeQueue` are local to `prepareBatchSubs` and read its `clntServiceId_` parameter.
   - `sharedSubscribeQueue` takes the client's service ID and the entity ID as its first two parameters.
2. `sharedSubscribeQueue` and `setDelivered` are moved from the `processCommand` `where` to the `client` `where`.
3. `sharedSubscribeQueue` returns the service counters to increment, `[ServiceStats -> IORef Int]`. They are incremented after the transaction, on `rcvServices` for SUB and on `ntfServices` for NSUB.
4. TMap exports `lookupOrInsert` in STM; `lookupOrInsertIO` calls it. Callers:
   - `sharedSubscribeQueue`;
   - `subscribeQueue`;
   - `deliverQueueMsg`, which creates the Sub with `delivered` set inside it.
5. `updateSMPSubscribers` runs a registration transaction and `endPrevSMP` under one `uninterruptibleMask_`. Callers: SUBS, DEL, NEW with `SMSubscribe`.
6. `withDB op st = withDBPriority op st False`, as `withTransaction` (PGC:89-91).
7. T4 (`testSubPendingDelivery`) keeps the test `tbqSize` 4 (tests/SMPClient.hs:249) and fills the send path of recipient connection C without reading:
   - 4 blocks of 255 LGET of one contact queue with 13 KB link data, one LNK per 16 KB block, 4 sndQ items in all;
   - one SEND from C to a probe queue of connection S; its MSG on S confirms that C's commands thread processed the LGET blocks;
   - SENDs from S to 4 filler queues of C, then to the tested queue, whose delivery thread then waits for sndQ;
   - SUB of the tested queue from C, then 0.5 s before C reads.
   - Full sndQ is reached when the TCP buffers hold less than the 4 LGET batches (≈16 MB); otherwise the test passes on master too.

## 4. Dangers

1. Deadlocks on `msg_queues` rows.
   - Rows are locked by SUB batches in `recipient_id` order.
   - Single-row lockers: `write_message`, `try_del_msg`, `try_del_peek_msg` (MIG:850-853, 879-882, 925-928) and the QPG single-row UPDATEs.
   - `SKIP LOCKED` is used by expiry (MIG:817).
   - The unordered multi-row association UPDATE (QPG:397-399) is preceded by `SELECT ... ORDER BY recipient_id FOR UPDATE` in its transaction (D4).
2. Deadlocks on `services` rows [L6]. `services` rows are locked by AFTER UPDATE row triggers in row-processing order (MIG:532-571). A deadlock can occur when two services exchange queues concurrently; one batch is then aborted by PostgreSQL after `deadlock_timeout` (INFERENCE). The cycle is present on master and is left unchanged (D11).
3. Lock hold time.
   - Held for: statement 1, statement 2, at most 255 STM registrations, COMMIT, and the commands thread's run-queue delay after each round trip [C-A8].
   - One message row per queue is read by statement 2 (D10) [L2]. Every message row of the batch's queues is read by the current `DISTINCT ON` form (INFERENCE), up to 129 rows per queue (quota Env:256, plus the quota marker, MIG:855-860).
   - Up to 100 rows are held by the expiry page until its COMMIT (MIG:775-794). Queues locked by an in-flight SUB batch are skipped by that expiry run (MIG:817; cursor advance MIG:796-797) [C-A9].
   - Measured in V4.
4. COMMIT under the lock [L1, C-B2]. With `FOR UPDATE`, an XID is assigned and COMMIT is delayed until the WAL flush (INFERENCE). Resolution: `SET LOCAL synchronous_commit TO OFF` (D9). When a commit record is lost in a crash, only row locks are discarded; row contents are unchanged by the transaction (INFERENCE).
5. Pool occupancy [C-B1, L7].
   - `dbPool` is used for command verification (S:1165 → QPG:187; QPG:637-639 → PGC:63-69) and for expiry (MPG:98, PGC:77-78).
   - Resolution: the SUB transaction is run on `dbPriorityPool` (D8). That pool is opened with `poolSize` connections at start (Agent/Store/Postgres.hs:59, 73); it is used only by the notifications server (Notifications/Server/Store/Postgres.hs:760).
   - Wait cycles are excluded: a priority-pool connection is never requested by `dbPool` holders (SEND, ACK, expiry), each holding one connection.
   - One connection per batch is held, since the callback is restricted to STM.
6. STM re-executions under row locks [I5, L4, C-B3, C-B4].
   - Only `TVar`/`TMap` operations are used in registration transactions (`upsertSubscribedClient` Env:375-382, `newSubscription`, `checkAnotherClient`).
   - The `queueSubscribers` map TVar is read by every registration (Env:377). After a restart (Env:490) or a reconnect (new `clientId`, S:1066-1068; keys deleted on disconnect, S:1128 → Env:399-403), a key is inserted by every registration (Env:378).
   - The map is written by `endQueueSub` through `stateTVar` even for an absent key (Env:391 → TMap:87-89). Resolution: in Env:389-391 the key is looked up first, and the map is written only when the key is present:
     ```haskell
     lookupDeleteSubscribedClient entId (SubscribedClients cs) =
       TM.lookup entId cs $>>= \cv -> TM.delete entId cs >> swapTVar cv Nothing
     ```
   - `subClients` is added to every read set by the absent-ID check (§3.5 item 1) and written by every disconnect (S:1129).
   - `totalServiceSubs` is written only by service registrations and decrements (S:282, 296, 338, 348, 1133). The transactions of one batch are run sequentially in one thread (§3.2 loop, §3.3 `mapM`), so a conflict on it is caused only by a commit in another thread: a service registration, a decrement in `endPreviousSubscriptions` (S:338, 348) or a service disconnect (S:1133). It is read only by metrics (S:718). For this reason the [C-B3] batching of its delta is deferred to D12.
   - Estimates [C-A3]: 1.4% re-runs at the measured 2.4k SUB/s; 40-63% at 160k SUB/s, i.e. 2-10% of per-SUB CPU.
   - Measured in V4; fallbacks in D12.
7. SEND latency. A SEND to a queue of an in-flight batch is delayed at `write_message` (MIG:853) until the batch COMMIT. Estimated probability ≤ 0.26% at 10^6 queues and pool size 10 [C-A9]. STM store: only STM conflicts on the same queue apply.
8. Disconnect during subscription.
   - Registration and END handling are kept together by `uninterruptibleMask_`.
   - `clientDisconnected` is run after the client threads end (S:1069; `raceAny_` cancel waits, INFERENCE). Registrations whose keys are in the swapped map (S:1109, 1126-1128) and the service registration (S:1131-1133) are removed.
   - The Sub key and the registry entry are written in one transaction.
9. DEL ordering [I3]. If an asynchronous `CSDeleted` were applied after a synchronous SUBS registration, the new connection's count would be reduced by a queue absent from that count (S:292, 312-314, 336, 346-351; aggregate MIG:536-538).
   - `CSDeleted` is registered synchronously in `delQueueAndMsgs` (§3.5 item 2). The window is narrowed to the steps between `deleteQueue` (S:2251) and that registration (S:2259) in the deleting connection's commands thread: the Sub removal, `cancelSub` and the count update.
   - A SUBS of another connection of the same service can read the count (S:1951) and register (S:1963) within that window. `CSAEndServiceSub` is then returned for that connection by the `CSDeleted` registration, and its count is reduced by the deleted queue; a count of 1 is set to `(0, mempty)` (Protocol.hs:1600-1602), although a queue remains associated.
   - The window is closed only when the count read and the SUBS registration are ordered against the deletion under a lock; SUBS registers without a store lock (D3).
   - T5 checks the final outcome; it does not reproduce [I3], since C2 is connected only after the DEL response is received. T5 passed on master code in https://github.com/evgeny-simplex/simplexmq/actions/runs/40420084415 (09eda0ed), where `CSDeleted` is queued to the FIFO `subQ` before the later `CSService`.
10. DEL and key changes during a batch.
    - Committed before the lock: the row is re-checked by `FOR UPDATE`, and AUTH is returned for a deleted row or changed keys.
    - Arriving during the lock: DEL's UPDATE (QPG:334) is delayed until COMMIT; the batch's registration is then removed by the synchronous `CSDeleted`.
    - STM store: `queueRec` is in the read set.
    - `EntityOff` stays subscribable (tests/ServerTests.hs:408).
11. Resubscription by another client. After concurrent takeovers, the last registration is kept. END is sent to the previous client only while it is connected (S:325-326). On the [I4] path, both clients may be sent END, and both Subs are removed (§3.5 item 6).
12. Error after registration [I7, L3]. An error is returned after registrations were committed in STM by the callbacks:
    - STORE on a COMMIT failure (connection loss, PostgreSQL restart, WAL flush error);
    - AUTH or STORE on an `updateQueueTime` failure (QPG:314-325) in `withQueue_` (S:1836-1839), run in `processCommand` after `prepareBatchSubs` (S:1423-1424); MSG of the message read is withheld while `delivered` is set.
    - Resolution: displaced-client entries are appended to a batch-local `TVar` in the registration transaction, and `endPrevSMP` is run on both outcomes (§3.5 pseudocode).
    - The `delivered := Nothing` reset of [I7] is omitted. The message read is kept first in the queue, so later SENDs are written with `was_empty = false` (MIG:855-857) and pushes are skipped irrespective of `delivered`. The message is returned by the next SUB, and `delivered` is overwritten in its existing-Sub branch.
    - The registrations are kept; MSG pushed to that client is processed by the agent irrespective of subscription state (Agent.hs:3603-3604).
13. Isolation level [L5]. Rejected. Under REPEATABLE READ, a serialization failure is raised by `FOR UPDATE` on a row updated after the snapshot (INFERENCE); that row is updated by `write_message` (MIG:862-865). STORE is then returned for the batch, and the message is kept in the queue. Concurrently written rows are already locked and updated by `write_message`, `try_del_msg` and `try_del_peek_msg` (MIG:850-865, 879-882, 925-928), so READ COMMITTED is required server-wide on master.
14. Disk writes from row locks (D1). The tuple header is written by `FOR UPDATE`: one WAL record per row, and a full-page image on the first change of a page after a checkpoint (INFERENCE). WAL of the order of the `msg_queues` heap size (≈400 MB at 10^6 queues, INFERENCE) is written in a full restart storm [C-A8]. Measured in V5.
15. Stale delivery-thread state [I1]. `SubThread` is left set when `delivered = Just` is read by the thread (S:2136-2142); later pushes are skipped (S:2103, 2111). Resolution D7.
16. Association races [I2, I4].
    - Existing-Sub short-circuit that skips the association bookkeeping [I4]: resolved by the guard in §3.5 item 4.
    - Association and registration in separate transactions [I2]: on master and on this design, SEND routing and the registry may be left inconsistent after concurrent association changes by a service and a non-service connection (S:1441; QPG:383-399; S:2086-2088). Deferred to D2.
17. SUBS fold duplicate [I6]: resolved in §3.6 item 2.
18. Same-queue batches (D6). In `[SUB q, GET q]`, PROHIBITED is returned for GET and SOK for SUB; on master the outcomes are reversed.
19. MSG before SOK. MSG may be pushed before SOK is sent; MSG is processed by the agent irrespective of subscription state (Agent.hs:3603-3604, 3672-3690).

## 5. Verification

1. T1, deterministic reproduction, both stores.
   - NEW with `SMOnlyCreate`; one client block `[SUB rId (signed), SEND sId "hello" (unsigned)]`.
   - Expected in any order: `MSG hello`, and a block `[SOK, OK]` read with `tGetClient` (`receiveInAnyOrder` reads one transmission per block, ServerTests:947-953).
   - Master: SEND is processed first by `foldrM`, after the empty read (S:1443) and before registration. QUE result: `QSub {QNoSub, qDelivered = Nothing}`, `qiSize = 1`.
   - Fix: the registration is committed in `prepareBatchSubs`, before `foldrM` (S:1423-1424).
2. T2, SUBS, both stores.
   - A service client creates the queue and disconnects. A new service connection sends `[SEND sId, SUBS 1 hash]`.
   - Expected: one MSG, OK, SOKS and ALLS. Deterministic with §3.6 item 2; timing-dependent on master.
3. T4, D7, both stores.
   - Test server config with a small `tbqSize`; the test client stops reading until `sndQ` is full.
   - SEND; duplicate SUB; ACK; SEND. Expected: MSG for the second SEND.
   - Determinism of the full-`sndQ` step: T4 was run on e85d8579 (commit 3 with T4, without D7) in https://github.com/evgeny-simplex/simplexmq/actions/runs/40443527767 (job 121989282031). It failed on both stores with `expected: (Just QNoSub,True,1) but got: (Just QSubThread,False,1)`.
4. T5, DEL ordering, both stores.
   - Service connection C1 with queues Q1, Q2; DEL Q1; SUBS from C2 of the same service; SUBS from C3.
   - Expected: ENDS to C2 with count 1 and the hash of Q2.
5. T3 (D2 follow-up): `[SUB rId (association change), SEND sId]` from a service connection; expected MSG.
6. Suites, each run in full (`--ghc-options -O0` locally):
   - `SMP server via TLS, memory message store`
   - `SMP server via TLS, postgres-only message store`
   - `Message store tests`
   - `SMP client agent, server memory message store`
   - `SMP client agent, server postgres-only message store`
   - `Notifications server (SMP server: memory store)`
   - `Notifications server (SMP server: postgres-only store)`
   - `SMP proxy, memory message store`
   - `SMP proxy, postgres-only message store`
   - with D2: `SMP server schema dump`
7. V4, contention, harness `scratchpad/bench-1989/harness/ServerBench.hs` [C-B5, L4, L7].
   - Harness changes:
     - receiver count as a CLI argument (fixed `stormClients = 8`, ServerBench.hs:66);
     - "displace" scenario: all queues subscribed on connection set A, then on set B while A stays connected;
     - variant without prefill (ServerBench.hs:85);
     - service-association storm;
     - `SSCDatabase` configuration at pool size 10 (BenchUtil.hs:60 configures `SSCMemory` only).
   - Benchmark-build instrumentation, outside the PR:
     - `unsafeIOToSTM` counter at the start of the registration transaction;
     - connection acquisition time in `withConnectionPool` (PGC:63-69);
     - per-batch connection hold time.
   - Runs: A = c0c416da, B = fix; `-N` equal to the production core count; receivers 8 and 4×N.
   - Report:
     - subscribe window;
     - SUB batch response p50/p99;
     - ACK latency p99;
     - delivered/s;
     - server CPU;
     - registration re-executions per SUB;
     - pool acquisition p99;
     - WAL bytes per subscription (`pg_current_wal_lsn()` deltas);
     - lock waits (`pg_stat_activity`, `wait_event_type = 'Lock'`).
8. V5, D1 and D9 pre-measurement on master's schema (SQL only).
   - `CHECKPOINT`, then 255-row `ORDER BY recipient_id FOR UPDATE` transactions over random queues.
   - Record:
     - WAL per locked row, with and without full-page images;
     - COMMIT latency with `synchronous_commit` on and off;
     - `txid_current()` deltas;
     - WAL of `write_message` for comparison.
9. D10: `EXPLAIN (ANALYZE, BUFFERS)` of statement 2 and of the current `DISTINCT ON` query, on a 255-queue batch with backlog.

## 6. Open questions

1. D1. PostgreSQL lock primitive.
   - (a) `FOR UPDATE`. Cost: §4 item 14.
   - (b) Advisory transaction locks, shared in SUB and exclusive in `write_message`. Cost: a migration; lock-table capacity (`max_locks_per_transaction` × connections, INFERENCE) against 255 locks per batch × pool size.
   - Recommendation: run V5 first; keep (a) unless WAL per subscription is material.
2. D2. Association races, follow-up PR.
   - SEND is routed by `rcv_service_id` returned from `write_message` under its own row lock: a migration adds the return column `r_rcv_service_id`; the value is stored into the queue record TVar by `writeMsg` and read by `tryDeliverMessage` (S:2086-2088, 2113).
   - SUB association is run in the locked transaction after statement 1, with the previous service ID taken from the locked row [I2]. The S:1441 transaction is replaced for SUB.
   - Recommendation: follow-up PR with T3 and an [I2] test.
3. D3. SUBS registers before the fold. Credentials are the session's verified service signature (S:1321-1325). Locking all service rows is unbounded, and `msgQ` is written inside the fold transaction (MPG:110-132). Recommendation: accept.
4. D4. Ordered lock in `setQueueServices`. Cost: +3 lines and one statement per association batch. Recommendation: include.
5. D5. Credential re-check by key equality. AUTH is returned for changed keys. RKEY is accepted only for contact queues (S:1612) and is referenced only in Server.hs and Protocol.hs. Recommendation: accept.
6. D6. Same-queue batch order (§4 item 18). Recommendation: accept.
7. D7. Stale `SubThread` fix (§3.7) [I1]. The loss path is present on master, with signature `QSubThread`, `qDelivered = Nothing`, `qiSize >= 1`. Recommendation: include as its own commit with T4.
8. D8. SUB transaction on `dbPriorityPool` [C-B1]. Cost: one `withDB` variant (≈4 lines); up to `poolSize` more active sessions on connections opened at start. Recommendation: include.
9. D9. `SET LOCAL synchronous_commit TO OFF` in the SUB transaction [L1, C-B2]. Cost: one statement per batch. Recommendation: include; confirm with V5.
10. D10. Statement 2 as a lateral `LIMIT 1` per queue [L2], the shape of the SUBS fold query (MPG:121-127). Recommendation: include after the EXPLAIN in §5 item 9.
11. D11. `services`-row lock cycle [L6]. Option: lock `services` rows in `service_id` order before the association UPDATE. Recommendation: leave unchanged; the cycle is present on master and occurs only when two services exchange queues concurrently.
12. D12. Contention fallbacks, applied only if V4 shows registration re-executions or lock waits that raise SUB p99:
    1. `IS.member` guard on the disconnect delete of `subClients` (S:1129) [C-A5];
    2. one `totalServiceSubs` delta per batch after COMMIT [C-B3];
    3. `SubscribedClients` (Env:365) split into a fixed array of TMaps keyed by one ID byte [L4].
    - Recommendation: measure first; apply in the listed order.
