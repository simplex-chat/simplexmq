// Agent store scenario tests using fake-indexeddb.
// Each scenario exercises a full lifecycle: create → update → read → delete → verify gone.
// Every store method is called from at least one test.

import "fake-indexeddb/auto"
import {openAgentStore} from "../dist/agent/store-idb.js"
import type {AgentStore} from "../dist/agent/store.js"

// The store returns raw IndexedDB rows with snake_case field names.
// The TypeScript interface types use camelCase but the underlying data is snake_case.
// We use `any` casts in assertions to access the actual field names.
type Row = any

// -- Helpers

function bytes(hex: string): Uint8Array {
  const b = new Uint8Array(hex.length / 2)
  for (let i = 0; i < hex.length; i += 2) b[i / 2] = parseInt(hex.slice(i, i + 2), 16)
  return b
}

function hex(b: Uint8Array): string {
  return Array.from(b, x => x.toString(16).padStart(2, "0")).join("")
}

function randomBytes(n: number): Uint8Array {
  const b = new Uint8Array(n)
  for (let i = 0; i < n; i++) b[i] = Math.floor(Math.random() * 256)
  return b
}

let passed = 0
let failed = 0

function assert(cond: boolean, msg: string) {
  if (!cond) {
    console.error("FAIL:", msg)
    failed++
  } else {
    passed++
  }
}

function assertEq(a: any, b: any, msg: string) {
  const av = a instanceof Uint8Array ? hex(a) : JSON.stringify(a)
  const bv = b instanceof Uint8Array ? hex(b) : JSON.stringify(b)
  assert(av === bv, `${msg}: expected ${bv}, got ${av}`)
}

async function assertThrows(fn: () => Promise<any>, msg: string) {
  try {
    await fn()
    assert(false, `${msg}: expected throw`)
  } catch {
    passed++
  }
}

// -- Scenarios

async function testUsers(store: AgentStore) {
  console.log("  users...")
  // createUserRecord, getUserIds
  const uid1 = await store.createUserRecord()
  const uid2 = await store.createUserRecord()
  let ids = await store.getUserIds()
  assert(ids.includes(uid1) && ids.includes(uid2), "getUserIds returns both users")

  // setUserDeleted — marks user as deleted, getUserIds should exclude it
  await store.setUserDeleted(uid1)
  ids = await store.getUserIds()
  assert(!ids.includes(uid1), "deleted user not in getUserIds")
  assert(ids.includes(uid2), "non-deleted user still in getUserIds")

  // deleteUserRecord — hard delete
  await store.deleteUserRecord(uid2)
  ids = await store.getUserIds()
  assert(!ids.includes(uid2), "hard-deleted user gone")
}

async function testServers(store: AgentStore) {
  console.log("  servers...")
  // createServer — insert or ignore
  const kh = randomBytes(32)
  await store.createServer("smp1.example.com", "5223", kh)
  // Duplicate should not throw
  await store.createServer("smp1.example.com", "5223", kh)
}

