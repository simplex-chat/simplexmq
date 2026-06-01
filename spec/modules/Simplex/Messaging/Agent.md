# Simplex.Messaging.Agent

> Orchestration layer: duplex connection lifecycle, message processing dispatch, queue rotation, ratchet synchronization, and async command framework.

**Source**: [`Agent.hs`](../../../../../src/Simplex/Messaging/Agent.hs)

**See also**: [Agent/Client.md](./Agent/Client.md) — the infrastructure layer (AgentClient, worker framework, protocol client lifecycle, subscription state, operation suspension).

**Protocol spec**: [`agent-protocol.md`](../../../../protocol/agent-protocol.md) — duplex connection procedure, agent message syntax.

## Overview

This module is the top-level SimpleX agent, consumed by simplex-chat and other client applications. It passes specific worker bodies, task queries, and handler logic into the frameworks defined in [Agent/Client.hs](./Agent/Client.md), and implements the orchestration policies: duplex handshake, queue rotation, ratchet synchronization, message integrity validation.

### Agent startup — backgroundMode

`getSMPAgentClient_` accepts a `backgroundMode` flag that fundamentally changes agent capabilities:
- **Normal mode** (`backgroundMode = False`): starts four threads raced via `raceAny_` — `subscriber` (main event loop), `runNtfSupervisor` (notification management), `cleanupManager` (garbage collection), `logServersStats` (statistics). Also restores persisted router statistics. If any thread crashes, all are cancelled; statistics are saved in a `finally` block.
- **Background mode** (`backgroundMode = True`): starts only the `subscriber` thread. No cleanup, no notifications, no stats persistence. Used when the agent needs minimal receive-only operation.

Thread crashes are caught by the `run` wrapper: if the agent is still active (`acThread` is set), the exception is reported as `CRITICAL True` to `subQ`. If the agent is being disposed, crashes are silently ignored.

### Service + entity session mode prohibition

Service certificates and entity transport session mode (`TSMEntity`) are mutually exclusive. This is checked in four places: `getSMPAgentClient_`, `setNetworkConfig`, `createUser'`, `setUserService'`. If violated, throws `CMD PROHIBITED`. The constraint exists because service certificates associate multiple queues under one identity, which contradicts entity session mode's goal of preventing queue correlation.

## Split-phase connection creation

`prepareConnectionLink` and `createConnectionForLink` separate link preparation (key generation, link formatting — no network) from queue creation (single network call). This prevents the race where a link is published before the queue exists on the router.

**Sender ID derivation.** The sender ID is deterministic: `SMP.EntityId $ B.take 24 $ C.sha3_384 corrId` where `corrId` is a random nonce. `createConnectionForLink` validates `actualSndId == sndId` — if the router returns a different sender ID, the connection is rejected. See source comment: "the remaining 24 bytes are reserved, possibly for notifier ID in the new notifications protocol."

**PQ restriction.** `IKUsePQ` is prohibited for prepared links — throws `CMD PROHIBITED`. PQ keys are too large for the short link format.

## Subscriber loop — processSMPTransmissions

The subscriber thread reads batches from `msgQ` (filled by SMP protocol clients) and dispatches to `processSMPTransmissions`. Each batch is processed within `agentOperationBracket c AORcvNetwork waitUntilActive`, tying into the operation suspension cascade.

**Batch UP notification accumulation.** Successful subscription confirmations (`processSubOk`) append to a shared `upConnIds` TVar across the batch. A single `UP` event is emitted after all transmissions are processed, not per-transmission. Similarly, `serviceRQs` accumulates service-associated receive queues for batch processing via `processRcvServiceAssocs`.

**Double validation for subscription results.** `isPendingSub` checks two conditions atomically: the queue must be in the pending map AND the client session must still be active (`activeClientSession`). If either fails, the result is counted as ignored (statistics only). This handles the race where a subscription result arrives after reconnection.

**SUB result piggybacking MSG.** When a SUB result arrives as `Right msg@SMP.MSG {}`, the connection is marked UP (via `processSubOk`) AND the MSG is processed. The UP notification happens even if the MSG processing fails — the connection is up regardless.

**subQ overflow to pendingMsgs.** `processSMP` writes events to `subQ` (bounded TBQueue) but when full, events go into a `pendingMsgs` TVar. After processing, pending messages are drained in reverse order (LIFO). This prevents the message processing thread from blocking on a full queue, which would stall the entire SMP client.

