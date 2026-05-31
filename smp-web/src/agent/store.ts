// Agent store interface for IndexedDB.
// Each method mirrors a Haskell function in AgentStore.hs.
// Implementation in store-idb.ts.

// -- Types matching Haskell store types

export type ConnId = Uint8Array
export type UserId = number
export type EntityId = Uint8Array
export type InternalId = number
export type InternalRcvId = number
export type InternalSndId = number

export type QueueStatus = "new" | "confirmed" | "secured" | "active" | "disabled" | "deleted"

// Matches Haskell SkippedMsgDiff (Crypto/Ratchet.hs:584-587)
export type SkippedMsgDiff =
  | {type: "noChange"}
  | {type: "remove", headerKey: Uint8Array, msgN: number}
  | {type: "add", keys: Map<Uint8Array, Map<number, any>>}  // Map<HeaderKey, Map<MsgN, MessageKey>>
export type ConnectionMode = "INV" | "CON"  // SCMInvitation | SCMContact
export type RatchetSyncState = "ok" | "allowed" | "required" | "started" | "agreed"

export interface ConnData {
  connId: ConnId
  connMode: ConnectionMode
  userId: UserId
  smpAgentVersion: number
  enableNtfs: boolean
  duplexHandshake: boolean
  deleted: boolean
  ratchetSyncState: RatchetSyncState
  pqSupport: boolean
  // Message ID counters
  lastInternalMsgId: number
  lastInternalRcvMsgId: number
  lastInternalSndMsgId: number
  lastExternalSndMsgId: number
  lastRcvMsgHash: Uint8Array
  lastSndMsgHash: Uint8Array
}

export interface RcvQueue {
  host: string
  port: string
  rcvId: Uint8Array
  connId: ConnId
  rcvPrivateKey: Uint8Array
  rcvDhSecret: Uint8Array
  e2ePrivKey: Uint8Array
  e2eDhSecret: Uint8Array | null
  sndId: Uint8Array
  sndKey: Uint8Array | null
  status: QueueStatus
  smpClientVersion: number | null
  dbQueueId: number
  primary: boolean
  replaceRcvQueueId: number | null
  queueMode: string | null
  serverKeyHash: Uint8Array | null
  lastBrokerTs: string | null
}

export interface SndQueue {
  host: string
  port: string
  sndId: Uint8Array
  connId: ConnId
  sndPrivateKey: Uint8Array
  e2eDhSecret: Uint8Array
  status: QueueStatus
  smpClientVersion: number
  sndPublicKey: Uint8Array | null
  e2ePubKey: Uint8Array | null
  dbQueueId: number
  primary: boolean
  queueMode: string | null
  serverKeyHash: Uint8Array | null
}

export interface MsgMeta {
  integrity: string  // "OK" or error
  recipient: [number, string]  // (internalId, internalTs)
  broker: [Uint8Array, string]  // (brokerId/msgId, brokerTs)
  sndMsgId: number
  pqEncryption: boolean
}

export interface RcvMsgData {
  msgMeta: MsgMeta
  msgType: string
  msgFlags: number
  msgBody: Uint8Array
  internalRcvId: number
  internalHash: Uint8Array
  externalPrevSndHash: Uint8Array
  encryptedMsgHash: Uint8Array
}

export interface SndMsgData {
  internalId: number
  internalSndId: number
  internalTs: string
  msgType: string
  msgFlags: number
  msgBody: Uint8Array
  pqEncryption: boolean
  internalHash: Uint8Array
  prevMsgHash: Uint8Array
  msgEncryptKey: Uint8Array | null
  paddedMsgLen: number | null
  sndMessageBodyId: number | null
}

export interface Confirmation {
  confirmationId: Uint8Array
  connId: ConnId
  e2eSndPubKey: Uint8Array
  senderKey: Uint8Array | null
  ratchetState: Uint8Array
  senderConnInfo: Uint8Array
  accepted: boolean
  ownConnInfo: Uint8Array | null
  smpReplyQueues: Uint8Array | null  // serialized
  smpClientVersion: number | null
}

