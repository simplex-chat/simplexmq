# Simplex.Messaging.Agent

> Orchestration layer: duplex connection lifecycle, message processing dispatch, queue rotation, ratchet synchronization, and async command framework.

**Source**: [`Agent.hs`](../../../../../src/Simplex/Messaging/Agent.hs)

**See also**: [Agent/Client.md](./Agent/Client.md) — the infrastructure layer (AgentClient, worker framework, protocol client lifecycle, subscription state, operation suspension).

**Protocol spec**: [`agent-protocol.md`](../../../../protocol/agent-protocol.md) — duplex connection procedure, agent message syntax.

## Overview

This module is the top-level messaging agent, consumed by simplex-chat and other client applications. It passes specific worker bodies, task queries, and handler logic into the frameworks defined in [Agent/Client.hs](./Agent/Client.md), and implements the orchestration policies: duplex handshake, queue rotation, ratchet synchronization, message integrity validation.

The agent starts four threads (in `getSMPAgentClient_`): `subscriber` (main event loop), `runNtfSupervisor` (notification token management), `cleanupManager` (periodic garbage collection), and `logServersStats` (statistics reporting). These threads are raced via `raceAny_` — if any exits, all are cancelled.

## Split-phase connection creation

`prepareConnectionLink` and `createConnectionForLink` separate link preparation (key generation, link formatting — no network) from queue creation (single network call). This prevents the race where a link is published before the queue exists on the router. The link can be shared out-of-band after `prepareConnectionLink`, and `createConnectionForLink` is called only when the user is ready to accept connections.

## Subscriber loop — processSMPTransmissions

The subscriber thread reads batches from `msgQ` (filled by SMP protocol clients) and dispatches to `processSMPTransmissions`. Key non-obvious behaviors:

**Batch UP notification accumulation.** Successful subscription confirmations (`processSubOk`) append to a shared `upConnIds` TVar across the batch. A single `UP` event is emitted after all transmissions in the batch are processed, not per-transmission. Similarly, `serviceRQs` accumulates service-associated receive queues for batch processing via `processRcvServiceAssocs`.

**Double validation for subscription results.** `isPendingSub` checks two conditions atomically: the queue must be in the pending map AND the client session must still be active. If either fails, the subscription result is counted as ignored (statistics only). This handles the race where a subscription response arrives after the client disconnected and a new client connected.

**subQ overflow to pendingMsgs.** `processSMP` writes events to `subQ` (bounded TBQueue) but when it's full, events go into a `pendingMsgs` TVar instead. After processing completes, pending messages are drained in reverse order. This prevents the message processing thread from blocking on a full queue, which would stall the entire SMP client.

**END/ENDS session validation.** Both `END` (single queue) and `ENDS` (service) check `activeClientSession` before removing subscriptions. If the session doesn't match (stale disconnect), the event is logged but ignored. This prevents a delayed END from a disconnected client from removing subscriptions that a new client established.

## Message processing — processSMP

`processSMP` dispatches on the SMP message type within a per-connection lock (`withConnLock`).

### Four e2e key states

The MSG handler discriminates on `(e2eDhSecret, e2ePubKey_)` — the per-queue shared secret and the incoming public key:

- `(Nothing, Just key)` — **Handshake phase**: no shared secret yet, public key present. Computes DH, decrypts with per-queue E2E. Dispatches to `smpConfirmation` (if AgentConfirmation) or `smpInvitation` (if AgentInvitation).
- `(Just dh, Nothing)` — **Established phase**: shared secret exists, no new key. This is normal message flow. Dispatches to `AgentRatchetKey` (ratchet renegotiation) or `AgentMsgEnvelope` (double-ratchet encrypted message).
- `(Just dh, Just _)` — **Repeated confirmation**: both present. Only AgentConfirmation is accepted (this is a retry because ACK failed), everything else is rejected.
- `(Nothing, Nothing)` — **Error**: no keys at all.

### ACK semantics

ACK is NOT automatic for `A_MSG` — the function returns `ACKPending` and the user must call `ackMessage`. ACK IS automatic for all control messages (HELLO, QADD, QKEY, QUSE, QTEST, EREADY, A_RCVD). This is because `A_MSG` delivery to the user application must be confirmed before the message is removed from the router.

`handleNotifyAck` wraps each MSG processing branch: if any error occurs, it sends `ERR` to the client but still ACKs the SMP message. This prevents a processing error from causing infinite re-delivery of the same message.

### agentClientMsg — transactional message processing

