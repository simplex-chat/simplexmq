# Agent Connections

Duplex connection lifecycle: establishment, queue rotation, ratchet synchronization, and message integrity. These cross-module flows span the Agent, protocol client, and store layers.

For per-module details: [Agent](../modules/Simplex/Messaging/Agent.md) · [Agent Protocol](../modules/Simplex/Messaging/Agent/Protocol.md) · [Ratchet](../modules/Simplex/Messaging/Crypto/Ratchet.md) · [Store Interface](../modules/Simplex/Messaging/Agent/Store/Interface.md). For the component diagram, see [agent.md](../agent.md). For protocol specification, see [Agent Protocol](../../protocol/agent-protocol.md) and [PQDR](../../protocol/pqdr.md).

- [Design constraints](#design-constraints)
- [Connection establishment](#connection-establishment)
- [Queue rotation](#queue-rotation)
- [Ratchet synchronization](#ratchet-synchronization)
- [Message envelope hierarchy](#message-envelope-hierarchy)
- [Integrity chain](#integrity-chain)

---

## Design constraints

**Source**: [Agent.hs](../../src/Simplex/Messaging/Agent.hs), [Agent/Client.hs](../../src/Simplex/Messaging/Agent/Client.hs)

Two properties of the protocol drive much of the agent's complexity:

**TOFU retry safety**: Queues and links are secured via trust-on-first-use - the router accepts the first key presented (SKEY, KEY) and rejects any subsequent different key. If a network call succeeds but the response is lost, the client must retry with the *same* key, or the router will reject it. This means all cryptographic keys must be generated and persisted *before* the network call that uses them. The agent's pervasive store-then-execute pattern (`enqueueCommand` persists to DB, then worker executes with stored keys) exists primarily to satisfy this constraint.

**Network asymmetry**: After a client sends a message to a queue, the peer's response can arrive at the agent before the originating API call returns to the application. The application must already know the connection exists when it receives the event, otherwise it gets handshake events for an unknown connection. This drives split-phase APIs where the connection is registered locally before any network call.

Together, these constraints explain why the agent separates key generation from network operations, why commands are persisted before execution, and why connection creation is split into prepare + create phases.

---

## Connection establishment

**Source**: [Agent.hs](../../src/Simplex/Messaging/Agent.hs), [Agent/Protocol.hs](../../src/Simplex/Messaging/Agent/Protocol.hs)

### Split-phase connection creation

Connection creation is split into two phases to satisfy both design constraints:

**`prepareConnectionLink`** (no network, no database): generates root Ed25519 signing key pair and queue-level X25519 DH keys. Derives a short link key as `SHA3_256` of the encoded fixed link data. Returns the connection link URI and `PreparedLinkParams` in memory. The application can now embed the link in link data (e.g., for short link resolution) before the queue exists.

**`createConnectionForLink`** (single network call): uses the prepared parameters to create the queue on the router with SKEY (root signature). The sender ID is deterministically derived from the correlation nonce (`SMP.EntityId $ B.take 24 $ C.sha3_384 corrId`), so a lost response can be retried - the router validates the same sender ID.

Without split-phase, the application would need to create the queue first, get the link, then update the queue with link data containing the link - requiring an extra round-trip.

### Standard handshake

The connection establishment flow is shown in [agent.md](../agent.md#connection-establishment-flow). The key non-obvious details:

**Ratchet initialization is asymmetric**: The initiator (Alice) generates X3DH key parameters during `newRcvConnSrv` and stores them via `createRatchetX3dhKeys`, but does not initialize any ratchet yet. The *receiving* ratchet is only initialized later in `smpConfirmation` via `initRcvRatchet` when the confirmation arrives with the responder's parameters. The responder (Bob) initializes a *sending* ratchet during `startJoinInvitation` via `initSndRatchet`. The names `RcvE2ERatchetParams`/`SndE2ERatchetParams` are historical - what matters is that the responder initializes first (sending direction), and the initiator initializes second (receiving direction) using the responder's parameters.

**Confirmation decryption proves key agreement**: In `smpConfirmation`, the initiator creates a fresh receiving ratchet from the responder's parameters and immediately uses it to decrypt the confirmation body. If decryption fails, the entire confirmation is rejected - there is no state where a connection has mismatched ratchets.

**HELLO exchange completes the handshake**: After `allowConnection`, both sides have duplex queues but haven't confirmed liveness. The responder (Bob) sends the first HELLO (with `notification = True` in MsgFlags), triggered by `ICDuplexSecure`. The initiator (Alice) receives it and sends her own HELLO back (also with `notification = True`). The initiator emits `CON` in the *delivery callback* of her HELLO (her rcvQueue is already Active from receiving Bob's HELLO). The responder emits `CON` when he *receives* the initiator's reply HELLO (his sndQueue is already Active from his own HELLO delivery). There are exactly two HELLO messages.

### Contact URI async path

For contact URIs (`joinConnectionAsync` with `CRContactUri`), the join is enqueued as an async command. The connection record is created locally (NewConnection state) before the network call, satisfying the network asymmetry constraint. The background worker then creates the receive queue, sends the invitation, and processes the handshake.

### PQ key agreement

PQ support is negotiated via version numbers: `agentVersion >= pqdrSMPAgentVersion && e2eVersion >= pqRatchetE2EEncryptVersion`. When both sides support PQ, the KEM public key travels in the confirmation body (too large for invitation URI). The responder encapsulates, producing `(kemCiphertext, kemSharedKey)`, and the hybrid key is derived via HKDF-SHA512 over the concatenation of three X3DH shared secrets plus the KEM shared secret, with info string `"SimpleXX3DH"`.

**PQ support is monotonic**: once enabled for a connection (`PQSupport PQSupportOn`), it cannot be downgraded. This affects header padding size (88 bytes without PQ vs 2310 bytes with PQ).

### Connection type state machine

```
NewConnection
  +-> RcvConnection (initiator, after newRcvConnSrv)
  |     +-> DuplexConnection (after allowConnection + connectReplyQueues)
  |     +-> ContactConnection (contact address case)
  +-> SndConnection (responder, before reply queue created)
  |     +-> DuplexConnection (after reply queue created)
  +-> ContactConnection (short link / contact address)
```

---

## Queue rotation

**Source**: [Agent.hs](../../src/Simplex/Messaging/Agent.hs), [Agent/Store.hs](../../src/Simplex/Messaging/Agent/Store.hs)

Queue rotation replaces a receive queue with a new one on a different router, providing forward secrecy for the transport layer. The protocol uses a 4-message handshake.

### Protocol sequence

Rotation is initiated by `switchConnectionAsync` (client API) or by receiving QADD from the peer. Preconditions: connection must be duplex, no switch already in progress, ratchet must not be syncing.

```
Receiver (switching party)              Sender (peer)
    |                                       |
    |-- QADD (new queue address) ---------->|
    |                                       |-- creates SndQueue to new address
    |<--------- QKEY (sender auth key) ----|
    |                                       |
    |-- secures new queue (ICQSecure) ----->|
    |-- QUSE (start using new queue) ----->|
    |                                       |-- switches delivery to new queue
    |<--------- QTEST (on new queue) ------|
    |                                       |
    |-- deletes old queue (ICQDelete) ---->|
```

### State machines

**Receiver (RcvQueue switch)**: `RSSwitchStarted` -> `RSSendingQADD` -> `RSSendingQUSE` -> `RSReceivedMessage`. The switch becomes non-abortable at `RSSendingQUSE` - by this point the sender may have already deleted the old queue, so aborting would break the connection. `canAbortRcvSwitch` enforces this.

**Sender (SndQueue switch)**: creates new SndQueue on QADD, sends QKEY, marks old as `SSSendingQKEY`. On QUSE: sends QTEST *only to the new queue*, marks as `SSSendingQTEST`. Completes when QTEST delivery succeeds.

### Consecutive rotation handling

`dbReplaceQueueId` tracks which old queue a new one replaces. Each new queue stores `dbReplaceQueueId = Just oldQueueId`. When QADD is processed, send queues whose `dbReplaceQueueId` points to the current queue's `dbQueueId` are found and deleted in bulk. This handles consecutive rotation requests - only the latest rotation survives.

### Old queue deletion

Three triggers delete the old queue:
1. **Sender-side**: QTEST delivery succeeds - old queue removed from `smpDeliveryWorkers` (worker thread stops)
2. **Receiver-side**: first message arrives on new queue - receiver marks old queue for deletion via `ICQDelete`
3. **Abort cleanup**: `abortConnectionSwitch` explicitly deletes new queues created during a failed switch attempt

---

## Ratchet synchronization

**Source**: [Agent.hs](../../src/Simplex/Messaging/Agent.hs), [Agent/Protocol.hs](../../src/Simplex/Messaging/Agent/Protocol.hs)

When double ratchet state becomes desynchronized (e.g., one side restores from backup), the agent can re-establish the ratchet without breaking the connection.

### State machine

```
RSOk (synchronized)
  |
  v  (crypto error detected)
RSAllowed / RSRequired
  |
  v  (synchronizeRatchet called)
RSStarted (waiting for peer)
  |
  v  (peer responds with own keys)
RSAgreed (both exchanged keys)
  |
  v  (ratchet recreated, EREADY sent/received)
RSOk
```

**Send prohibition**: `ratchetSyncSendProhibited` returns `True` for `RSRequired`, `RSStarted`, and `RSAgreed`. This blocks *all* messages including queue rotation messages - preventing state corruption while the ratchet is being re-established.

### Key exchange protocol

1. Initiator calls `synchronizeRatchet`, which generates new X3DH keys and sends them in an `AgentRatchetKey` envelope (discriminant `'R'`). State becomes `RSStarted`.
2. Peer receives the ratchet key in `newRatchetKey`. If peer hasn't started sync, it generates own keys and sends a reply `AgentRatchetKey`.
3. Both sides now have each other's keys. State becomes `RSAgreed`.

### Hash-ordered role assignment

Both parties compute `rkHash = SHA256(pubKeyBytes k1 || pubKeyBytes k2)` for their own keys. The party with the *smaller* hash initializes the receiving ratchet (`pqX3dhRcv`); the party with the larger hash initializes the sending ratchet (`pqX3dhSnd`) and sends `EREADY`. This deterministic tie-breaking avoids a separate negotiation round.

### EREADY completion

`EREADY` carries `lastExternalSndId` - the ID of the last message sent with the old ratchet. The receiving party uses this to know when the old ratchet's messages are exhausted and the new ratchet is fully active. Until EREADY arrives, messages may arrive encrypted with either the old or new ratchet.

### Error recovery

- **Crypto error during decrypt**: `cryptoErrToSyncState` classifies the error and sets state to `RSAllowed` or `RSRequired`. Client is notified via `RSYNC`.
- **Successful decrypt during non-RSOk state**: if state is not `RSStarted` (which means sync is actively in progress), reset to `RSOk`. A successful message proves the ratchets are synchronized.
- **Duplicate handling**: `rkHash` of received keys is checked against stored hashes to prevent reprocessing the same ratchet key message.

---

## Message envelope hierarchy

**Source**: [Agent/Protocol.hs](../../src/Simplex/Messaging/Agent/Protocol.hs)

Messages use three nesting levels, each adding a layer of structure:

### Level 1: AgentMsgEnvelope (transport)

Four variants with single-character discriminants:

| Variant | Disc. | Encryption | When |
|---------|-------|-----------|------|
| `AgentConfirmation` | `'C'` | Per-queue E2E only | Connection handshake |
| `AgentMsgEnvelope` | `'M'` | Double ratchet | Normal messages |
| `AgentInvitation` | `'I'` | Per-queue E2E only | Contact URI join |
| `AgentRatchetKey` | `'R'` | Per-queue E2E only | Ratchet sync |

Only `AgentMsgEnvelope` is double-ratchet encrypted. The other three use only the per-queue E2E encryption (DH shared secret from queue creation). This is because during handshake and ratchet sync, the double ratchet is either not yet established or being replaced.

### Level 2: AgentMessage (application)

Inside the decrypted envelope:
- `AgentConnInfo` / `AgentConnInfoReply` - connection info during handshake (not double-ratchet encrypted)
- `AgentRatchetInfo` - ratchet sync payload (not double-ratchet encrypted)
- `AgentMessage APrivHeader AMessage` - user and control messages (double-ratchet encrypted)

The private header (`APrivHeader`) carries `sndMsgId` and `prevMsgHash` for the integrity chain.

### Level 3: AMessage (semantic)

Message types with 1-2 character discriminants:
- User messages: `HELLO_`, `A_MSG_`, `A_RCVD_`, `A_QCONT_`, `EREADY_`
- Queue rotation: `QADD_`, `QKEY_`, `QUSE_`, `QTEST_`

### ACK semantics

- **User messages** (`A_MSG_`): NOT auto-ACKed. Agent returns `ACKPending`; application must call `ackMessage`.
- **Receipts** (`A_RCVD`): returns `ACKPending` when valid receipts are present (application must ACK after processing); auto-ACKed only when all receipts fail.
- **Other control messages** (HELLO, QADD, QKEY, QUSE, QTEST, EREADY, A_QCONT): auto-ACKed by the agent.
- **Error during processing**: `handleNotifyAck` sends `ERR` to the application but still ACKs to the router, preventing re-delivery of a message that will fail again.

---

## Integrity chain

**Source**: [Agent.hs](../../src/Simplex/Messaging/Agent.hs), [Agent/Protocol.hs](../../src/Simplex/Messaging/Agent/Protocol.hs)

Each message in a connection commits to the previous message via two mechanisms:

1. **External sender ID** (`lastExternalSndId`): monotonically increasing counter per connection
2. **Previous message hash** (`prevMsgHash`): SHA256 of the previous message body

`checkMsgIntegrity` produces one of five outcomes:

| Outcome | Condition |
|---------|-----------|
| `MsgOk` | Sequential ID and matching hash |
| `MsgBadId` | ID from the past (less than previous) |
| `MsgDuplicate` | Same ID as previous |
| `MsgSkipped` | Gap in IDs (messages lost) |
| `MsgBadHash` | Sequential ID but hash mismatch |

**Non-rejecting semantics**: the agent does NOT reject messages with integrity failures. The result is reported to the application via `MsgMeta.integrity`. The application decides the policy - warn, ignore, or terminate the connection.