export interface Invitation {
  invitationId: Uint8Array
  contactConnId: ConnId | null
  crInvitation: Uint8Array
  recipientConnInfo: Uint8Array
  accepted: boolean
  ownConnInfo: Uint8Array | null
}

export interface RcvMsg {
  internalId: number
  msgMeta: MsgMeta
  msgType: string
  msgBody: Uint8Array
  internalHash: Uint8Array
  userAck: boolean
  msgReceipt: {agentMsgId: number, msgRcptStatus: string} | null
}

export interface PendingQueueMsg {
  connId: ConnId
  sndQueueId: number
  internalId: number
  internalTs: string
  internalSndId: number
  msgType: string
  msgFlags: number
  msgBody: Uint8Array
  internalHash: Uint8Array
  prevMsgHash: Uint8Array
  pqEncryption: boolean
  retryIntSlow: number | null
  retryIntFast: number | null
  msgEncryptKey: Uint8Array | null
  paddedMsgLen: number | null
  sndMsgBody: Uint8Array | null  // agent_msg from snd_message_bodies (joined)
}

export interface AsyncCommand {
  commandId: number
  connId: ConnId
  host: string | null
  port: string | null
  corrId: Uint8Array
  commandTag: string
  command: Uint8Array
  agentVersion: number
  serverKeyHash: Uint8Array | null
  failed: boolean
}

// -- Store interface
// Each method name matches the Haskell function in AgentStore.hs.

export interface AgentStore {
  // -- Users (AgentStore.hs:201-230)
  createUserRecord(): Promise<UserId>
  getUserIds(): Promise<UserId[]>
  deleteUserRecord(userId: UserId): Promise<void>
  setUserDeleted(userId: UserId): Promise<ConnId[]>

  // -- Servers (AgentStore.hs:233-240)
  createServer(host: string, port: string, keyHash: Uint8Array): Promise<void>

  // -- Connections (AgentStore.hs:242-500)
  createNewConn(connData: ConnData, connMode: ConnectionMode): Promise<ConnId>
  getConn(connId: ConnId): Promise<{connData: ConnData, rcvQueues: RcvQueue[], sndQueues: SndQueue[]} | null>
  getRcvConn(host: string, port: string, rcvId: Uint8Array): Promise<{connData: ConnData, rcvQueue: RcvQueue} | null>
  getConnSubs(connIds: ConnId[]): Promise<Map<string, ConnData>>
  getConnsData(connIds: ConnId[]): Promise<Map<string, ConnData>>
  lockConnForUpdate(connId: ConnId): Promise<void>  // no-op in IndexedDB (single-threaded)
  setConnDeleted(connId: ConnId, waitDelivery: boolean): Promise<void>
  setConnUserId(oldUserId: UserId, connId: ConnId, newUserId: UserId): Promise<void>
  setConnAgentVersion(connId: ConnId, version: number): Promise<void>
  setConnPQSupport(connId: ConnId, pqSupport: boolean): Promise<void>
  setConnRatchetSync(connId: ConnId, state: RatchetSyncState): Promise<void>
  updateNewConnJoin(connId: ConnId, agentVersion: number, pqSupport: boolean, enableNtfs: boolean): Promise<void>
  updateNewConnRcv(connId: ConnId, rcvQueue: RcvQueue, subMode: string): Promise<RcvQueue>
  getDeletedConnIds(): Promise<ConnId[]>
  getDeletedWaitingDeliveryConnIds(): Promise<ConnId[]>
  getConnIds(): Promise<ConnId[]>