**END/ENDS session validation.** Both check `activeClientSession` before removing subscriptions. If the session doesn't match (stale disconnect), the event is logged but ignored.

## Message processing — processSMP

`processSMP` dispatches on the SMP message type within a per-connection lock (`withConnLock`).

### Four e2e key states

The MSG handler discriminates on `(e2eDhSecret, e2ePubKey_)`:

- `(Nothing, Just key)` — **Handshake**: computes DH, decrypts with per-queue E2E. Dispatches to `smpConfirmation` or `smpInvitation`.
- `(Just dh, Nothing)` — **Established**: normal message flow. Dispatches to `AgentRatchetKey` or `AgentMsgEnvelope`.
- `(Just dh, Just _)` — **Repeated confirmation**: only AgentConfirmation is accepted (ACK for previous one failed), everything else is rejected.
- `(Nothing, Nothing)` — **Error**: no keys at all.

### ACK semantics

ACK is NOT automatic for `A_MSG` — the function returns `ACKPending` and the user must call `ackMessage`. ACK IS automatic for all control messages (HELLO, QADD, QKEY, QUSE, QTEST, EREADY, A_RCVD).

`handleNotifyAck` wraps the MSG processing: if any error occurs, it sends `ERR` to the client but still ACKs the SMP message. This prevents a processing error from causing infinite re-delivery.

### agentClientMsg — transactional message processing

Performs ratchet decryption, message parsing, and integrity checking inside a single `withStore` transaction with `lockConnForUpdate`. This serializes all message processing for a given connection, preventing concurrent ratchet state modifications. Returns the pre-decryption ratchet state (`rcPrev`) alongside the message — needed by `ereadyMsg` to decide whether to send EREADY.

### Additional queue status transitions on message receipt

When receiving an `AgentMsgEnvelope` on a non-Active queue, the queue is set to Active. For primary queues during rotation (`dbReplaceQueueId` is set), the new queue is set as primary and the old queue is scheduled for deletion via `ICQDelete`. This is how the receiving side completes queue rotation — any message on the new queue triggers cleanup of the old one.

### Duplicate message handling

Three paths for `A_DUPLICATE` errors:

1. **Stored and user-acked**: `getLastMsg` finds it with `userAck = True` → `ackDel`.
2. **Stored, A_MSG, not user-acked**: re-notify the user with `MSG` event and return `ACKPending`. The user may not have seen the original.
3. **Not stored or non-A_MSG**: `checkDuplicateHash` verifies the encrypted hash exists in the DB. If not, re-throws (real decryption failure, not duplicate).

For crypto errors (`A_CRYPTO`): if the encrypted hash already exists, suppressed (duplicate). If not, `notifySync` classifies via `cryptoErrToSyncState` (RSAllowed or RSRequired) and updates the connection's ratchet sync state.

### resetRatchetSync on successful decryption

When a double-ratchet message is successfully decrypted and the connection's ratchet sync state is not `RSOk` or `RSStarted`, the state is reset to `RSOk` and `RSYNC RSOk` is notified. Successful message delivery is the recovery signal for ratchet desynchronization.

### updateConnVersion — monotonic upgrade

Every received `AgentMsgEnvelope` triggers `updateConnVersion`. If the message's agent version is higher than the current agreed version and compatible, the agreed version is upgraded. Versions only increase. `safeVersionRange` handles the case where the sender's version exceeds the receiver's maximum — creates a range from `minVersion` to the sender's version.

## Duplex handshake

See [agent-protocol.md](../../../../protocol/agent-protocol.md) for the protocol description. Implementation-specific details:

### Initiating party (RcvConnection)

Receives AgentConfirmation with `e2eEncryption = Just sndParams`. Initializes the receive ratchet from the sender's E2E parameters. **v7+ (ratchetOnConfSMPAgentVersion)**: creates the ratchet immediately on confirmation processing, not later on `allowConnection`. See source comment on `processConf` — this supports decrypting messages that may arrive before `allowConnection` is called. The ratchet creation, E2E secret setup, and confirmation storage all happen in one `withStore` transaction.

### Accepting party (DuplexConnection)

Receives AgentConfirmation with `e2eEncryption = Nothing` and `AgentConnInfo` (not `AgentConnInfoReply`). The ratchet was already initialized during `joinConnection`. If `senderKey` is present, enqueues `ICDuplexSecure` (queue needs securing with SKEY). If absent (sender already secured via LKEY), sends `CON` immediately and sets the queue Active.

