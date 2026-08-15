# Fast queue rotation — implementation plan

Branch: ep/drop-agent-versions. RFC: ../rfcs/2026-08-09-fast-queue-rotation.md.

Model: redundant delivery, no flip. `QADD` adds the new receive queue R'. From `QADD` until R' is
secured the sender writes every message to both old and R' (double delivery, not a move); once R' is
secured the sender writes new messages to R' only, while old delivers its already-scheduled tail and
the `QEND` appended to it. `QEND` removes a named queue. The recipient drops duplicates (double
ratchet), so the order and which queue delivers do not matter, as long as every message arrives on at
least one queue. Rotation away from a dead server works because every message up to securing is
scheduled on R' too.

Roles: A initiates (its receive queue rotates; A receives on R'). B sends to A and secures R'.

## Why redundant delivery removes the hard parts

- No boundary, no drain, no last-message id. A never decides how much of old to read.
- A dead old server loses nothing: every undelivered message is scheduled on R' as well.
- A dead new server does not suspend delivery: old keeps delivering until R' is secured.
- The double ratchet already drops duplicates (`AGENT A_DUPLICATE`) and tolerates bounded reordering,
  and the delivery schema already writes one message to several send queues (`enqueueMessageB` +
  `enqueueSavedMessageB`).

## The one ordering constraint

A must hold R''s secret before it reads any R' data message. A data message reaching R' before the
confirmation is dropped as "no keys" (`processClientMsg`, `(Nothing, Nothing)` arm, line 3611), which
loses it when old is dead. So the confirmation is the first message B sends on R'. R''s delivery
worker does not start while R' is securing, so its accumulated rows cannot outrun the confirmation.
`ICQSndSecure` sends the confirmation and only then starts the worker. This holds on restart too (see
Worker gate).

## New definitions

Agent/Protocol.hs
- Condition fast rotation on the existing `rpcAddressSMPAgentVersion` (v8, `Protocol.hs:322`).
- New `AMessage` constructor `QEND SndQAddr` (tag `QE`), the address of the queue to remove. v8-only,
  and only sent during fast rotation, so peers below v8 never parse it.
- `SndSwitchStatus` constructors `SSSecuringQueue` (old, while R' secures) and `SSSendingQEND` (old,
  after R' is secured — it drains its tail and `QEND` but takes no new messages).
- `InternalCommand` constructor `ICQSndSecure SMP.SenderId`.

No receive-side switch status, no boundary, no drain state.

## Schema

None. `SSSecuringQueue` uses `snd_queues.switch_status`; R' is secured into `rcv_queues.e2e_dh_secret`.
No new columns, no migration.

## Sender B

### Dual scheduling from QADD

`enqueueMessageB` writes a delivery row for the head send queue and for each `filter isActiveSndQ`
tail queue (`Agent.hs:2345`). Adjust the selection two ways: additionally include a securing
replacement queue on a v8 connection (`connAgentVersion cData >= rpcAddressSMPAgentVersion && status == New && isJust dbReplaceQueueId`),
and exclude a terminating queue (`sndSwchStatus == Just SSSendingQEND`). The version guard keeps the
slow path unchanged — there R' is also `New` with a replace reference during `QKEY`/`QUSE`, but it must
not be dual-scheduled. `SSSendingQEND` is a fast-path-only status, so the exclusion never affects the
slow path. The gate below is inert for the slow path anyway, since it never starts R''s worker while
`New`.

- `QADD` until R' secured: old is the head (active) and R' is the securing replacement, so every `SEND`
  writes both rows. old delivers at once; R''s rows accumulate behind its gate.
- R' secured: R' is the head (primary) and old is `SSSendingQEND` (excluded), so a `SEND` writes R'
  only. old keeps its worker and delivers whatever was already scheduled on it, plus `QEND`.

### Worker gate

`submitPendingMsg` (`Agent.hs:2437`) and `resumeMsgDelivery` (`2421`) — the two `getDeliveryWorker`
callers that start delivery — skip a queue with `status == New && isJust dbReplaceQueueId`, so neither
a `SEND` nor startup starts R''s worker while it secures. Startup resumes delivery through
`resumeMsgDelivery` (`resumeDelivery` line 1848, and `getAllSndQueuesForDelivery` line 1943), so R' is
skipped there; `resumeAllCommands` (1883) resumes R''s `ICQSndSecure`, which secures R' and only then
starts its worker.

### Steps

`qAddMsg` (fast branch, under the connection lock, `Agent.hs:3855`):
- Add R' as the slow path does (line 3870): `addConnSndQueue (sq_) {primary = True, dbReplaceQueueId = Just old}`, `New`.
- Duplicate **every** undelivered message on old to R': for each pending row on old
  (`SELECT internal_id FROM snd_message_deliveries WHERE conn_id = ? AND snd_queue_id = old AND failed = 0`),
  `createSndMsgDelivery db R' internalId`. This is the loss-prevention step: old's not-yet-sent
  messages are duplicated onto R', so if old later fails they are already on R'. If old is already
  down, nothing was sent and the whole backlog is duplicated.
- `enqueueCommand (Just newSrv) (ICQSndSecure sndId)`; `setSndSwitchStatus SSSecuringQueue` on old
  (where the slow path sets `SSSendingQKEY`, line 3874); notify `SWITCH QDSnd SPStarted`. old keeps
  delivering; R''s worker is gated.

`ICQSndSecure sId` (retryable, under `tryWithLock`):
1. If old is already gone, a prior attempt finished; return. Otherwise find R' by `sId`.
2. `secureSndQueue` (SKEY) R' — idempotent, since `sndPrivateKey` was persisted by `qAddMsg`
   (`QueueStore/STM.hs:213`: same key → `Right ()`, different key → `AUTH`).
3. Send the confirmation on R' (`sendConfirmation`; empty body, both peers already know each other;
   `e2eEncryption_ = Nothing`, no ratchet step). It is the first message on R'.
4. On success, in one transaction: `setSndQueueStatus R' Active` (the gate lifts), `setSndQueuePrimary R'`
   (R' becomes the head; its replace reference is cleared), and `setSndSwitchStatus old (Just SSSendingQEND)`
   (old takes no new messages but keeps its worker). Then `submitPendingMsg c R'` (the worker starts and
   flushes the accumulated rows after the confirmation), `enqueueMessages [old, R'] (QEND oldAddr)`
   (appended after old's tail, delivered on both), and notify `SWITCH QDSnd SPSecured`. From here a
   `SEND` goes to R' only; old delivers its tail then `QEND` and is removed when `QEND` is sent.

A temporary error retries from step 1; nothing is torn down. A permanent `AUTH` (should not occur, R'
was secured with B's own key) leaves both queues and surfaces `A_QUEUE`.

`QEND` sent — new `AM_QEND_` arm in `runSmpQueueMsgDelivery`, modelled on `AM_QTEST_` (`Agent.hs:2567`):
on a successful send of `QEND addr`, remove the named send queue (`TM.delete` its worker,
`deleteConnSndQueue addr`), make the remaining queue the sole primary (`setSndQueuePrimary`, which
clears its `replace_snd_queue_id`), and notify `SWITCH QDSnd SPCompleted` (as `AM_QTEST_` does, line 2591). The handler is idempotent — a
second `QEND` send finds the named queue already gone and does nothing. `QEND` is sent on both queues;
removing old's send queue also drops any `QEND` still pending on old. The R' copy reliably removes old
and reaches A even when old is dead; the old copy is best effort. Once old's send queue is gone, `SEND`
schedules to R' only.

## Recipient A

A is subscribed to old (primary) and R' (created at rotation start, `dbReplaceQueueId = old`,
`RSSendingQADD`).

- **Confirmation on R'.** In `processClientMsg`, `(Nothing, Just e2ePubKey)` case, add an arm before the
  `senderCanSecure` arm (`Agent.hs:3476`), guarded by `isJust (dbReplaceQueueId rq)`. In one
  transaction: `setRcvQueueConfirmedE2E rq (C.dh' e2ePubKey e2ePrivKey) (min v phVer)` (secures R') and
  `setRcvQueuePrimary R'` (clears R''s replace reference). Then `ack`, and notify `SWITCH QDRcv SPConfirmed`.
  No conn-info processing, no ratchet step, no deferral. Redelivery is idempotent: R' now has `e2e_dh_secret`, so a re-sent
  confirmation reaches the `(Just e2eDh, Just _)` arm (line 3608) and is acked — correct here, since
  there is no backlog to hold.
- **Data on R'.** With R''s replace reference cleared, a data message on R' takes the ordinary path
  (`(_, dbReplaceQueueId=Nothing)`, line 3503) — no old-deletion, no `RSSendingQUSE` check. A copy
  already read on old is dropped as `A_DUPLICATE`; a copy read first on R' advances the ratchet and
  old's copy is then the duplicate.
- **`QEND oldAddr` on either queue.** New `AMessage` handler (`qEndMsg`, a `qDuplex` handler like
  `qAddMsg`): `findRQ oldAddr` the receive queue to remove. Mark it deleted (`setRcvQueueDeleted`, so
  `getRcvQueuesByConnId_`'s `deleted = 0` filter excludes it at once and a restart does not resurrect
  it) and `enqueueCommand (Just oldServer) (ICDeleteRcvQueue oldRcvId)` for the server `DEL` and record
  removal — the async, crash-safe path `abortConnectionSwitch` uses, which resumes on restart and does
  not block `QEND`, **not** the synchronous `deleteQueue` of `finalizeSwitch`, which would stall if old
  is unreachable. `ICDeleteRcvQueue` (`Agent.hs:2224`) currently retries a temporary error forever;
  bound it with the same persisted `rcv_queues.delete_errors`/`deleteErrorCount` mechanism `deleteQueueRec`
  uses (2884): on a temporary error `incRcvDeleteErrors`, and at the limit `deleteConnRcvQueue` and
  stop. The count is in the database, so the bound survives restarts, and its only other caller
  (`abortConnectionSwitch'`, 2739) deletes an alive queue that succeeds well before the limit. If the removed
  queue was primary, make the remaining one primary (`setRcvQueuePrimary`); re-create the notification
  subscription (`when enableNtfs $ sendNtfSubCommand ns (NSCCreate, [connId])`); notify
  `SWITCH QDRcv SPCompleted`; `ackDel` the `QEND`. Received on both queues, the second finds it already
  marked deleted and is a no-op.

No drain, no boundary, no finalize command. Old is removed when `QEND` arrives, not by counting.

## Abort / version

- Fast rotation runs only when `connAgentVersion >= v8`; otherwise the `QKEY`/`QUSE` slow path runs
  unchanged.
- `canAbortRcvSwitch` (`Agent/Store.hs:210`) returns false for `RSSendingQADD` when `connAgentVersion >= v8`
  (at v8 B always chooses fast, so A treats a sent `QADD` as committed). Its signature gains
  `connAgentVersion`; both callers pass it from `cData` — `abortConnectionSwitch'` (2730) and
  `rcvQueueInfo` in `connectionStats` (2976).

## Losses and duplication

- No boundary loss: the `QADD` step **duplicates** old's entire undelivered backlog onto R', and every
  later message up to securing is scheduled on both queues, so if old fails it loses nothing B still
  holds. The only messages old can strand are those its server already accepted but had not handed to
  A — the ordinary store-and-forward risk, present whenever a server fails with unread messages, and
  empty if old was already down (a down server accepted nothing).
- Duplicates: the double ratchet drops them (`A_DUPLICATE`); `checkMsgIntegrity`'s `MsgDuplicate` is
  only a flag, not the mechanism.
- The 512 skip bound (`Crypto/Ratchet.hs:953`) does not bite: each queue delivers in order and every
  message is on R', so A reads a contiguous stream with only small cross-queue reordering.

## Tests

- new/new, old stopped right after `QADD`: rotation completes; all messages delivered on R'; old
  removed by `QEND` on R'.
- new/new, both alive: messages delivered on both, deduped; old removed by `QEND`.
- new/old and old/new: fall back to the `QKEY`/`QUSE` path.
- crash during securing: restart does not start R''s worker; `ICQSndSecure` resumes, secures R',
  starts the worker, sends `QEND`.
- `QEND` received on both queues: old removed once, the second receipt is a no-op.