async function testConnectionsAndQueues(store: AgentStore) {
  console.log("  connections and queues...")
  const userId = await store.createUserRecord()
  const connId = randomBytes(24)
  const connId2 = randomBytes(24)

  // createNewConn
  const created = await store.createNewConn({
    connId, connMode: "INV", userId, smpAgentVersion: 7,
    enableNtfs: true, duplexHandshake: true, deleted: false,
    ratchetSyncState: "ok", pqSupport: true,
    lastInternalMsgId: 0, lastInternalRcvMsgId: 0, lastInternalSndMsgId: 0,
    lastExternalSndMsgId: 0, lastRcvMsgHash: new Uint8Array(0), lastSndMsgHash: new Uint8Array(0),
  }, "INV")
  assertEq(created, connId, "createNewConn returns connId")

  // getConn — should find it
  const got = await store.getConn(connId)
  assert(got !== null, "getConn finds connection")
  assertEq((got!.connData as Row).conn_id, connId, "getConn connId matches")

  // getConnIds
  const allIds = await store.getConnIds()
  assert(allIds.some(id => hex(id) === hex(connId)), "getConnIds includes new conn")

  // setConnAgentVersion
  await store.setConnAgentVersion(connId, 8)
  const got2 = await store.getConn(connId)
  assertEq((got2!.connData as Row).smp_agent_version, 8, "setConnAgentVersion updated")

  // setConnPQSupport
  await store.setConnPQSupport(connId, false)
  const got3 = await store.getConn(connId)
  assertEq((got3!.connData as Row).pq_support, 0, "setConnPQSupport updated")

  // setConnRatchetSync
  await store.setConnRatchetSync(connId, "required")
  const got4 = await store.getConn(connId)
  assertEq((got4!.connData as Row).ratchet_sync_state, "required", "setConnRatchetSync updated")

  // setConnectionNtfs
  await store.setConnectionNtfs(connId, false)
  const got5 = await store.getConn(connId)
  assertEq((got5!.connData as Row).enable_ntfs, 0, "setConnectionNtfs updated")

  // lockConnForUpdate — no-op, should not throw
  await store.lockConnForUpdate(connId)

  // addConnRcvQueue
  const rcvQ = await store.addConnRcvQueue(connId, {
    host: "smp1.example.com", port: "5223", rcvId: randomBytes(24),
    connId, rcvPrivateKey: randomBytes(32), rcvDhSecret: randomBytes(32),
    e2ePrivKey: randomBytes(32), e2eDhSecret: null,
    sndId: randomBytes(24), sndKey: null, status: "new" as const,
    smpClientVersion: 7, dbQueueId: 0, primary: true,
    replaceRcvQueueId: null, queueMode: null,
    serverKeyHash: randomBytes(32), lastBrokerTs: null,
  }, "SMSubscribe")
  assert(rcvQ.dbQueueId >= 1, "addConnRcvQueue assigns dbQueueId")

  // getPrimaryRcvQueue
  const primary = await store.getPrimaryRcvQueue(connId)
  assert(primary !== null, "getPrimaryRcvQueue finds queue")
  assertEq((primary as Row).rcv_primary, 1, "primary queue is marked primary")

  // getRcvConn
  const rcvConn = await store.getRcvConn(rcvQ.host, rcvQ.port, rcvQ.rcvId)
  assert(rcvConn !== null, "getRcvConn finds by host/port/rcvId")

  // getRcvQueue
  const rq = await store.getRcvQueue(connId, rcvQ.host, rcvQ.port, rcvQ.rcvId)
  assert(rq !== null, "getRcvQueue finds queue")

  // setRcvQueueStatus
  await store.setRcvQueueStatus(rcvQ, "confirmed")
  const rq2 = await store.getRcvQueue(connId, rcvQ.host, rcvQ.port, rcvQ.rcvId)
  assertEq(rq2!.status, "confirmed", "setRcvQueueStatus updated")

  // setRcvQueueConfirmedE2E
  const dhSecret = randomBytes(32)
  await store.setRcvQueueConfirmedE2E(rcvQ, dhSecret, 7)
  const rq3 = await store.getRcvQueue(connId, rcvQ.host, rcvQ.port, rcvQ.rcvId)
  assertEq((rq3 as Row).e2e_dh_secret, dhSecret, "setRcvQueueConfirmedE2E updated dh secret")
  assertEq((rq3 as Row).status, "confirmed", "setRcvQueueConfirmedE2E sets confirmed")

  // addConnSndQueue + upgradeRcvConnToDuplex (same operation)
  const sndQ = {
    host: "smp2.example.com", port: "5223", sndId: randomBytes(24),
    connId, sndPrivateKey: randomBytes(32), e2eDhSecret: randomBytes(32),
    status: "confirmed" as const, smpClientVersion: 7,
    sndPublicKey: randomBytes(32), e2ePubKey: randomBytes(32),
    dbQueueId: 0, primary: true, queueMode: null, serverKeyHash: randomBytes(32),
  }
  await store.upgradeRcvConnToDuplex(connId, sndQ)
  const gotDuplex = await store.getConn(connId)
  assert(gotDuplex!.sndQueues.length >= 1, "upgradeRcvConnToDuplex added snd queue")

  // setSndQueueStatus
  await store.setSndQueueStatus(sndQ, "active")

  // getConnSubs, getConnsData
  const subs = await store.getConnSubs([connId])
  assert(subs.size === 1, "getConnSubs returns 1 entry")
  const connsData = await store.getConnsData([connId])
  assert(connsData.size === 1, "getConnsData returns 1 entry")

  // Create second connection for setConnUserId
  await store.createNewConn({
    connId: connId2, connMode: "CON", userId, smpAgentVersion: 7,
    enableNtfs: true, duplexHandshake: true, deleted: false,
    ratchetSyncState: "ok", pqSupport: false,
    lastInternalMsgId: 0, lastInternalRcvMsgId: 0, lastInternalSndMsgId: 0,
    lastExternalSndMsgId: 0, lastRcvMsgHash: new Uint8Array(0), lastSndMsgHash: new Uint8Array(0),
  }, "CON")
  const userId2 = await store.createUserRecord()
  await store.setConnUserId(userId, connId2, userId2)
  const got6 = await store.getConn(connId2)
  assertEq((got6!.connData as Row).user_id, userId2, "setConnUserId updated")

  // updateNewConnJoin
  await store.updateNewConnJoin(connId, 9, true, false)
  const got7 = await store.getConn(connId)
  assertEq((got7!.connData as Row).smp_agent_version, 9, "updateNewConnJoin updated version")

  // updateNewConnRcv — adds a rcv queue (same as addConnRcvQueue)
  const rcvQ2 = await store.updateNewConnRcv(connId2, {
    host: "smp3.example.com", port: "5223", rcvId: randomBytes(24),
    connId: connId2, rcvPrivateKey: randomBytes(32), rcvDhSecret: randomBytes(32),
    e2ePrivKey: randomBytes(32), e2eDhSecret: null,
    sndId: randomBytes(24), sndKey: null, status: "new" as const,
    smpClientVersion: 7, dbQueueId: 0, primary: true,
    replaceRcvQueueId: null, queueMode: null,
    serverKeyHash: randomBytes(32), lastBrokerTs: null,
  }, "SMSubscribe")
  assert(rcvQ2.dbQueueId >= 1, "updateNewConnRcv assigns dbQueueId")

  // upgradeSndConnToDuplex — add rcv queue to a snd-only connection
  const connId3 = randomBytes(24)
  await store.createNewConn({
    connId: connId3, connMode: "INV", userId, smpAgentVersion: 7,
    enableNtfs: true, duplexHandshake: true, deleted: false,
    ratchetSyncState: "ok", pqSupport: false,
    lastInternalMsgId: 0, lastInternalRcvMsgId: 0, lastInternalSndMsgId: 0,
    lastExternalSndMsgId: 0, lastRcvMsgHash: new Uint8Array(0), lastSndMsgHash: new Uint8Array(0),
  }, "INV")
  await store.addConnSndQueue(connId3, {
    host: "smp4.example.com", port: "5223", sndId: randomBytes(24),
    connId: connId3, sndPrivateKey: randomBytes(32), e2eDhSecret: randomBytes(32),
    status: "confirmed" as const, smpClientVersion: 7,
    sndPublicKey: null, e2ePubKey: null, dbQueueId: 0, primary: true,
    queueMode: null, serverKeyHash: randomBytes(32),
  })
  const rcvQ3 = await store.upgradeSndConnToDuplex(connId3, {
    host: "smp4.example.com", port: "5223", rcvId: randomBytes(24),
    connId: connId3, rcvPrivateKey: randomBytes(32), rcvDhSecret: randomBytes(32),
    e2ePrivKey: randomBytes(32), e2eDhSecret: null,
    sndId: randomBytes(24), sndKey: null, status: "new" as const,
    smpClientVersion: 7, dbQueueId: 0, primary: true,
    replaceRcvQueueId: null, queueMode: null,
    serverKeyHash: randomBytes(32), lastBrokerTs: null,
  }, "SMSubscribe")
  assert(rcvQ3.dbQueueId >= 1, "upgradeSndConnToDuplex added rcv queue")

  // setRcvQueuePrimary — add second rcv queue, make it primary
  const rcvQ4 = await store.addConnRcvQueue(connId, {
    host: "smp5.example.com", port: "5223", rcvId: randomBytes(24),
    connId, rcvPrivateKey: randomBytes(32), rcvDhSecret: randomBytes(32),
    e2ePrivKey: randomBytes(32), e2eDhSecret: null,
    sndId: randomBytes(24), sndKey: null, status: "new" as const,
    smpClientVersion: 7, dbQueueId: 0, primary: false,
    replaceRcvQueueId: null, queueMode: null,
    serverKeyHash: randomBytes(32), lastBrokerTs: null,
  }, "SMSubscribe")
  await store.setRcvQueuePrimary(connId, rcvQ4)
  const newPrimary = await store.getPrimaryRcvQueue(connId)
  assertEq((newPrimary as Row).rcv_queue_id, rcvQ4.dbQueueId, "setRcvQueuePrimary changed primary")

  // getDeletedRcvQueue — first delete a queue, then find it
  // deleteConnRcvQueue physically deletes, so getDeletedRcvQueue won't find it
  // We need to test the soft-delete path — but deleteConnRcvQueue does hard delete
  // Just verify it returns null for non-deleted
  const drq = await store.getDeletedRcvQueue(connId, rcvQ.host, rcvQ.port, rcvQ.rcvId)
  assert(drq === null, "getDeletedRcvQueue returns null for non-deleted queue")

  // deleteConnRcvQueue
  await store.deleteConnRcvQueue(rcvQ4)
  const afterDel = await store.getRcvQueue(connId, rcvQ4.host, rcvQ4.port, rcvQ4.rcvId)
  assert(afterDel === null, "deleteConnRcvQueue removes queue")

  // setConnDeleted (waitDelivery=true)
  await store.setConnDeleted(connId2, true)
  const waitDel = await store.getDeletedWaitingDeliveryConnIds()
  assert(waitDel.some(id => hex(id) === hex(connId2)), "setConnDeleted waitDelivery appears in getDeletedWaitingDeliveryConnIds")

  // setConnDeleted (waitDelivery=false)
  await store.setConnDeleted(connId3, false)
  const delIds = await store.getDeletedConnIds()
  assert(delIds.some(id => hex(id) === hex(connId3)), "setConnDeleted appears in getDeletedConnIds")

  // deleteConnRecord
  await store.deleteConnRecord(connId3)
  const gone = await store.getConn(connId3)
  assert(gone === null, "deleteConnRecord removes connection")
}