  // -- Queues (AgentStore.hs:500-700)
  addConnRcvQueue(connId: ConnId, rcvQueue: RcvQueue, subMode: string): Promise<RcvQueue>
  addConnSndQueue(connId: ConnId, sndQueue: SndQueue): Promise<SndQueue>
  setRcvQueueStatus(rcvQueue: RcvQueue, status: QueueStatus): Promise<void>
  setSndQueueStatus(sndQueue: SndQueue, status: QueueStatus): Promise<void>
  setRcvQueueConfirmedE2E(rcvQueue: RcvQueue, dhSecret: Uint8Array, smpClientVersion: number): Promise<void>
  setRcvQueuePrimary(connId: ConnId, rcvQueue: RcvQueue): Promise<void>
  deleteConnRcvQueue(rcvQueue: RcvQueue): Promise<void>
  deleteConnRecord(connId: ConnId): Promise<void>
  upgradeRcvConnToDuplex(connId: ConnId, sndQueue: SndQueue): Promise<SndQueue>
  upgradeSndConnToDuplex(connId: ConnId, rcvQueue: RcvQueue, subMode: string): Promise<RcvQueue>
  getPrimaryRcvQueue(connId: ConnId): Promise<RcvQueue | null>
  getRcvQueue(connId: ConnId, host: string, port: string, rcvId: Uint8Array): Promise<RcvQueue | null>
  getDeletedRcvQueue(connId: ConnId, host: string, port: string, rcvId: Uint8Array): Promise<RcvQueue | null>
  setConnectionNtfs(connId: ConnId, enable: boolean): Promise<void>

  // -- Subscriptions (AgentStore.hs:700-800)
  getSubscriptionServers(onlyNeeded: boolean): Promise<Array<{userId: UserId, host: string, port: string, keyHash: Uint8Array}>>
  getUserServerRcvQueueSubs(userId: UserId, host: string, port: string, keyHash: Uint8Array, onlyNeeded: boolean, batchSize: number, cursor: number | null): Promise<{queues: RcvQueue[], nextCursor: number | null}>
  unsetQueuesToSubscribe(): Promise<void>
  getConnectionsForDelivery(): Promise<ConnId[]>
  getAllSndQueuesForDelivery(): Promise<SndQueue[]>

  // -- Confirmations (AgentStore.hs:800-870)
  createConfirmation(confirmation: Confirmation): Promise<Uint8Array>
  acceptConfirmation(confirmationId: Uint8Array, ownConnInfo: Uint8Array): Promise<Confirmation>
  getAcceptedConfirmation(connId: ConnId): Promise<Confirmation | null>
  removeConfirmations(connId: ConnId): Promise<void>

  // -- Invitations (AgentStore.hs:870-920)
  createInvitation(invitation: Invitation): Promise<Uint8Array>
  getInvitation(invitationId: Uint8Array): Promise<Invitation | null>
  acceptInvitation(invitationId: Uint8Array, ownConnInfo: Uint8Array): Promise<void>
  unacceptInvitation(invitationId: Uint8Array): Promise<void>
  deleteInvitation(invitationId: Uint8Array): Promise<void>

