# Agent API Inventory for Web Widget

Every exported function from `Agent.hs`, classified as MVP / post-MVP / skip, with reasoning.

## Context

The web widget:
- Joins existing connections via addresses hardcoded in the widget or sent as simplex links
- Sends and receives messages
- Does NOT create addresses, invitation links, or short links
- Does NOT transfer files (post-MVP)
- Does NOT manage notifications (post-MVP)
- Does NOT rotate queues
- Must accept ratchet re-sync initiated by the other side (but does not initiate)

## Lifecycle

| Function | MVP? | Reason |
|----------|------|--------|
| `getSMPAgentClient` | YES | Initialize agent — required |
| `getSMPAgentClient_` | NO | Variant with extra params, not needed |
| `disconnectAgentClient` | YES | Clean shutdown — required |
| `disposeAgentClient` | NO | Hard shutdown — disconnectAgentClient is sufficient |
| `resumeAgentClient` | NO | Widget doesn't suspend/resume — runs while page is open |
| `foregroundAgent` | NO | Mobile-only concept |
| `suspendAgent` | NO | Mobile-only concept |

## User management

| Function | MVP? | Reason |
|----------|------|--------|
| `createUser` | YES | Widget needs at least one user to own connections |
| `deleteUser` | NO | Widget doesn't delete users — page reload is cleanup |

## Connection creation (widget never creates)

| Function | MVP? | Reason |
|----------|------|--------|
| `createConnection` | NO | Widget joins, never creates |
| `createConnectionAsync` | NO | Same |
| `prepareConnectionLink` | NO | For creating links |
| `createConnectionForLink` | NO | For creating links |
| `setConnShortLink` | NO | For creating short links |
| `setConnShortLinkAsync` | NO | Same |
| `deleteConnShortLink` | NO | For managing short links |
| `getConnShortLink` | NO | For reading short links — widget uses hardcoded address |
| `getConnShortLinkAsync` | NO | Same |
| `getConnLinkPrivKey` | NO | For link management |
| `deleteLocalInvShortLink` | NO | For link cleanup |
| `changeConnectionUser` | NO | Widget has one user |

## Joining connections

| Function | MVP? | Reason |
|----------|------|--------|
| `prepareConnectionToJoin` | YES | Create connection record before join — prevents race with incoming confirmation |
| `joinConnection` | YES | Core function — join via address URI |
| `joinConnectionAsync` | NO | Async variant — widget can use sync joinConnection with await |
| `connRequestPQSupport` | YES | Determine PQ support from connection request — needed for join |

## Handshake (accepting incoming)

| Function | MVP? | Reason |
|----------|------|--------|
| `allowConnection` | YES | Allow connection after receiving CONF — part of handshake |
| `allowConnectionAsync` | NO | Async variant |
| `acceptContact` | YES | Accept contact request (for group join flow) |
| `acceptContactAsync` | NO | Async variant |
| `prepareConnectionToAccept` | YES | Prepare for accept — same race prevention as prepareConnectionToJoin |
| `rejectContact` | NO | Widget doesn't reject — it always accepts |

## Subscription

| Function | MVP? | Reason |
|----------|------|--------|
| `subscribeConnection` | YES | Subscribe to receive messages on one connection |
| `subscribeConnections` | YES | Batch subscribe — needed after page reload |
| `subscribeAllConnections` | YES | Subscribe everything for a user — simplest for widget |
| `resubscribeConnection` | YES | Resubscribe after network recovery |
| `resubscribeConnections` | YES | Batch resubscribe |
| `getConnectionMessages` | NO | Fetch stored messages — widget processes messages as they arrive |
| `getNotificationConns` | NO | Push notification management |
| `subscribeClientService` | NO | Service certificate management |

## Messaging

| Function | MVP? | Reason |
|----------|------|--------|
| `sendMessage` | YES | Send a message — core function |
| `sendMessages` | NO | Batch send — sendMessage is sufficient for MVP |
| `sendMessagesB` | NO | Batch send with error handling — optimization |
| `ackMessage` | YES | Acknowledge received message — required for protocol correctness |
| `ackMessageAsync` | NO | Async variant |

## Queue management

| Function | MVP? | Reason |
|----------|------|--------|
| `switchConnection` | NO | Queue rotation — not needed |
| `switchConnectionAsync` | NO | Same |
| `abortConnectionSwitch` | NO | Cancel rotation |
| `getConnectionQueueInfo` | NO | Debug info |
| `suspendConnection` | NO | Widget deletes or ignores, doesn't suspend |

## Ratchet

| Function | MVP? | Reason |
|----------|------|--------|
| `synchronizeRatchet` | NO | Widget doesn't initiate ratchet sync. But MUST handle incoming EREADY — that's in processSMPTransmissions, not a separate API call. |
| `getConnectionRatchetAdHash` | NO | Verification UI not in widget |

## Connection cleanup

| Function | MVP? | Reason |
|----------|------|--------|
| `deleteConnection` | YES | User may want to delete a conversation |
| `deleteConnectionAsync` | NO | Async variant |
| `deleteConnections` | NO | Batch delete — single delete sufficient |
| `deleteConnectionsAsync` | NO | Same |
| `getConnectionServers` | NO | Info only |
| `compareConnections` | NO | Database sync tool |
| `syncConnections` | NO | Database sync tool |

## Server configuration

| Function | MVP? | Reason |
|----------|------|--------|
| `setProtocolServers` | NO | Widget initialized with servers, doesn't change them |
| `checkUserServers` | NO | Admin function |
| `testProtocolServer` | NO | Admin function |
| `setNtfServers` | NO | No notifications in MVP |
| `setNetworkConfig` | NO | Widget uses default network config |
| `setUserNetworkInfo` | NO | Widget doesn't track network state changes |
| `reconnectAllServers` | NO | Widget handles reconnection via SMP client |
| `reconnectSMPServer` | NO | Same |