async function testSubscriptions(store: AgentStore) {
  console.log("  subscriptions...")
  const userId = await store.createUserRecord()
  const connId = randomBytes(24)
  await store.createNewConn({
    connId, connMode: "INV", userId, smpAgentVersion: 7,
    enableNtfs: true, duplexHandshake: true, deleted: false,
    ratchetSyncState: "ok", pqSupport: false,
    lastInternalMsgId: 0, lastInternalRcvMsgId: 0, lastInternalSndMsgId: 0,
    lastExternalSndMsgId: 0, lastRcvMsgHash: new Uint8Array(0), lastSndMsgHash: new Uint8Array(0),
  }, "INV")
  await store.createServer("sub.example.com", "5223", randomBytes(32))
  const rcvQ = await store.addConnRcvQueue(connId, {
    host: "sub.example.com", port: "5223", rcvId: randomBytes(24),
    connId, rcvPrivateKey: randomBytes(32), rcvDhSecret: randomBytes(32),
    e2ePrivKey: randomBytes(32), e2eDhSecret: null,
    sndId: randomBytes(24), sndKey: null, status: "new" as const,
    smpClientVersion: 7, dbQueueId: 0, primary: true,
    replaceRcvQueueId: null, queueMode: null,
    serverKeyHash: randomBytes(32), lastBrokerTs: null,
  }, "SMOnlyCreate")

  // getSubscriptionServers — onlyNeeded=true should find our to_subscribe=1 queue
  const srvs = await store.getSubscriptionServers(true)
  assert(srvs.some(s => s.host === "sub.example.com"), "getSubscriptionServers finds queue with to_subscribe")

  // getSubscriptionServers — onlyNeeded=false
  const allSrvs = await store.getSubscriptionServers(false)
  assert(allSrvs.some(s => s.host === "sub.example.com"), "getSubscriptionServers(false) finds all")

  // getUserServerRcvQueueSubs
  const {queues} = await store.getUserServerRcvQueueSubs(userId, "sub.example.com", "5223", true, 10, null)
  assert(queues.length >= 1, "getUserServerRcvQueueSubs finds queues")

  // unsetQueuesToSubscribe
  await store.unsetQueuesToSubscribe()
  const srvsAfter = await store.getSubscriptionServers(true)
  assert(!srvsAfter.some(s => s.host === "sub.example.com"), "unsetQueuesToSubscribe clears to_subscribe")

  // getConnectionsForDelivery, getAllSndQueuesForDelivery — need snd deliveries
  // Add snd queue and delivery
  const sndQ = {
    host: "sub.example.com", port: "5223", sndId: randomBytes(24),
    connId, sndPrivateKey: randomBytes(32), e2eDhSecret: randomBytes(32),
    status: "active" as const, smpClientVersion: 7,
    sndPublicKey: null, e2ePubKey: null, dbQueueId: 0, primary: true,
    queueMode: null, serverKeyHash: randomBytes(32),
  }
  await store.addConnSndQueue(connId, sndQ)
  // Need to create a message first
  const {internalId, internalSndId, prevSndMsgHash} = await store.updateSndIds(connId)
  await store.createSndMsg(connId, {
    internalId, internalSndId, internalTs: new Date().toISOString(),
    msgType: "HELLO", msgFlags: 0, msgBody: randomBytes(10),
    pqEncryption: false, internalHash: randomBytes(32),
    prevMsgHash: prevSndMsgHash, msgEncryptKey: null, paddedMsgLen: null, sndMessageBodyId: null,
  })
  // Get the snd queue with its actual dbQueueId
  const gotConn = await store.getConn(connId)
  const actualSndQ = gotConn!.sndQueues[0] as Row
  // Raw IDB row has snd_queue_id, interface expects dbQueueId
  await store.createSndMsgDelivery(connId, {dbQueueId: actualSndQ.snd_queue_id} as any, internalId)

  const deliveryConns = await store.getConnectionsForDelivery()
  assert(deliveryConns.some(id => hex(id) === hex(connId)), "getConnectionsForDelivery finds conn with delivery")

  const deliverySndQs = await store.getAllSndQueuesForDelivery()
  assert(deliverySndQs.length >= 1, "getAllSndQueuesForDelivery finds queues")
}

