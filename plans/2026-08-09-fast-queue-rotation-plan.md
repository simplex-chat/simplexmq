# Fast queue rotation — implementation plan

Branch: ep/drop-agent-versions. RFC: ../rfcs/2026-08-09-fast-queue-rotation.md.

No new agent message. Each side detects the rotation from the replacement
reference (`dbReplaceQueueId`) on its own new queue.

## New definitions

Agent/Protocol.hs
- Gate on the existing `rpcAddressSMPAgentVersion` (v8). Renaming it to cover both features can be considered separately; no alias.
- `SndSwitchStatus` constructor `SSSecuringQueue` with StrEncoding/JSON/field instances.
- `InternalCommand` constructor `ICQSndSecure SMP.SenderId` with tag.

Agent/Store(.AgentStore)
- `SSSecuringQueue` in `setSndSwitchStatus` mapping.
- `ICQSndSecure` in internal command store/parse.

Agent.hs
- `storeRotationConfirmation` — variant of `storeConfirmation` that stores
  `AgentConfirmation {e2eEncryption_ = Nothing, encConnInfo = ""}` with msgType
  `AM_CONN_INFO`, `sndMsgPrepData_ = Nothing`, no ratchet step.

## Sender B — Agent.hs

`qAddMsg` (new-queue-sender branch)
- After `addConnSndQueue` for the new snd queue, choose path:
  - fast: `connAgentVersion cData' >= rpcAddressSMPAgentVersion && senderCanSecure (queueMode of new queue)`.
  - else: current `QKEY` path (unchanged).
- Fast: `enqueueCommand c "" connId (Just newSrv) $ AInternalCommand $ ICQSndSecure sndId`;
  `setSndSwitchStatus db sq $ Just SSSecuringQueue`; notify `SWITCH QDSnd SPStarted`.

`ICQSndSecure sId` (new, in runCommandProcessing, model on `ICQSecure`)
- Find new snd queue `sq'` in sqs with `dbReplaceQueueId = Just _`, status `New`.
- `agentSecureSndQueue` (SKEY) on `sq'`; set `Secured`.
- `storeRotationConfirmation c cData sq'`; `submitPendingMsg c sq'`.

runSmpQueueMsgDelivery — success `AM_CONN_INFO`
- Branch on `sq` replacement reference:
  - `dbReplaceQueueId = Just _`: rotation. Mirror `AM_QTEST_` — `checkSQSwchStatus sq' SSSecuringQueue`; remove old snd queue; `setSndQueuePrimary`; `deleteConnSndQueue`; notify `SWITCH QDSnd SPCompleted`.
  - otherwise: current join completion (`CON`/`setStatus`).

runSmpQueueMsgDelivery — AUTH `AM_CONN_INFO`
- Same branch: rotation → `qError msgId "rotation confirmation: AUTH"`; otherwise current `connError NOT_AVAILABLE`.

## Recipient A — Agent.hs

`smpConfirmation`, `New` case, before the RcvConnection/DuplexConnection split
- If `dbReplaceQueueId rq = Just replacedId` (rq is R'):
  - `setRcvQueueConfirmedE2E db rq (C.dh' e2ePubKey e2ePrivKey) (min v phVer)` (empty encConnInfo not decrypted).
  - `setRcvQueuePrimary`, `setRcvQueueStatus rq Active`.
  - `setRcvSwitchStatus db replaced $ Just RSReceivedMessage`.
  - finalize: update connection, notify `SWITCH QDRcv SPCompleted`, delete old queue via `deleteConnQueues` (bounded best-effort), not `ICQDelete`.
  - no `CON`/`INFO`.

## Switch state

- A: `RSSendingQADD` → (confirmation on R') → `RSReceivedMessage` → done. `RSSendingQUSE` skipped for fast path.
- B: `SSSecuringQueue` → (confirmation delivered) → done.

## Unchanged

QADD wire format, slow QKEY/QUSE/QTEST path, abort (`canAbortRcvSwitch` still allows through `RSSendingQADD`).

## Tests

- new/new: rotation completes with current server stopped after QADD.
- new/old and old/new: fall back to QKEY path, complete.
- redundancy: two current queues, rotate one, secret established on R' only.