## Notifications (all post-MVP)

| Function | MVP? | Reason |
|----------|------|--------|
| `registerNtfToken` | NO | No webpush yet |
| `verifyNtfToken` | NO | Same |
| `checkNtfToken` | NO | Same |
| `deleteNtfToken` | NO | Same |
| `getNtfToken` | NO | Same |
| `getNtfTokenData` | NO | Same |
| `toggleConnectionNtfs` | NO | Same |

## File transfer (all post-MVP)

| Function | MVP? | Reason |
|----------|------|--------|
| `xftpStartWorkers` | NO | Post-MVP |
| `xftpStartSndWorkers` | NO | Same |
| `xftpReceiveFile` | NO | Same |
| `xftpDeleteRcvFile` | NO | Same |
| `xftpDeleteRcvFiles` | NO | Same |
| `xftpSendFile` | NO | Same |
| `xftpSendDescription` | NO | Same |
| `xftpDeleteSndFileInternal` | NO | Same |
| `xftpDeleteSndFilesInternal` | NO | Same |
| `xftpDeleteSndFileRemote` | NO | Same |
| `xftpDeleteSndFilesRemote` | NO | Same |

## Remote control (all skip)

| Function | MVP? | Reason |
|----------|------|--------|
| `rcNewHostPairing` | NO | Not in scope |
| `rcConnectHost` | NO | Same |
| `rcConnectCtrl` | NO | Same |
| `rcDiscoverCtrl` | NO | Same |

## Debug/stats (all skip)

| Function | MVP? | Reason |
|----------|------|--------|
| `getAgentSubsTotal` | NO | Debug |
| `getAgentServersSummary` | NO | Debug |
| `resetAgentServersStats` | NO | Debug |
| `execAgentStoreSQL` | NO | Debug |
| `getAgentMigrations` | NO | Debug |
| `debugAgentLocks` | NO | Debug |
| `getAgentSubscriptions` | NO | Debug |
| `logConnection` | NO | Debug |
| `withAgentEnv` | NO | Test utility |

## Summary

### Corrections after reviewing simplex-chat-2 Subscriber.hs + Commands.hs

The widget handles business chats (groups). Group flows trigger agent calls the widget doesn't initiate but must support:

- Member introductions create connections asynchronously → `createConnectionAsync`
- Members join via introductions → `joinConnectionAsync`, `prepareConnectionToJoin`
- Members leave/deleted → `deleteConnectionAsync`, `deleteConnectionsAsync`
- Group messages go to all members → `sendMessages`
- All message acks use async variant → `ackMessageAsync`
- Accepting group invitations → `allowConnectionAsync`
- `acceptContact` — used in contact request acceptance flow (APIAcceptContactRequest in Commands.hs)
- `toggleConnectionNtfs` — used when CON received for group member (Subscriber.hs:850)

### MVP functions (27 of 90):

**Lifecycle:** `getSMPAgentClient`, `disconnectAgentClient`

**User:** `createUser`

**Join:** `prepareConnectionToJoin`, `joinConnection`, `joinConnectionAsync`, `connRequestPQSupport`

**Handshake:** `allowConnection`, `allowConnectionAsync`, `acceptContact`, `acceptContactAsync`, `prepareConnectionToAccept`

**Connection creation (for group member flows):** `createConnectionAsync`, `deleteConnectionAsync`, `deleteConnectionsAsync`

**Subscribe:** `subscribeConnection`, `subscribeConnections`, `subscribeAllConnections`, `resubscribeConnection`, `resubscribeConnections`

**Message:** `sendMessage`, `sendMessages`, `ackMessage`, `ackMessageAsync`

**Cleanup:** `deleteConnection`

**Notification toggle:** `toggleConnectionNtfs`

**Internal (not exported but required):** `subscriber`/`processSMPTransmissions` (message processing), `runSmpQueueMsgDelivery` (delivery worker), all encryption/decryption functions, store operations for the above.

### Message types to handle in processSMPTransmissions:

| AMessage | Handle? | Reason |
|----------|---------|--------|
| `HELLO` | YES | Complete handshake |
| `A_MSG body` | YES | Deliver message to user |
| `A_RCVD receipts` | YES | Process delivery receipts (show checkmarks) |
| `A_QCONT addr` | NO | Queue continuation after quota — skip |
| `QADD qs` | NO | Queue rotation — skip |
| `QKEY qs` | NO | Queue rotation — skip |
| `QUSE qs` | NO | Queue rotation — skip |
| `QTEST qs` | NO | Queue rotation — skip |
| `EREADY msgId` | ACCEPT | Must handle incoming (don't initiate) — reset ratchet sync state |

### AgentMsgEnvelope types to handle:

| Variant | Handle? | Reason |
|---------|---------|--------|
| `AgentConfirmation` | YES | Handshake — received when peer confirms |
| `AgentMsgEnvelope` | YES | Normal encrypted messages |
| `AgentInvitation` | YES | Received when joining contact address |
| `AgentRatchetKey` | ACCEPT | Must handle incoming ratchet key — don't initiate |

### Store operations needed:

Based on the 18 MVP functions, the store needs (rough count):

- Connection CRUD: ~8 operations
- Queue CRUD: ~6 operations
- Ratchet state: ~4 operations (get, update, skipped keys)
- Message storage: ~6 operations (create rcv/snd msg, update status, delete)
- Message delivery: ~4 operations (create delivery, get pending, update status)
- User: ~2 operations (create, get)
- Confirmation: ~3 operations (create, get, delete)

**Estimated: ~33 store operations.** This is what determines whether SQLite WASM or IndexedDB direct is more practical.
