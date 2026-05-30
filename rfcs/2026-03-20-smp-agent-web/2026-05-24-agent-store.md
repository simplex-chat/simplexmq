# Agent Store: IndexedDB Design

**Parent**: [Agent Plan](./2026-05-22-agent.md)

## Schema

IndexedDB object stores, mapped from SQLite tables. Each store mirrors the Haskell schema from `agent_schema.sql`.

### Object stores needed (16)

```
users
  key: userId (autoincrement)
  fields: deleted

connections
  key: connId (Uint8Array)
  fields: connMode, lastInternalMsgId, lastInternalRcvMsgId, lastInternalSndMsgId,
          lastExternalSndMsgId, lastRcvMsgHash, lastSndMsgHash, smpAgentVersion,
          duplexHandshake, enableNtfs, deleted, userId, ratchetSyncState, pqSupport

rcv_queues
  key: [host, port, rcvId] (compound)
  index: [connId], [host, port, sndId]
  fields: connId, rcvPrivateKey, rcvDhSecret, e2ePrivKey, e2eDhSecret, sndId, sndKey,
          status, smpClientVersion, rcvQueueId, rcvPrimary, replaceRcvQueueId, queueMode,
          serverKeyHash, lastBrokerTs

snd_queues
  key: [host, port, sndId] (compound)
  index: [connId]
  fields: connId, sndPrivateKey, e2eDhSecret, status, smpClientVersion,
          sndPublicKey, e2ePubKey, sndQueueId, sndPrimary, queueMode, serverKeyHash

messages
  key: [connId, internalId] (compound)
  index: [connId]
  fields: internalTs, internalRcvId, internalSndId, msgType, msgBody, msgFlags, pqEncryption

rcv_messages
  key: [connId, internalRcvId] (compound)
  index: [connId, internalId]
  fields: internalId, externalSndId, brokerId, brokerTs, internalHash,
          externalPrevSndHash, integrity, userAck, rcvQueueId, receiveAttempts

snd_messages
  key: [connId, internalSndId] (compound)
  index: [connId, internalId]
  fields: internalId, internalHash, previousMsgHash, retryIntSlow, retryIntFast,
          rcptInternalId, rcptStatus, msgEncryptKey, paddedMsgLen, sndMessageBodyId

snd_message_deliveries
  key: sndMessageDeliveryId (autoincrement)
  index: [connId, sndQueueId]
  fields: connId, sndQueueId, internalId, failed

snd_message_bodies
  key: sndMessageBodyId (autoincrement)
  fields: agentMsg

conn_confirmations
  key: confirmationId (Uint8Array)
  index: [connId]
  fields: connId, e2eSndPubKey, senderKey, ratchetState, senderConnInfo,
          accepted, ownConnInfo, smpReplyQueues, smpClientVersion

conn_invitations
  key: invitationId (Uint8Array)
  index: [contactConnId]
  fields: contactConnId, crInvitation, recipientConnInfo, accepted, ownConnInfo

ratchets
  key: connId (Uint8Array)
  fields: x3dhPrivKey1, x3dhPrivKey2, ratchetState, e2eVersion,
          x3dhPubKey1, x3dhPubKey2, pqPrivKem, pqPubKem

skipped_messages
  key: skippedMessageId (autoincrement)
  index: [connId]
  fields: connId, headerKey, msgN, msgKey

servers
  key: [host, port] (compound)
  fields: keyHash

commands
  key: commandId (autoincrement)
  index: [connId], [host, port]
  fields: connId, host, port, corrId, commandTag, command, agentVersion, serverKeyHash, failed

encrypted_rcv_message_hashes
  key: id (autoincrement)
  index: [connId, hash]
  fields: connId, hash, createdAt
```

## Interface

TypeScript interface matching the ~60 store operations. Each method maps to a specific Haskell function in `AgentStore.hs`.

The interface will be defined in `src/agent/store.ts`. Implementation in `src/agent/store-idb.ts` (IndexedDB).

## Implementation approach

1. Define the TypeScript interface first — every method name matches the Haskell function name
2. Implement with IndexedDB transactions
3. Test each operation in isolation before wiring to agent

IndexedDB transactions map to SQLite transactions — both are ACID within a single store/table. Cross-store atomicity in IndexedDB requires putting multiple stores in one transaction, which is supported.

## Key differences from SQLite

1. **No SQL joins** — denormalize where needed, or do application-level joins
2. **No AUTO INCREMENT guaranteed ordering** — use explicit counters
3. **Blob keys** — IndexedDB supports ArrayBuffer keys natively
4. **Compound keys** — IndexedDB supports array keys: `[host, port, rcvId]`
5. **Indexes** — must be declared upfront in `onupgradeneeded`

## Testing

Each store operation tested by: write data, read it back, verify it matches. No server needed — pure store tests using `fake-indexeddb` in Node.js.