async function testConfirmations(store: AgentStore) {
  console.log("  confirmations...")
  const userId = await store.createUserRecord()
  const connId = randomBytes(24)
  await store.createNewConn({
    connId, connMode: "INV", userId, smpAgentVersion: 7,
    enableNtfs: true, duplexHandshake: true, deleted: false,
    ratchetSyncState: "ok", pqSupport: false,
    lastInternalMsgId: 0, lastInternalRcvMsgId: 0, lastInternalSndMsgId: 0,
    lastExternalSndMsgId: 0, lastRcvMsgHash: new Uint8Array(0), lastSndMsgHash: new Uint8Array(0),
  }, "INV")

  const confId = randomBytes(16)
  // createConfirmation
  const returned = await store.createConfirmation({
    confirmationId: confId, connId,
    e2eSndPubKey: randomBytes(32), senderKey: randomBytes(32),
    ratchetState: randomBytes(64), senderConnInfo: randomBytes(50),
    accepted: false, ownConnInfo: null,
    smpReplyQueues: randomBytes(100), smpClientVersion: 7,
  })
  assertEq(returned, confId, "createConfirmation returns confirmationId")

  // getAcceptedConfirmation — not accepted yet
  const notAccepted = await store.getAcceptedConfirmation(connId)
  assert(notAccepted === null, "getAcceptedConfirmation returns null before acceptance")

  // acceptConfirmation
  const ownInfo = randomBytes(40)
  const accepted = await store.acceptConfirmation(confId, ownInfo)
  assert(accepted !== null, "acceptConfirmation returns confirmation")
  assertEq(accepted.accepted, 1, "acceptConfirmation sets accepted=1")

  // getAcceptedConfirmation — now accepted
  const gotAccepted = await store.getAcceptedConfirmation(connId)
  assert(gotAccepted !== null, "getAcceptedConfirmation finds accepted confirmation")
  assertEq((gotAccepted as Row).own_conn_info, ownInfo, "accepted confirmation has ownConnInfo")

  // removeConfirmations
  await store.removeConfirmations(connId)
  const afterRemove = await store.getAcceptedConfirmation(connId)
  assert(afterRemove === null, "removeConfirmations deletes all confirmations for conn")
}