### HELLO exchange

HELLO is processed in `helloMsg`. The key dispatch is on `sndStatus`:
- `sndStatus == Active`: this side already sent HELLO, so receiving HELLO means both sides are connected → emit `CON`.
- Otherwise: this side hasn't sent HELLO yet → enqueue HELLO reply.

HELLO is not used in fast duplex connection (v9+ SMP with SKEY).

### startJoinInvitation — retry-safe ratchet creation

When retrying a join (existing `SndQueue`), `startJoinInvitation` tries to get the existing ratchet via `getSndRatchet` before creating a new one. If the ratchet exists, it reuses it. If not (error), it logs a non-blocking error via `nonBlockingWriteTBQueue` and creates a fresh ratchet. This prevents a retry from corrupting an already-established ratchet. The same pattern appears in `mkJoinInvitation` for contact URI joins.

### PQ support negotiation

PQ support is the AND of four conditions: the local client's PQ preference, the peer's agent version (>= `pqdrSMPAgentVersion`), the E2E encryption version (>= `pqRatchetE2EEncryptVersion`), and the connection's current PQ support. This negotiation happens at `joinConn` and `smpConfirmation` time via `versionPQSupport_` and `pqSupportAnd`.

## Queue rotation

Four agent messages implement queue rotation. See [agent-protocol.md](../../../../protocol/agent-protocol.md#rotating-messaging-queue) for the protocol. Implementation-specific details:

**QADD** (processed by sender in `qAddMsg`): Creates a new `SndQueue` with DH key exchange. Deletes any previous pending replacement (`delSqs` partitioned by `dbReplaceQId`). Responds with `QKEY`. The replacement chain means consecutive rotation requests are handled correctly — only the latest survives.

**QKEY** (processed by recipient in `qKeyMsg`): Validates queue is `New` or `Confirmed` and switch status is `RSSendingQADD`. Enqueues `ICQSecure` for async processing.

**QUSE** (processed by sender in `qUseMsg`): Marks new queue `Secured`. Sends `QTEST` **only to the new queue**.

**QTEST** (no handler in processSMP): Any message on the new queue triggers old queue deletion via `dbReplaceQueueId` logic. QTEST exists only to ensure at least one message traverses the new queue.

**Sender-side completion in delivery handler.** When `AM_QTEST_` is successfully sent in `runSmpQueueMsgDelivery`, the old send queue is removed from the connection: pending messages are deleted, the queue record is removed, and the old queue's delivery worker is deleted from `smpDeliveryWorkers` (stopping its thread). This happens inside `withConnLockNotify` to prevent deadlock with the subscriber.

**ICQDelete error tolerance.** In `runCommandProcessing`, if deleting the old receive queue fails with a permanent error (e.g., queue already gone on router), `finalizeSwitch` still runs — the local switch completes. Only temporary errors prevent completion.

**Ratchet sync guard**: All four message handlers check `ratchetSyncSendProhibited` before proceeding.

## Ratchet synchronization — newRatchetKey

When an `AgentRatchetKey` message is received, `newRatchetKey` handles ratchet re-establishment.

### Hash-ordering for initialization role

Both parties generate key pairs and exchange them. The party whose `rkHash(k1, k2)` is **lower** (lexicographic comparison) initializes the **receiving** ratchet; the other initializes **sending** and sends EREADY. This breaks the symmetry when both parties simultaneously request ratchet sync.

### State machine

- `RSOk`, `RSAllowed`, `RSRequired` → **receiving client**: generate new keys, send `AgentRatchetKey` reply, then proceed with hash-ordering.
- `RSStarted` → **initiating client**: use keys already stored (from `synchronizeRatchet'`), proceed with hash-ordering.
- `RSAgreed` → **error**: sets state to `RSRequired`, throws `RATCHET_SYNC`. Handles the edge case where both parties initiate simultaneously and one has completed.

### Deduplication

`checkRatchetKeyHashExists` prevents processing the same ratchet key twice. The hash is stored atomically before processing begins.

### EREADY

Sent when the ratchet was initialized as receiving (`rcSnd` is `Nothing` in the pre-decryption ratchet state). Carries `lastExternalSndId` so the other party knows which messages were sent with the old ratchet.

## Message integrity — checkMsgIntegrity

Sequential external sender ID + previous message hash chain. Five outcomes: `MsgOk` (sequential + hashes match), `MsgBadId` (ID from the past), `MsgDuplicate` (same ID), `MsgSkipped` (gap in sequence), `MsgBadHash` (sequential but hashes differ).

The integrity result is delivered to the client application via `MsgMeta`. The agent does not reject messages with integrity failures — it reports them and continues processing. The client decides the policy.

## Async command processing — runCommandProcessing

Uses the worker framework from [Agent/Client.hs](./Agent/Client.md#worker-framework). Keyed by `(connId, server)` — each connection/server combination gets its own command worker. Uses `AOSndNetwork` for operation suspension.

### Internal commands

- **ICAllowSecure**: User-initiated handshake completion (from `allowConnection`). On DuplexConnection (SKEY retry), if the error is temporary and the send queue's server differs from the command's server, the command is **moved** to the correct server queue via `updateCommandServer` + `getAsyncCmdWorker`. Returns `CCMoved` instead of `CCCompleted`.
- **ICDuplexSecure**: Automatic handshake completion (from receiving AgentConnInfo with senderKey). Secures queue and sends HELLO.
- **ICQSecure / ICQDelete**: Queue rotation — secure the new queue (KEY) and delete the old queue.
- **ICAck / ICAckDel**: Send ACK to the router, optionally deleting the internal message record.
- **ICDeleteConn**: No longer used, but may exist in old databases — cleaned up by deleting the command record.
- **ICDeleteRcvQueue**: Queue cleanup during rotation.

### Retry semantics

`tryMoveableCommand` wraps execution with `withRetryInterval`: waits for `waitWhileSuspended` and `waitForUserNetwork`, then executes. Temporary/host errors trigger retry via `retrySndOp`. On success, the command is deleted. On permanent error, the error is notified and the command is deleted. `retrySndOp` separates `endAgentOperation`/`beginAgentOperation` into separate `atomically` blocks — see source comment: if `beginAgentOperation` blocks, `SUSPENDED` won't be sent.

### withConnLockNotify — deadlock prevention

Returns `Maybe ATransmission` and writes to `subQ` **after** releasing the lock. This prevents deadlock: if the lock holder writes to a full `subQ` while the subscriber thread needs the lock to process a message, both block indefinitely.

## Message delivery — runSmpQueueMsgDelivery

Per-queue delivery loop. Each `SndQueue` has its own worker keyed by queue address in `smpDeliveryWorkers`, paired with a `TMVar ()` retry lock (via `getAgentWorker'`).

### Deferred encryption

Message bodies are NOT encrypted at enqueue time. `enqueueMessageB` advances the ratchet header (`agentRatchetEncryptHeader`) and validates padding (`rcCheckCanPad`), but stores only the body reference (`sndMsgBodyId`) and encryption key (`encryptKey`, `paddedLen`). The actual message body encoding (`encodeAgentMsgStr`) and encryption (`rcEncryptMsg`) happen at delivery time. This allows the same body to be shared across multiple send queues via `sndMsgBodyId` — each delivery encrypts independently with its connection's ratchet.

For confirmation and ratchet key messages (AM_CONN_INFO, AM_CONN_INFO_REPLY, AM_RATCHET_INFO), the body is pre-encrypted and stored in `msgBody` directly — no deferred encryption.

### Per-message-type error handling

**QUOTA**: Checks `internalTs` against `quotaExceededTimeout`. If the message is older than the timeout, expires it and all subsequent expired messages in the queue (via `getExpiredSndMessages` → bulk `MERRS` notification). If not expired, sends `MWARN` and retries with `RISlow`. For confirmation messages (AM_CONN_INFO/AM_CONN_INFO_REPLY), QUOTA is treated as `NOT_AVAILABLE`.

**AUTH**: Per message type:
- `AM_CONN_INFO` / `AM_CONN_INFO_REPLY` / `AM_RATCHET_INFO`: connection error `NOT_AVAILABLE`
- `AM_HELLO_` with receive queue (initiating party): `NOT_AVAILABLE`. Without receive queue (joining party): `NOT_ACCEPTED`.
- `AM_A_MSG_` / `AM_A_RCVD_` / `AM_QCONT_` / `AM_EREADY_`: delete message and notify `MERR`.
- Queue rotation messages (`AM_QADD_` through `AM_QTEST_`): queue error with descriptive string.

**Timeout/network errors**: message-type-aware timeout — `AM_HELLO_` uses `helloTimeout`, all others use `messageTimeout`. If expired, uses `notifyDelMsgs` which expires the current message AND fetches all expired messages for the queue in bulk. If `serverHostError`, sends `MWARN` before retrying. Non-host temporary errors retry silently.

### Delivery success handling

On successful send, per message type:
- `AM_CONN_INFO` with `senderCanSecure` (fast handshake): sends `CON` + sets status `Active`.
- `AM_CONN_INFO` without `senderCanSecure`: sets status `Confirmed` only.
- `AM_CONN_INFO_REPLY`: sets status `Confirmed`.
- `AM_HELLO_`: sets status `Active`. If receive queue exists AND its status is `Active`, sends `CON` (accepting party in v2).
- `AM_A_MSG_`: sends `SENT msgId proxySrv_` to notify the client.
- `AM_QKEY_`: re-reads connection and sends `SWITCH QDSnd SPConfirmed`.
- `AM_QTEST_`: see "Sender-side completion" under Queue rotation above.
- All other types: no notification.

After success, the delivery record is deleted. For `AM_A_MSG_`, `keepForReceipt = True` — the record is kept until a receipt is received.

### withRetryLock2 — external retry signaling

The delivery loop uses `withRetryLock2` which combines the standard retry interval with `qLock` (the `TMVar ()` paired with the worker). When `A_QCONT` is received, the handler puts `()` into the retry lock, causing the retry to fire immediately instead of waiting for the backoff interval. See `continueSending` in `processSMP`.

### submitPendingMsg — operation counting

`submitPendingMsg` increments `opsInProgress` on `msgDeliveryOp` BEFORE spawning the delivery worker. This means the operation is counted even before the worker starts, ensuring the suspension cascade waits for all enqueued deliveries.

## Batch message sending — sendMessagesB_

### MsgReq grouping contract

Messages to the same connection must be contiguous in the traversable, with only the first having a non-empty `connId`. Subsequent messages for the same connection must have empty `connId`. This is validated by `addConnId` which rejects duplicate `connId` values and empty first `connId`. The `getConn_` function uses a `TVar prev` to cache the last connection lookup, avoiding redundant database reads.

### Connection locking

`withConnLocks` takes locks for ALL connections in the batch before processing. This prevents concurrent sends to the same connection from interleaving ratchet state updates.

### PQ support monotonic upgrade

When `pqEnc == PQEncOn` but the connection has `pqSupport == PQSupportOff`, PQ support is upgraded via `setConnPQSupport`. PQ support can only be enabled, never disabled. The upgrade IDs are accumulated via `mapAccumL` and applied in a single batch database write.

### VRValue/VRRef — database body deduplication

VRValue/VRRef deduplication operates at the **database body storage** level, not encryption. `enqueueMessageB` tracks an `IntMap (Maybe Int64, AMessage)` mapping integer indices to database body IDs (`sndMsgBodyId`):

- `VRValue (Just i) body`: stores the body in `snd_message_bodies`, records the `sndMsgBodyId`, and associates it with index `i` for future reference.
- `VRRef i`: looks up index `i` to get the previously stored `sndMsgBodyId`, and creates a new `snd_messages` record linked to the same body.

Encryption is NOT deduplicated — each connection's ratchet header is independently advanced at enqueue time, and each delivery encrypts the body independently. The optimization is purely about avoiding redundant database storage of identical message bodies (common for group messages).

### Error propagation constraint

When a connection type is wrong (e.g., SndConnection, NewConnection), the error is returned per-message but the batch continues. See source comment: "we can't fail here, as it may prevent delivery of subsequent messages that reference the body of the failed message." If a VRValue message fails, subsequent VRRef messages that reference it would break.

## Subscription management

### subscribeConnections_

Partitions connections by type. SndConnection with `Confirmed` status returns success (it's not subscribed, just waiting). SndConnection with `Active` status returns `CONN SIMPLEX` (can't subscribe a send-only connection). After subscribing queues, resumes delivery workers for connections with pending deliveries (via `getConnectionsForDelivery`).

**Multi-queue result combining.** For connections with multiple receive queues, results are combined using a priority system: Active+Success (1) > Active+Error (2) > non-Active+Success (3) > non-Active+Error (4). The highest-priority (lowest number) result is used. This ensures that if at least one Active queue subscribes successfully, the connection reports success.

### subscribeAllConnections'

**Active user priority.** If `activeUserId_` is provided, that user's subscriptions are processed first (`sortOn`).

**Service subscription with fallback.** Service subscriptions are attempted first. If a service subscription fails with `SSErrorServiceId` or zero subscribed queues, the queues are unassociated from the service and subscribed individually. If the error is a client-level error (not a service-specific error), the same fallback applies.

**Pending throttle.** `maxPending` limits concurrent pending subscriptions. The counter is incremented inside the database transaction (before leaving `withStore'`) and decremented in a `finally` block. When the count exceeds the limit, `subscribeUserServer` blocks in STM via `retry`.

### resubscribeConnections'

Filters out connections that already have active subscriptions (via `hasActiveSubscription`). For store errors, returns `True` for `isActiveConn` — this causes the error to be processed by `subscribeConnections_` which will report it.

## Notification token lifecycle

`registerNtfToken'` is a complex state machine. Key non-obvious behavior: on `NTF AUTH` error during token operations, the token is removed and re-registered from scratch (see `withToken` catch of `NTF AUTH`). Device token changes trigger `replaceToken`, which attempts an in-place replacement; if that fails with a permanent error, the token is removed and recreated.

## Cleanup manager

Runs periodically with a `cleanupStepInterval` delay BETWEEN each cleanup operation (not just between cycles). This prevents cleanup from monopolizing database access.

Additional cleanup not previously mentioned:
- **Expired receive message hashes**: `deleteRcvMsgHashesExpired`
- **Expired send messages**: `deleteSndMsgsExpired`
- **Expired ratchet key hashes**: `deleteRatchetKeyHashesExpired`
- **Expired notification tokens**: `deleteExpiredNtfTokensToDelete`
- **Expired send chunk replicas**: `deleteDeletedSndChunkReplicasExpired`

## Agent suspension

`suspendAgent` has two modes:
- **Immediate** (`maxDelay = 0`): sets `ASSuspended` and suspends all operations immediately.
- **Gradual** (`maxDelay > 0`): sets `ASSuspending` and triggers the cascade (NtfNetwork independent; RcvNetwork → MsgDelivery → SndNetwork → Database). A timeout thread fires after `maxDelay` and forces suspension of sending and database if still suspending.

`foregroundAgent` resumes in reverse order: database → sending → delivery → receiving → notifications.

## connectReplyQueues — background duplex upgrade

Used during async command processing to complete the duplex handshake. Handles two cases:
- **Fresh connection** (`sq_ = Nothing`): upgrades `RcvConnection` to `DuplexConnection`.
- **SKEY retry** (`sq_ = Just sq`): connection is already duplex. See source comment: "in case of SKEY retry the connection is already duplex."

## secureConfirmQueue vs secureConfirmQueueAsync

- **secureConfirmQueue** (synchronous): secures queue and sends confirmation directly via network. Used in `joinConnection`.
- **secureConfirmQueueAsync** (asynchronous): secures queue, stores confirmation, submits to delivery worker. Used in `allowConnection` (via `ICAllowSecure`).

Both call `agentSecureSndQueue`, which returns `initiatorRatchetOnConf` — whether the initiator's ratchet should be created on confirmation (v7+ behavior). When the queue was already secured (retry), returns the same flag without re-securing.

## smpConfirmation — version compatibility

The confirmation handler accepts messages where the agent version or client version is either within the configured range OR at-or-below the already-agreed version. See source comment. This means a downgraded client can still complete in-progress handshakes.

## smpInvitation — contact address handling

Invitation messages received on a contact address are passed through even if version-incompatible. See source comment. The client application sees `REQ` with `PQSupportOff` when incompatible.

## ackMessage' — receipt sending

After ACKing a message, if the user provides receipt info (`rcptInfo_`), a receipt message (`A_RCVD`) is enqueued. Receipts are only allowed for `AM_A_MSG_` type. If the user ACKs without receipt info and the message already has a receipt with `MROk` status, the corresponding sent message is deleted from the database — it's confirmed delivered.

## acceptContactAsync' — rollback on failure

See source comment. Unlike the synchronous `acceptContact'` which takes a lock first, `acceptContactAsync'` marks the invitation as accepted before joining. On failure, `unacceptInvitation` rolls back. The comment notes this could be improved with an invitation lock map.

## prepareConnectionToJoin — race prevention

See source comment. Creates a connection record without queues, returning a `ConnId`. The caller saves this ID before the peer can send a confirmation. Without this, the sequence "joinConnection → peer sends confirmation → caller saves ConnId" could result in the confirmation arriving before the caller has the ID.
