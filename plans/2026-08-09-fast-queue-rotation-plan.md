# Fast queue rotation — implementation plan

Branch: ep/drop-agent-versions. RFC: ../rfcs/2026-08-09-fast-queue-rotation.md.

No new agent message. Both peers recognise the rotation from the replacement
reference (`dbReplaceQueueId`) on their own new queue. The confirmation carries
one value: `lastOldMsgId` — the last connection message id B committed to the old
queue before the flip. A uses it to know exactly how much to drain.

Roles: A initiates (its receiving queue moves; A receives on R'); B is the peer
that sends to A and secures R'.

## Delivery facts this relies on (from the reception loop)

- Per subscribed queue the server sends the next message only as the response to
  the ACK of the current one (`SMP.ACK _ -> … Right msg@SMP.MSG`). So **not ACKing
  a message pauses that queue.**
- `ack = enqueueCmd (ICAck rId srvMsgId)`; the ACK response (next `MSG`, or none)
  returns to `STResponse (Cmd SRecipient (SMP.ACK _))`, where "none" is currently
  `pure ()`.
- The confirmation on an unsecured queue is read via the `(Nothing, Just e2ePubKey)`
  + `PHEmpty AgentConfirmation | senderCanSecure` branch; it is not in the numbered
  message sequence.

## New definitions

Agent/Protocol.hs
- Condition fast rotation on the existing `rpcAddressSMPAgentVersion` (v8). No alias.
- `SndSwitchStatus` constructor `SSSecuringQueue`.
- `RcvSwitchStatus` constructor `RSDrainingOld`.
- `InternalCommand` constructor `ICQSndSecure SMP.SenderId`.
- Confirmation body for rotation: `lastOldMsgId :: Int64`, placed in `encConnInfo`,
  protected by the per-queue box, not ratchet-encrypted; read directly by A.

Agent/Store(.AgentStore)
- `SSSecuringQueue`, `RSDrainingOld` in the switch-status mappings.
- `ICQSndSecure` in internal command store/parse.
- New: `moveSndDeliveries db connId fromQ toQ` —
  `UPDATE snd_message_deliveries SET snd_queue_id = toQ WHERE conn_id = ? AND snd_queue_id = fromQ AND failed = 0`
  (used both for the flip, old → R', and for rollback, R' → old).
- New: `getFirstPendingSndMsgId db connId oldQ` —
  `SELECT MIN(m.internal_snd_id) FROM snd_message_deliveries d JOIN messages m ON m.conn_id = d.conn_id AND m.internal_id = d.internal_id WHERE d.conn_id = ? AND d.snd_queue_id = oldQ AND d.failed = 0`.
- New: `setRcvSwitchDrain db oldRq srvMsgId lastOldMsgId` and `getRcvSwitchDrain db oldRq`
  to persist and read the recipient's deferred-ACK id and drain target.

## Schema

Migration adds columns to `rcv_queues`, carried on the old (replaced) queue row, which
already holds `rcv_switch_status`:

```
ALTER TABLE rcv_queues ADD COLUMN switch_confirm_srv_msg_id BLOB;   -- R' confirmation id to ACK at the flip
ALTER TABLE rcv_queues ADD COLUMN switch_drain_to_msg_id BIGINT;    -- lastOldMsgId: drain old up to this
```

Both are NULL except while `rcv_switch_status = RSDrainingOld`. R''s `rcvId` (needed for the
ACK) is the connection's queue whose `dbReplaceQueueId` is the old queue. No new send-side
column: `ICQSndSecure` recomputes `lastOldMsgId` on each attempt and rolls the move back on
failure, so its only persisted state is `snd_switch_status = SSSecuringQueue`.

New config: `switchDrainTimeout` — the deadline after which A flips even though old has not
fully drained (see recipient Step 2).

## Sender B

### Synchronisation

Three tasks touch this connection's send state; two must be excluded during the flip,
the third is handled by transaction ordering:

1. **User enqueue** — `sendMessagesB_ c reqs connIds = withConnLocks c connIds "sendMessages" $ …`.
   The `getConn`, the id assignment (`updateSndIds`), and the delivery creation
   (`createSndMsgDelivery`) all run **inside** the per-connection lock (`connLocks c`, keyed by
   `connId`).
2. **Reception** — `processSMP … withConnLock c connId "processSMP"`.
3. **Delivery worker** — `runSmpQueueMsgDelivery`; for `A_MSG` it does **not** take the
   connection lock, and it only *removes* an old delivery on a successful send
   (`delMsgKeep → deleteSndMsgDelivery`), never creates one.

The primitive is the **per-connection lock**. `ICQSndSecure` holds it across the whole flip —
including the confirmation network send — via `tryWithLock` (`= tryCommand . withConnLock c connId`),
which is the same thing `ICQSecure` already does across the `secureQueue` network call today. Because
(1) and (2) take that lock, and (1) re-reads the connection under it, an enqueue cannot interleave
with the flip: it either fully commits **before** the flip takes the lock — so its message is pending
on old and is moved to R' — or runs **after** the flip releases it, re-reads the connection, sees R'
primary, and enqueues to R'. It can never write to old mid-flip.

Holding the lock across the send is specific to the **rotation** confirmation, because only it carries
`lastOldMsgId` and must exclude concurrent sends to old. It is sent **directly** from `ICQSndSecure`
(`sendConfirmation`), so ordinary connection-setup confirmations — `secureConfirmQueue` /
`storeConfirmation` and the delivery worker's `AM_CONN_INFO` path — are unchanged and are **not**
sent under the connection lock.

Only (3) runs outside the lock. It is excluded not by the lock but by ordering: `lastOldMsgId` is
read in the **same DB transaction** as the move, so SQLite serialises the worker's row removal
against it, and the move relabels rows rather than deleting them. So a message the worker sends
concurrently is either removed before the transaction (counted on old, A drains it) or after (it was
already relabelled to R', the worker's old-scoped delete matches nothing, A reads it on R'); at worst
it exists on both old and R' and is de-duplicated by `sndMsgId`. Never lost.

### Steps

`qAddMsg`
- After `addConnSndQueue` for the new send queue (created `New` by `newSndQueue … Nothing`):
  - fast: `connAgentVersion cData' >= rpcAddressSMPAgentVersion` (rotation queues are always
    messaging mode, so `senderCanSecure` is a redundant guard). Then:
    `enqueueCommand … (Just newSrv) (ICQSndSecure sndId)`; `setSndSwitchStatus SSSecuringQueue`;
    notify `SWITCH QDSnd SPStarted`.
  - else: current `QKEY` path, unchanged.
- The new send queue stays `New`, so `isActiveSndQ` is false and no user message is enqueued to
  it while securing — user messages go only to old.

`ICQSndSecure sId` (new internal command, retryable). Runs under `tryWithLock` — the connection
lock is held for the entire body, steps 1–5:
1. If R' is already primary and old is gone → the flip completed on a prior attempt; return.
   Otherwise find R' by `dbReplaceQueueId = Just _`, status `New`; `secureSndQueue` (SKEY) on R'
   (idempotent, retry-safe).
2. `atomically $ TM.delete (qAddress oldQ) (smpDeliveryWorkers c)` — the old worker starts no new
   iteration; any in-flight send is handled by step 3's transaction.
3. **One DB transaction:** `lastOldMsgId = getFirstPendingSndMsgId oldQ − 1` (or the connection's
   last snd id if nothing is pending); `moveSndDeliveries oldQ → R'` (`failed = 0` only; preserves
   `internal_id`, so the moved suffix keeps its order and `sndMsgId`). R' is not primary and its
   worker is not started, so nothing is sent on R' yet.
4. Send the confirmation to R' carrying `lastOldMsgId` (`sendConfirmation`; direct, not stored, no
   ratchet step, `e2eEncryption_ = Nothing`). Still under the lock, so no enqueue and no reception
   for this connection during the send (bounded by the send's network timeout — same as `ICQSecure`).
5. On success — one transaction: `setSndQueuePrimary R'`; `setSndQueueStatus R' Active`;
   `deleteConnSndQueue oldQ` (deliveries already moved; B never deletes old on the server). Then
   `submitPendingMsg c R'` (starts R''s worker, which sends the moved suffix — after the confirmation),
   notify `SWITCH QDSnd SPCompleted`.
   On failure — one transaction: `moveSndDeliveries R' → oldQ`; `submitPendingMsg c oldQ` (restart old
   worker). Temporary error → the command retries from step 1. Permanent error (AUTH) → also
   `deleteConnSndQueue R'`, leave old as sole primary, surface `A_QUEUE`.

Order of arrival on R': the confirmation (sent directly at step 4, before R''s worker exists), then
the moved suffix (> `lastOldMsgId`, in `internal_id` order once the worker starts at step 5), then new
user messages (higher ids, enqueued to R' after the lock is released).

## Recipient A — receive-side state machine

Preconditions: A is subscribed to old (primary) and R' (created at rotation start), at
`RSSendingQADD`, and tracks `lastExternalSndId` (existing per-connection counter).

`RSSendingQADD` → (confirmation on R') → `RSDrainingOld` → (drained) → complete.

Step 1 — confirmation on R' (`smpConfirmation`, new branch when `dbReplaceQueueId rq = Just replacedId`):
- Derive R''s secret from the header: `setRcvQueueConfirmedE2E rq (C.dh' e2ePubKey e2ePrivKey) …`.
- Read `lastOldMsgId` from the confirmation body.
- Persist the deferred ACK `(rcvId rq, srvMsgId)` and `lastOldMsgId`; set the old queue
  `rcvSwchStatus = RSDrainingOld`; keep R' status `New`; keep old primary.
- **Return without ACKing** (like `A_MSG` returns `ACKPending`). The server then holds R''s
  backlog; A processes no numbered R' message.
- If `lastExternalSndId >= lastOldMsgId` → go to Step 3 (nothing to drain).
- Idempotent on redelivery: if already `RSDrainingOld`, re-derive (no-op) and again return
  without ACKing; re-evaluate the flip condition. **Never ACK a redelivered confirmation
  until Step 3.**

Step 2 — drain old (best-effort):
- A keeps receiving old's messages through its existing subscription; each is processed and
  ACKed normally, advancing `lastExternalSndId`. (No polling; the server pushes.)
- Extend the ACK path (`ackQueueMessage`/`sendAck` and the `SMP.ACK _ -> … _ -> pure ()`
  response branch) to report whether the server has more messages for the queue.
- Perform the flip (Step 3) when any holds:
  - `lastExternalSndId >= lastOldMsgId`, or
  - an old-queue ACK response reports no more messages, or
  - the drain deadline (new config, e.g. a few seconds) passes, or
  - old is unreachable (subscription failed).
- Dead old server: nothing is pushed; the deadline fires; A flips, losing
  `lastExternalSndId+1 … lastOldMsgId` (inherent — on a dead server). When
  `lastExternalSndId >= lastOldMsgId` already, Step 1 flips immediately, with no delay even
  if old is unreachable.

Step 3 — flip (finalize, holds the connection lock):
- `setRcvQueuePrimary R'`; `setRcvQueueStatus R' Active`; remove old from the connection;
  clear `RSDrainingOld`; notify `SWITCH QDRcv SPCompleted`.
- Delete old on the server best-effort (bounded `deleteConnQueues`), not blocking.
- ACK the deferred confirmation: `enqueueCommand … (Just R'server) (ICAck (rcvId R') srvMsgId)`.
  The server then releases R''s backlog; A processes it and new messages (> `lastOldMsgId`),
  contiguous after `<= lastOldMsgId`.

## Abort / version

- `canAbortRcvSwitch` returns false for `RSSendingQADD` when `connAgentVersion >= v8`
  (A cannot see whether B answers with `QKEY` or a confirmation, but at v8 B always chooses
  fast, so A treats `RSSendingQADD` as committed). Pass `connAgentVersion` to the check.
- No send-side abort exists; B rolls back internally on permanent failure (sender step 6).

## Losses and duplication

- Old reachable: no loss — A drains `<= lastOldMsgId` from old, then reads `> lastOldMsgId` from R'.
- Old dead: `lastExternalSndId+1 … lastOldMsgId` stranded on the dead server are lost; inherent.
- Duplication (old worker race on B; a message present on both old server and R') is
  de-duplicated by `sndMsgId` (`checkMsgIntegrity` → `MsgDuplicate`).

## Tests

- new/new, old server stopped right after QADD, with unsent backlog: rotation completes;
  backlog delivered on R'; loss only of messages left unfetched on the stopped server.
- nothing to drain (`lastExternalSndId >= lastOldMsgId`): flip is immediate with old server down.
- draining: messages pending on old at flip are received before any R' content.
- new/old and old/new: fall back to the `QKEY`/`QUSE` path.
- crash mid-drain: reconnect redelivers the confirmation; A re-defers and resumes; completes.