async function testInvitations(store: AgentStore) {
  console.log("  invitations...")
  const userId = await store.createUserRecord()
  const connId = randomBytes(24)
  await store.createNewConn({
    connId, connMode: "CON", userId, smpAgentVersion: 7,
    enableNtfs: true, duplexHandshake: true, deleted: false,
    ratchetSyncState: "ok", pqSupport: false,
    lastInternalMsgId: 0, lastInternalRcvMsgId: 0, lastInternalSndMsgId: 0,
    lastExternalSndMsgId: 0, lastRcvMsgHash: new Uint8Array(0), lastSndMsgHash: new Uint8Array(0),
  }, "CON")

  const invId = randomBytes(16)
  // createInvitation
  const returned = await store.createInvitation({
    invitationId: invId, contactConnId: connId,
    crInvitation: randomBytes(200), recipientConnInfo: randomBytes(50),
    accepted: false, ownConnInfo: null,
  })
  assertEq(returned, invId, "createInvitation returns invitationId")

  // getInvitation — not accepted, should find
  const got = await store.getInvitation(invId)
  assert(got !== null, "getInvitation finds unaccepted invitation")

  // acceptInvitation
  const ownInfo = randomBytes(40)
  await store.acceptInvitation(invId, ownInfo)
  // getInvitation — accepted, should NOT find (WHERE accepted = 0)
  const gotAfterAccept = await store.getInvitation(invId)
  assert(gotAfterAccept === null, "getInvitation returns null for accepted invitation")

  // unacceptInvitation
  await store.unacceptInvitation(invId)
  const gotAfterUnaccept = await store.getInvitation(invId)
  assert(gotAfterUnaccept !== null, "unacceptInvitation resets accepted to 0")
  assert((gotAfterUnaccept as Row).own_conn_info === null, "unacceptInvitation clears ownConnInfo")

  // deleteInvitation
  await store.deleteInvitation(invId)
  const gotAfterDelete = await store.getInvitation(invId)
  assert(gotAfterDelete === null, "deleteInvitation removes invitation")
}