The inner function `agentClientMsg` performs ratchet decryption, message parsing, and integrity checking inside a single `withStore` transaction with `lockConnForUpdate`. This serializes all message processing for a given connection, preventing concurrent ratchet state modifications. The function returns the pre-decryption ratchet state (`rcPrev`) alongside the message — this is needed by `ereadyMsg` to decide whether to send EREADY.

### Duplicate message handling

Three paths for `A_DUPLICATE` errors:

1. **Stored and user-acked**: `getLastMsg` finds it with `userAck = True` → `ackDel` (delete from router).
2. **Stored, A_MSG, not user-acked**: re-notify the user with `MSG` event and return `ACKPending`. The user may not have seen the original notification.
3. **Not stored or non-A_MSG**: verify via `checkDuplicateHash` that the encrypted hash exists in the DB. If it doesn't, the error is re-thrown (it's a real decryption failure, not a duplicate).

For crypto errors (`A_CRYPTO`): the encrypted message hash is checked for existence. If the hash already exists, the error is silently suppressed (it's a duplicate that failed decryption differently). If not, `notifySync` classifies the error via `cryptoErrToSyncState` and may trigger ratchet resynchronization.

### resetRatchetSync on successful decryption

When a double-ratchet message is successfully decrypted and the connection's ratchet sync state is not `RSOk` or `RSStarted`, the state is reset to `RSOk` and `RSYNC RSOk` is notified. This means successful message delivery is the recovery signal for ratchet desynchronization.

### updateConnVersion on every message

Every received `AgentMsgEnvelope` triggers `updateConnVersion`, which upgrades the connection's agreed agent version if the message's version is higher and compatible. This is a monotonic upgrade — versions only increase. The `safeVersionRange` construction handles the case where the sender's version is higher than the receiver's maximum — it creates a range from `minVersion` to the sender's version.

## Duplex handshake

See [agent-protocol.md](../../../../protocol/agent-protocol.md) for the protocol description. Implementation-specific details:

### Initiating party (RcvConnection)

Receives AgentConfirmation with `e2eEncryption = Just sndParams`. Initializes the receive ratchet from the sender's E2E parameters. **v7+ (ratchetOnConfSMPAgentVersion)**: creates the ratchet immediately on confirmation processing, not later on `allowConnection`. See source comment on `processConf` — this supports decrypting messages that may arrive before `allowConnection` is called. The ratchet creation, E2E secret setup, and confirmation storage all happen in one `withStore` transaction.

### Accepting party (DuplexConnection)

Receives AgentConfirmation with `e2eEncryption = Nothing` and `AgentConnInfo` (not `AgentConnInfoReply`). The ratchet was already initialized during `joinConnection`. If `senderKey` is present, enqueues `ICDuplexSecure` (the queue needs to be secured with SKEY). If absent (sender already secured via LKEY), sends `CON` immediately.

### HELLO exchange

HELLO is processed in `helloMsg`. The key dispatch is on `sndStatus`:
- `sndStatus == Active`: this side already sent HELLO, so receiving HELLO means both sides are connected → emit `CON`.
- Otherwise: this side hasn't sent HELLO yet → enqueue HELLO reply via `enqueueDuplexHello`.

HELLO is not used at all in fast duplex connection (v9+ SMP with SKEY — the sender secures the queue directly, skipping the HELLO exchange).

## Queue rotation

Four agent messages implement queue rotation. See [agent-protocol.md](../../../../protocol/agent-protocol.md#rotating-messaging-queue) for the protocol. Implementation-specific details:

**QADD** (processed by sender in `qAddMsg`): Creates a new `SndQueue` with DH key exchange. Before creating the new queue, deletes any previous pending replacement (`delSqs` partitioned by `dbReplaceQId`). Responds with `QKEY`. The replacement chain means multiple consecutive rotation requests are handled correctly — only the latest replacement survives.

**QKEY** (processed by recipient in `qKeyMsg`): Validates that the queue is `New` or `Confirmed` and the switch status is `RSSendingQADD`. Enqueues `ICQSecure` to secure the queue asynchronously — the actual KEY command is sent by `runCommandProcessing`.

**QUSE** (processed by sender in `qUseMsg`): Marks the new queue as `Secured`. Sends `QTEST` **only to the new queue**, not the old one. The old queue is deleted after QTEST is successfully delivered (handled in `runSmpQueueMsgDelivery`).

**QTEST** (no handler): Comment explains — any message received on the new queue triggers deletion of the old queue via the `dbReplaceQueueId` logic in `processSMP`'s AgentMsgEnvelope branch. QTEST exists only to ensure at least one message traverses the new queue.

**Ratchet sync guard**: All four handlers check `ratchetSyncSendProhibited` before proceeding. Queue rotation is blocked during ratchet desynchronization.

## Ratchet synchronization — newRatchetKey

When an `AgentRatchetKey` message is received, `newRatchetKey` handles ratchet re-establishment.

### Hash-ordering for initialization role

Both parties generate key pairs and exchange them. The party whose `rkHash(k1, k2)` is **lower** (lexicographic comparison) initializes as the **receiving** ratchet; the other initializes as **sending** and sends EREADY. This deterministic ordering breaks the symmetry when both parties simultaneously request ratchet sync.

### State machine

The current `ratchetSyncState` determines behavior:
- `RSOk`, `RSAllowed`, `RSRequired` → **receiving client**: generate new keys, send `AgentRatchetKey` reply, then proceed with hash-ordering.
- `RSStarted` → **initiating client**: use the keys already stored (from `synchronizeRatchet'`), proceed with hash-ordering.
- `RSAgreed` → **error**: ratchet was already re-established but another key arrived. Sets state to `RSRequired` and throws `RATCHET_SYNC`. This handles the edge case where both parties initiate simultaneously and one has already completed.

### Deduplication

`checkRatchetKeyHashExists` prevents processing the same ratchet key message twice. The hash is stored before processing, so a duplicate delivery is detected and short-circuited via `ratchetExists`.

### EREADY

Sent when the ratchet was initialized as receiving (`rcSnd` is `Nothing` in the pre-decryption ratchet state). Carries `lastExternalSndId` so the other party knows which messages were sent with the old ratchet. Processed by `ereadyMsg`, which checks `rcPrev` (the ratchet state before decrypting the current message) for the same condition — if the pre-decryption ratchet had no send chain, it sends EREADY.

## Message integrity — checkMsgIntegrity

Sequential external sender ID + previous message hash chain. Five outcomes:
- **MsgOk**: `extSndId == prevExtSndId + 1` AND hashes match.
- **MsgBadId**: `extSndId < prevExtSndId` — message from the past.
- **MsgDuplicate**: `extSndId == prevExtSndId` — same ID as last message.
- **MsgSkipped**: `extSndId > prevExtSndId + 1` — gap in sequence, reports range of skipped IDs.
- **MsgBadHash**: IDs are sequential but hashes don't match — message was modified or a different message was inserted.

The integrity result is stored in `MsgMeta` and delivered to the client application. The agent does not reject messages with integrity failures — it reports them and continues processing. This is intentional: the client application decides the policy.

## Async command processing — runCommandProcessing

Uses the worker framework from [Agent/Client.hs](./Agent/Client.md#worker-framework). The worker body calls `withWork` with `getPendingServerCommand` as the task source.

### Internal commands

The command processor dispatches internal commands that are enqueued by message handlers and other agent operations:

- **ICAllowSecure / ICDuplexSecure**: Complete the duplex handshake by securing the queue and sending confirmation. `ICAllowSecure` is the user-initiated path (from `allowConnection`), `ICDuplexSecure` is the automatic path (from receiving AgentConnInfo with senderKey).
- **ICQSecure / ICQDelete**: Queue rotation — secure the new queue (KEY command) and delete the old queue.
- **ICAck / ICAckDel**: Send ACK to the SMP router, optionally deleting the internal message record.
- **ICDeleteConn / ICDeleteRcvQueue**: Connection and queue cleanup.

### Retry semantics

`runCommandProcessing` has two retry intervals: zero (immediate retry via `0`) for commands that fail with temporary errors, and `asyncCmdRetryInterval` for stuck commands. `tryMoveableCommand` attempts to skip a stuck command by marking it with a future `connId` so `getPendingServerCommand` returns the next one instead.

### withConnLockNotify

Wraps command execution with `withConnLock` plus automatic error notification to `subQ`. This ensures that even if a command fails, the client application is notified.

## Message delivery — runSmpQueueMsgDelivery

Per-queue delivery loop using the worker framework. Each `SndQueue` has its own delivery worker (keyed by queue address in `smpDeliveryWorkers`).

### Per-message-type error handling

Error handling differs by message type and SMP error:

**QUOTA**: The queue has exceeded its message quota. Sets `quotaExceededTs` and starts an expiry timer if `messageExpireInterval` is configured. Does NOT retry — the sender must wait for the recipient to drain messages (signaled by `A_QCONT`).

**AUTH**: Different response per message type:
- `A_MSG_` (user message): sends `SENT` with `SndMsgRcvQueued` status to the client. The message was accepted by the router but auth failed on the receive side — likely the queue was replaced during rotation.
- Other types: sends `MERR` error to the client.
- In both cases, if `messageExpireInterval` is configured, expired messages are deleted.

**Timeout/network errors**: retried with the worker framework's built-in retry. The `retryLock` TMVar (paired with each delivery worker — see `getAgentWorker'` in [Agent/Client.md](./Agent/Client.md#getagentworker--lifecycle-management)) provides external retry signaling from `A_QCONT`.

## Batch message sending — sendMessagesB_

`sendMessagesB_` sends messages to multiple connections. When multiple messages have the same body (common for group messages), the body is encrypted once and referenced via `VRRef` for subsequent connections. `vrCopyMap` tracks `ByteString → (VRValue encrypted)` mappings. This is a performance optimization — ratchet encryption is expensive, and group messages go to many connections with identical plaintext.

The function partitions connections by send queue and builds per-queue delivery batches. Each connection's message is encrypted with its own ratchet but the plaintext body lookup avoids redundant work.

## Subscription management

### subscribeAllConnections'

Batch subscription with throttling: `maxPending` limits how many pending subscriptions exist simultaneously. When the pending count exceeds the limit, the function waits before enqueuing more. This prevents memory exhaustion on reconnection when thousands of connections need resubscription.

Service subscriptions are attempted first (`subscribeClientServices'`). If a service subscription succeeds, its associated queues don't need individual SUB commands — they're covered by the service subscription. Queues not associated with any service are subscribed individually.

### resubscribeConnection'

Individual connection resubscription. Checks connection status and queue status before subscribing — deleted or suspended connections are skipped. Used for targeted resubscription after specific operations (e.g., after `allowConnection`).

## Notification token lifecycle

`registerNtfToken'` → `verifyNtfToken'` → `checkNtfToken'` → `deleteNtfToken'` manage push notification token registration with the NTF server. Token verification uses a challenge-response flow where the NTF server sends a verification code through the push notification channel, and the client confirms receipt.

## Cleanup manager

Runs periodically (configurable interval, typically 1 minute). Operations:
- **Delete marked connections**: connections in "deleted" or "deleted-waiting-delivery" states
- **Delete expired/deleted files**: both receive and send files, with configurable TTLs
- **Clean temp paths**: remove temporary file paths from completed transfers
- **Delete orphaned users**: users with no remaining connections get `DEL_USER` notification

Each cleanup operation catches errors individually (`catchAllErrors`) — a failure in one doesn't prevent others from running. The manager uses `waitActive` to pause during agent suspension, with `tryAny` to handle the case where the agent is being shut down.

## Agent suspension

`suspendAgent` triggers the operation suspension cascade defined in [Agent/Client.md](./Agent/Client.md#operation-suspension-cascade). `foregroundAgent` resumes operations. The cascade ordering (RcvNetwork → MsgDelivery → SndNetwork → Database) ensures that receiving stops first, then in-flight message delivery completes, then sending stops, and finally database operations complete.

## connectReplyQueues — background duplex upgrade

Used during async command processing to complete the duplex handshake. Handles two cases:
- **Fresh connection** (`sq_ = Nothing`): upgrades `RcvConnection` to `DuplexConnection` by creating a new send queue.
- **SKEY retry** (`sq_ = Just sq`): connection is already duplex from a previous attempt. Reuses the existing send queue.

Both paths then secure the queue and enqueue the confirmation.

## secureConfirmQueue vs secureConfirmQueueAsync

Two paths for sending the confirmation message during duplex handshake:
- **secureConfirmQueue** (synchronous): secures the queue and sends confirmation directly via network. Used in `joinConnection` (foreground user-initiated path).
- **secureConfirmQueueAsync** (asynchronous): secures the queue, stores the confirmation in the database, and submits to the delivery worker. Used in `allowConnection` (background path via `ICAllowSecure`).

Both call `agentSecureSndQueue` first, which returns whether the initiator's ratchet should be created on confirmation (v7+ behavior).

## smpConfirmation — version compatibility

The confirmation handler accepts messages where the agent version or client version is either within the configured range OR at-or-below the already-agreed version. See source comment: "checking agreed versions to continue connection in case of client/agent version downgrades." This means a downgraded client can still complete in-progress handshakes.

## smpInvitation — contact address handling

Invitation messages received on a contact address connection are passed through even if version-incompatible. See source comment: "show connection request even if invitation via contact address is not compatible." The client application sees the `REQ` event with `PQSupportOff` when incompatible, allowing it to display the request to the user (who may choose to respond from a compatible client).