  // -- Messages (AgentStore.hs:873-1050)
  updateRcvIds(connId: ConnId): Promise<{internalId: number, internalRcvId: number, prevExternalSndId: number, prevRcvMsgHash: Uint8Array}>
  createRcvMsg(connId: ConnId, rcvQueue: RcvQueue, rcvMsgData: RcvMsgData): Promise<void>
  setLastBrokerTs(connId: ConnId, dbQueueId: number, brokerTs: string): Promise<void>
  updateRcvMsgHash(connId: ConnId, sndMsgId: number, internalRcvId: number, hash: Uint8Array): Promise<void>
  createSndMsgBody(agentMsg: Uint8Array): Promise<number>
  updateSndIds(connId: ConnId): Promise<{internalId: number, internalSndId: number, prevSndMsgHash: Uint8Array}>
  createSndMsg(connId: ConnId, sndMsgData: SndMsgData): Promise<void>
  updateSndMsgHash(connId: ConnId, internalSndId: number, hash: Uint8Array): Promise<void>
  createSndMsgDelivery(connId: ConnId, sndQueue: SndQueue, internalId: number): Promise<void>
  getPendingQueueMsg(connId: ConnId, sndQueue: SndQueue): Promise<{rcvQueue: RcvQueue | null, msg: PendingQueueMsg} | null>
  updatePendingMsgRIState(connId: ConnId, msgId: number, retryIntSlow: number | null, retryIntFast: number | null): Promise<void>
  setMsgUserAck(connId: ConnId, internalId: number): Promise<{rcvQueue: RcvQueue, brokerId: Uint8Array}>
  getRcvMsg(connId: ConnId, internalId: number): Promise<RcvMsg | null>
  getLastMsg(connId: ConnId, brokerId: Uint8Array): Promise<RcvMsg | null>
  incMsgRcvAttempts(connId: ConnId, internalId: number): Promise<number>
  checkRcvMsgHashExists(connId: ConnId, hash: Uint8Array): Promise<boolean>
  getRcvMsgBrokerTs(connId: ConnId, brokerId: Uint8Array): Promise<string | null>
  deleteMsg(connId: ConnId, internalId: number): Promise<void>
  deleteDeliveredSndMsg(connId: ConnId, internalId: number): Promise<void>
  deleteSndMsgDelivery(connId: ConnId, sndQueue: SndQueue, msgId: number, keepForReceipt: boolean): Promise<void>
  getSndMsgViaRcpt(connId: ConnId, sndMsgId: number): Promise<{internalId: number, msgType: string, internalHash: Uint8Array, msgReceipt: {agentMsgId: number, msgRcptStatus: string} | null} | null>
  updateSndMsgRcpt(connId: ConnId, sndMsgId: number, receipt: {agentMsgId: number, msgRcptStatus: string}): Promise<void>

  // -- Ratchet (AgentStore.hs:1300-1400)
  createRatchetX3dhKeys(connId: ConnId, privKey1: Uint8Array, privKey2: Uint8Array, pqKem: Uint8Array | null): Promise<void>
  getRatchetX3dhKeys(connId: ConnId): Promise<{privKey1: Uint8Array, privKey2: Uint8Array, pqKem: Uint8Array | null} | null>
  createRatchet(connId: ConnId, ratchetState: Uint8Array): Promise<void>
  getRatchet(connId: ConnId): Promise<Uint8Array | null>
  getRatchetForUpdate(connId: ConnId): Promise<Uint8Array | null>  // same as getRatchet in IndexedDB (single-threaded)
  getSkippedMsgKeys(connId: ConnId): Promise<Map<string, Map<number, {mk: Uint8Array, iv: Uint8Array}>>>
  updateRatchet(connId: ConnId, ratchetState: Uint8Array, skippedMsgDiff: SkippedMsgDiff): Promise<void>

  // -- Commands (AgentStore.hs:1400-1480)
  createCommand(corrId: Uint8Array, connId: ConnId, host: string | null, port: string | null, command: AsyncCommand): Promise<number>
  getPendingCommandServers(connIds: ConnId[]): Promise<Array<{connId: ConnId, host: string, port: string}>>
  getAllPendingCommandConns(): Promise<Array<{connId: ConnId, host: string, port: string}>>
  getPendingServerCommand(connId: ConnId, host: string | null, port: string | null): Promise<AsyncCommand | null>
  updateCommandServer(commandId: number, host: string, port: string): Promise<void>
  deleteCommand(commandId: number): Promise<void>

  // -- Encrypted message hash dedup (AgentStore.hs:1200-1220)
  checkRcvMsgHashExists_encrypted(connId: ConnId, hash: Uint8Array): Promise<boolean>
  addEncryptedRcvMsgHash(connId: ConnId, hash: Uint8Array): Promise<void>
}