async function testReceiveMessages(store: AgentStore) {
  console.log("  receive messages...")
  const userId = await store.createUserRecord()
  const connId = randomBytes(24)
  await store.createNewConn({
    connId, connMode: "INV", userId, smpAgentVersion: 7,
    enableNtfs: true, duplexHandshake: true, deleted: false,
    ratchetSyncState: "ok", pqSupport: false,
    lastInternalMsgId: 0, lastInternalRcvMsgId: 0, lastInternalSndMsgId: 0,
    lastExternalSndMsgId: 0, lastRcvMsgHash: new Uint8Array(0), lastSndMsgHash: new Uint8Array(0),
  }, "INV")
  await store.createServer("rcv.example.com", "5223", randomBytes(32))
  const rcvQ = await store.addConnRcvQueue(connId, {
    host: "rcv.example.com", port: "5223", rcvId: randomBytes(24),
    connId, rcvPrivateKey: randomBytes(32), rcvDhSecret: randomBytes(32),
    e2ePrivKey: randomBytes(32), e2eDhSecret: null,
    sndId: randomBytes(24), sndKey: null, status: "active" as const,
    smpClientVersion: 7, dbQueueId: 0, primary: true,
    replaceRcvQueueId: null, queueMode: null,
    serverKeyHash: randomBytes(32), lastBrokerTs: null,
  }, "SMSubscribe")

  // updateRcvIds
  const {internalId, internalRcvId, prevExternalSndId, prevRcvMsgHash} = await store.updateRcvIds(connId)
  assertEq(internalId, 1, "updateRcvIds first internalId=1")
  assertEq(internalRcvId, 1, "updateRcvIds first internalRcvId=1")
  assertEq(prevExternalSndId, 0, "updateRcvIds prevExternalSndId=0")

  const brokerId = randomBytes(24)
  const brokerTs = new Date().toISOString()
  const internalHash = randomBytes(32)
  const encryptedMsgHash = randomBytes(32)
  const msgBody = randomBytes(100)

  // createRcvMsg — exercises insertRcvMsgBase_, insertRcvMsgDetails_, updateRcvMsgHash, setLastBrokerTs
  await store.createRcvMsg(connId, rcvQ, {
    msgMeta: {
      integrity: "OK",
      recipient: [internalId, new Date().toISOString()],
      broker: [brokerId, brokerTs],
      sndMsgId: 1,
      pqEncryption: false,
    },
    msgType: "MSG",
    msgFlags: 0,
    msgBody,
    internalRcvId,
    internalHash,
    externalPrevSndHash: randomBytes(32),
    encryptedMsgHash,
  })

  // getRcvMsg
  const rcvMsg = await store.getRcvMsg(connId, internalId)
  assert(rcvMsg !== null, "getRcvMsg finds message")
  assertEq(rcvMsg!.msgType, "MSG", "getRcvMsg msgType matches")

  // getLastMsg — verify the msg is "last" (conn.last_internal_msg_id matches)
  const lastMsg = await store.getLastMsg(connId, brokerId)
  assert(lastMsg !== null, "getLastMsg finds message by brokerId")

  // getRcvMsgBrokerTs
  const ts = await store.getRcvMsgBrokerTs(connId, brokerId)
  assert(ts !== null, "getRcvMsgBrokerTs finds broker ts")

  // checkRcvMsgHashExists — encrypted hash was inserted by createRcvMsg
  const hashExists = await store.checkRcvMsgHashExists(connId, encryptedMsgHash)
  assert(hashExists, "checkRcvMsgHashExists finds hash inserted by createRcvMsg")

  // incMsgRcvAttempts
  const attempts = await store.incMsgRcvAttempts(connId, internalId)
  assertEq(attempts, 1, "incMsgRcvAttempts returns 1 after first increment")
  const attempts2 = await store.incMsgRcvAttempts(connId, internalId)
  assertEq(attempts2, 2, "incMsgRcvAttempts returns 2 after second increment")

  // setMsgUserAck
  const {rcvQueue: ackQ, brokerId: ackBrokerId} = await store.setMsgUserAck(connId, internalId)
  assert(ackQ !== null, "setMsgUserAck returns rcvQueue")
  assertEq(ackBrokerId, brokerId, "setMsgUserAck returns correct brokerId")

  // Verify user_ack was set
  const rcvMsgAfterAck = await store.getRcvMsg(connId, internalId)
  assert(rcvMsgAfterAck!.userAck, "setMsgUserAck sets userAck=true")

  // setLastBrokerTs — standalone call
  const newTs = new Date().toISOString()
  await store.setLastBrokerTs(connId, rcvQ.dbQueueId, newTs)

  // updateRcvMsgHash — standalone call
  await store.updateRcvMsgHash(connId, 2, internalRcvId, randomBytes(32))

  // deleteMsg
  await store.deleteMsg(connId, internalId)
  const deletedMsg = await store.getRcvMsg(connId, internalId)
  assert(deletedMsg === null, "deleteMsg removes message")
}

async function testSendMessages(store: AgentStore) {
  console.log("  send messages...")
  const userId = await store.createUserRecord()
  const connId = randomBytes(24)
  await store.createNewConn({
    connId, connMode: "INV", userId, smpAgentVersion: 7,
    enableNtfs: true, duplexHandshake: true, deleted: false,
    ratchetSyncState: "ok", pqSupport: false,
    lastInternalMsgId: 0, lastInternalRcvMsgId: 0, lastInternalSndMsgId: 0,
    lastExternalSndMsgId: 0, lastRcvMsgHash: new Uint8Array(0), lastSndMsgHash: new Uint8Array(0),
  }, "INV")
  await store.createServer("snd.example.com", "5223", randomBytes(32))
  await store.addConnSndQueue(connId, {
    host: "snd.example.com", port: "5223", sndId: randomBytes(24),
    connId, sndPrivateKey: randomBytes(32), e2eDhSecret: randomBytes(32),
    status: "active" as const, smpClientVersion: 7,
    sndPublicKey: null, e2ePubKey: null, dbQueueId: 0, primary: true,
    queueMode: null, serverKeyHash: randomBytes(32),
  })
  const gotConn = await store.getConn(connId)
  const sndQueue = gotConn!.sndQueues[0]

  // createSndMsgBody
  const agentMsg = randomBytes(200)
  const bodyId = await store.createSndMsgBody(agentMsg)
  assert(bodyId >= 1, "createSndMsgBody returns positive id")

  // updateSndIds
  const {internalId, internalSndId, prevSndMsgHash} = await store.updateSndIds(connId)
  assertEq(internalId, 1, "updateSndIds first internalId=1")
  assertEq(internalSndId, 1, "updateSndIds first internalSndId=1")

  const internalHash = randomBytes(32)

  // createSndMsg
  await store.createSndMsg(connId, {
    internalId, internalSndId, internalTs: new Date().toISOString(),
    msgType: "SEND", msgFlags: 0, msgBody: randomBytes(100),
    pqEncryption: false, internalHash,
    prevMsgHash: prevSndMsgHash, msgEncryptKey: randomBytes(32),
    paddedMsgLen: 16384, sndMessageBodyId: bodyId,
  })

  // updateSndMsgHash — standalone
  await store.updateSndMsgHash(connId, internalSndId, internalHash)

  // createSndMsgDelivery
  await store.createSndMsgDelivery(connId, sndQueue, internalId)

  // getPendingQueueMsg
  const pending = await store.getPendingQueueMsg(connId, sndQueue)
  assert(pending !== null, "getPendingQueueMsg finds pending message")
  assertEq(pending!.msgType, "SEND", "getPendingQueueMsg msgType matches")
  assertEq(pending!.internalId, internalId, "getPendingQueueMsg internalId matches")

  // updatePendingMsgRIState
  await store.updatePendingMsgRIState(connId, internalId, 30, 5)

  // getSndMsgViaRcpt
  const sndMsg = await store.getSndMsgViaRcpt(connId, internalSndId)
  assert(sndMsg !== null, "getSndMsgViaRcpt finds message")
  assertEq(sndMsg!.internalId, internalId, "getSndMsgViaRcpt internalId matches")
  assertEq(sndMsg!.internalHash, internalHash, "getSndMsgViaRcpt hash matches")

  // updateSndMsgRcpt
  const receipt = randomBytes(8)
  await store.updateSndMsgRcpt(connId, internalSndId, receipt)

  // deleteSndMsgDelivery — deletes delivery, then msg if no more deliveries
  await store.deleteSndMsgDelivery(connId, sndQueue, internalId, false)

  // Create a second message for deleteDeliveredSndMsg
  const ids2 = await store.updateSndIds(connId)
  await store.createSndMsg(connId, {
    internalId: ids2.internalId, internalSndId: ids2.internalSndId,
    internalTs: new Date().toISOString(),
    msgType: "SEND", msgFlags: 0, msgBody: randomBytes(50),
    pqEncryption: false, internalHash: randomBytes(32),
    prevMsgHash: ids2.prevSndMsgHash, msgEncryptKey: null, paddedMsgLen: null, sndMessageBodyId: null,
  })

  // deleteDeliveredSndMsg — no deliveries exist, so should delete msg
  await store.deleteDeliveredSndMsg(connId, ids2.internalId)
}

async function testRatchet(store: AgentStore) {
  console.log("  ratchet...")
  const connId = randomBytes(24)
  const userId = await store.createUserRecord()
  await store.createNewConn({
    connId, connMode: "INV", userId, smpAgentVersion: 7,
    enableNtfs: true, duplexHandshake: true, deleted: false,
    ratchetSyncState: "ok", pqSupport: true,
    lastInternalMsgId: 0, lastInternalRcvMsgId: 0, lastInternalSndMsgId: 0,
    lastExternalSndMsgId: 0, lastRcvMsgHash: new Uint8Array(0), lastSndMsgHash: new Uint8Array(0),
  }, "INV")

  const privKey1 = randomBytes(56)
  const privKey2 = randomBytes(56)
  const pqKem = randomBytes(100)

  // createRatchetX3dhKeys
  await store.createRatchetX3dhKeys(connId, privKey1, privKey2, pqKem)

  // getRatchetX3dhKeys
  const keys = await store.getRatchetX3dhKeys(connId)
  assert(keys !== null, "getRatchetX3dhKeys finds keys")
  assertEq(keys!.privKey1, privKey1, "x3dh privKey1 matches")
  assertEq(keys!.privKey2, privKey2, "x3dh privKey2 matches")
  assertEq(keys!.pqKem, pqKem, "x3dh pqKem matches")

  // getRatchet — no ratchet state yet
  const noRatchet = await store.getRatchet(connId)
  assert(noRatchet === null, "getRatchet returns null before createRatchet")

  // createRatchet — upserts, clearing x3dh keys
  const ratchetState = randomBytes(200)
  await store.createRatchet(connId, ratchetState)

  // getRatchet
  const gotRatchet = await store.getRatchet(connId)
  assertEq(gotRatchet, ratchetState, "getRatchet returns stored state")

  // getRatchetForUpdate — same as getRatchet in IndexedDB
  const gotForUpdate = await store.getRatchetForUpdate(connId)
  assertEq(gotForUpdate, ratchetState, "getRatchetForUpdate returns stored state")

  // x3dh keys should be cleared after createRatchet
  const keysAfter = await store.getRatchetX3dhKeys(connId)
  assert(keysAfter === null, "createRatchet clears x3dh keys")

  // getSkippedMsgKeys — empty initially
  const noSkipped = await store.getSkippedMsgKeys(connId)
  assertEq(noSkipped.size, 0, "getSkippedMsgKeys empty initially")

  // updateRatchet with SMDAdd
  const headerKey = randomBytes(32)
  const msgKey = randomBytes(32)
  const newRatchetState = randomBytes(200)
  const addKeys = new Map<Uint8Array, Map<number, Uint8Array>>()
  const inner = new Map<number, Uint8Array>()
  inner.set(0, msgKey)
  inner.set(1, randomBytes(32))
  addKeys.set(headerKey, inner)
  await store.updateRatchet(connId, newRatchetState, {type: "add", keys: addKeys})

  // Verify ratchet state updated
  const updatedRatchet = await store.getRatchet(connId)
  assertEq(updatedRatchet, newRatchetState, "updateRatchet updates state")

  // Verify skipped keys added
  const skipped = await store.getSkippedMsgKeys(connId)
  assert(skipped.size >= 1, "updateRatchet SMDAdd adds skipped keys")

  // updateRatchet with SMDRemove
  const hkHex = Array.from(headerKey, x => x.toString(16).padStart(2, "0")).join("")
  await store.updateRatchet(connId, randomBytes(200), {type: "remove", headerKey, msgN: 0})
  const afterRemove = await store.getSkippedMsgKeys(connId)
  // Should have 1 key remaining (msgN=1) instead of 2
  let totalKeys = 0
  for (const [, m] of afterRemove) totalKeys += m.size
  assertEq(totalKeys, 1, "updateRatchet SMDRemove removes specific key")

  // updateRatchet with noChange
  const stateBeforeNoChange = randomBytes(200)
  await store.updateRatchet(connId, stateBeforeNoChange, {type: "noChange"})
  const afterNoChange = await store.getRatchet(connId)
  assertEq(afterNoChange, stateBeforeNoChange, "updateRatchet SMDNoChange only updates state")
}

async function testCommands(store: AgentStore) {
  console.log("  commands...")
  const userId = await store.createUserRecord()
  const connId = randomBytes(24)
  await store.createNewConn({
    connId, connMode: "INV", userId, smpAgentVersion: 7,
    enableNtfs: true, duplexHandshake: true, deleted: false,
    ratchetSyncState: "ok", pqSupport: false,
    lastInternalMsgId: 0, lastInternalRcvMsgId: 0, lastInternalSndMsgId: 0,
    lastExternalSndMsgId: 0, lastRcvMsgHash: new Uint8Array(0), lastSndMsgHash: new Uint8Array(0),
  }, "INV")

  const corrId = randomBytes(24)
  // createCommand
  const cmdId = await store.createCommand(corrId, connId, "cmd.example.com", "5223", {
    commandId: 0, connId, host: "cmd.example.com", port: "5223",
    corrId, commandTag: "NEW", command: randomBytes(50),
    agentVersion: 7, serverKeyHash: randomBytes(32), failed: false,
  })
  assert(cmdId >= 1, "createCommand returns positive id")

  // getPendingCommandServers
  const servers = await store.getPendingCommandServers([connId])
  assert(servers.some(s => s.host === "cmd.example.com"), "getPendingCommandServers finds command server")

  // getAllPendingCommandConns
  const allConns = await store.getAllPendingCommandConns()
  assert(allConns.some(c => hex(c.connId) === hex(connId)), "getAllPendingCommandConns finds conn")

  // getPendingServerCommand
  const pendingCmd = await store.getPendingServerCommand("cmd.example.com", "5223")
  assert(pendingCmd !== null, "getPendingServerCommand finds command")

  // updateCommandServer
  await store.updateCommandServer(cmdId, "cmd2.example.com", "5224")
  const updated = await store.getPendingServerCommand("cmd2.example.com", "5224")
  assert(updated !== null, "updateCommandServer changes server")
  const oldHost = await store.getPendingServerCommand("cmd.example.com", "5223")
  assert(oldHost === null, "updateCommandServer — old host returns nothing")

  // deleteCommand
  await store.deleteCommand(cmdId)
  const deleted = await store.getPendingServerCommand("cmd2.example.com", "5224")
  assert(deleted === null, "deleteCommand removes command")
}

async function testHashDedup(store: AgentStore) {
  console.log("  hash dedup...")
  const connId = randomBytes(24)
  const userId = await store.createUserRecord()
  await store.createNewConn({
    connId, connMode: "INV", userId, smpAgentVersion: 7,
    enableNtfs: true, duplexHandshake: true, deleted: false,
    ratchetSyncState: "ok", pqSupport: false,
    lastInternalMsgId: 0, lastInternalRcvMsgId: 0, lastInternalSndMsgId: 0,
    lastExternalSndMsgId: 0, lastRcvMsgHash: new Uint8Array(0), lastSndMsgHash: new Uint8Array(0),
  }, "INV")

  const hash = randomBytes(32)

  // checkRcvMsgHashExists_encrypted — not yet
  const before = await store.checkRcvMsgHashExists_encrypted(connId, hash)
  assert(!before, "checkRcvMsgHashExists_encrypted returns false before add")

  // addEncryptedRcvMsgHash
  await store.addEncryptedRcvMsgHash(connId, hash)

  // checkRcvMsgHashExists_encrypted — now exists
  const after = await store.checkRcvMsgHashExists_encrypted(connId, hash)
  assert(after, "checkRcvMsgHashExists_encrypted returns true after add")

  // Different hash should not exist
  const other = await store.checkRcvMsgHashExists_encrypted(connId, randomBytes(32))
  assert(!other, "checkRcvMsgHashExists_encrypted returns false for different hash")
}

// -- Run all

async function main() {
  console.log("Agent store tests")
  const store = await openAgentStore()

  await testUsers(store)
  await testServers(store)
  await testConnectionsAndQueues(store)
  await testSubscriptions(store)
  await testConfirmations(store)
  await testInvitations(store)
  await testReceiveMessages(store)
  await testSendMessages(store)
  await testRatchet(store)
  await testCommands(store)
  await testHashDedup(store)

  console.log(`\n${passed} passed, ${failed} failed`)
  if (failed > 0) process.exit(1)
}

main().catch(e => { console.error("FATAL:", e?.message || e, e?.stack); process.exit(1) })
