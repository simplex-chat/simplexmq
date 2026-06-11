// SMP session management and queue operations.
// Transpilation of Agent/Client.hs: getSMPServerClient, agentCbEncrypt/Decrypt,
// sendConfirmation, sendAgentMessage, newRcvQueue, subscribeQueues, etc.

import type {SMPClient, ProxiedRelay} from "../client.js"
import {createSMPClient} from "../client.js"
import type {AuthKey, SMPResponse} from "../protocol.js"
import {
  encodeClientMsgEnvelope, encodeClientMessage,
  type ClientMsgEnvelope, type ClientMessage, type PubHeader, type PrivHeader,
} from "../protocol.js"
import {getSessVar, removeSessVar, tryReadSessVar, type SessionVar} from "./session.js"
import {AgentError, type AgentClient, type AgentErrorType} from "./client.js"
import {ABQueue} from "./queue.js"
import type {RcvQueueSub} from "./subscriptions.js"
import {cbEncrypt, cbDecrypt} from "@simplex-chat/xftp-web/dist/crypto/secretbox.js"
import {generateX25519KeyPair, generateEd25519KeyPair, dh, encodePubKeyX25519, encodePubKeyEd25519} from "@simplex-chat/xftp-web/dist/crypto/keys.js"
import {concatBytes, encodeBytes} from "@simplex-chat/xftp-web/dist/protocol/encoding.js"

// -- Transport session key (simplified: one session per server, no TSMEntity)

export function tSessKey(userId: number, server: string): string {
  return `${userId}:${server}`
}

// -- SMP connected client with proxy relay sessions

export interface SMPConnectedClient {
  client: SMPClient
  proxiedRelays: Map<string, SessionVar<ProxiedRelay | AgentErrorType>>
}

// -- Server message for msgQ (dispatched by subscriber loop)

export interface ServerMsg {
  userId: number
  server: string
  sessionId: Uint8Array
  entityId: Uint8Array
  msg: SMPResponse
}

// -- getSMPServerClient (Client.hs:642-651)
// Get or create SMP client for the given server.
// Returns existing if connected, waits if pending, connects if new.
export async function getSMPServerClient(
  c: AgentClient,
  userId: number,
  server: string,
  keyHash: Uint8Array,
  wsUrl: string,
): Promise<SMPConnectedClient> {
  if (!c.active) throw new AgentError({tag: "INACTIVE"})
  const key = tSessKey(userId, server)
  const clients = c.smpClients as Map<string, SessionVar<SMPConnectedClient>>
  const {isNew, v} = getSessVar(c.workerSeq, key, clients)
  if (isNew) {
    return smpConnectClient(c, userId, server, keyHash, wsUrl, key, v)
  }
  return waitForSMPClient(server, v)
}

// smpConnectClient (Client.hs:704-718)
async function smpConnectClient(
  c: AgentClient,
  userId: number,
  server: string,
  keyHash: Uint8Array,
  wsUrl: string,
  key: string,
  v: SessionVar<SMPConnectedClient>,
): Promise<SMPConnectedClient> {
  const clients = c.smpClients as Map<string, SessionVar<SMPConnectedClient>>
  try {
    const smp = await createSMPClient(
      wsUrl, keyHash,
      // onMessage (Client.hs:716 — messages go to msgQ)
      (entityId: Uint8Array, msg: SMPResponse) => {
        const serverMsg: ServerMsg = {userId, server, sessionId: smp.sessionId, entityId, msg}
        c.msgQ.enqueue(serverMsg)
      },
      // onDisconnected (Client.hs:720-754 — smpClientDisconnected)
      () => smpClientDisconnected(c, userId, server, key, v, smp),
    )
    // setSessionId in subscription tracker (Client.hs:717)
    c.currentSubs.setSessionId(tSessKey(userId, server), smp.sessionId)
    const connected: SMPConnectedClient = {client: smp, proxiedRelays: new Map()}
    v.resolve(connected)
    // Notify CONNECT (Client.hs:884)
    c.subQ.enqueue(["", new Uint8Array(0), {tag: "CONNECT", server}])
    return connected
  } catch (e) {
    // Connection failed (Client.hs:886-895)
    removeSessVar(v, key, clients)
    v.reject(e instanceof Error ? e : new Error(String(e)))
    throw new AgentError({tag: "BROKER", addr: server, err: "NETWORK"})
  }
}

// waitForProtocolClient (Client.hs:847-868)
async function waitForSMPClient(
  server: string,
  v: SessionVar<SMPConnectedClient>,
): Promise<SMPConnectedClient> {
  try {
    return await v.promise
  } catch {
    throw new AgentError({tag: "BROKER", addr: server, err: "NETWORK"})
  }
}

// smpClientDisconnected (Client.hs:720-754)
// Handle WebSocket disconnect: move subs to pending, notify DOWN, remove client.
function smpClientDisconnected(
  c: AgentClient,
  userId: number,
  server: string,
  key: string,
  v: SessionVar<SMPConnectedClient>,
  smp: SMPClient,
): void {
  const clients = c.smpClients as Map<string, SessionVar<SMPConnectedClient>>
  // removeSessVar (only if this is still the current client)
  removeSessVar(v, key, clients)
  if (!c.active) return
  // Move active subs to pending (Client.hs:731-737)
  const tSess = tSessKey(userId, server)
  const moved = c.currentSubs.setSubsPending(tSess, smp.sessionId)
  // Notify DISCONNECT (Client.hs:746)
  c.subQ.enqueue(["", new Uint8Array(0), {tag: "DISCONNECT", server}])
  if (moved.size > 0) {
    // Notify DOWN with affected connIds (Client.hs:747)
    const connIds = [...new Set([...moved.values()].map(rq => toHex(rq.connId)))]
    c.subQ.enqueue(["", new Uint8Array(0), {tag: "DOWN", server, connIds}])
    // TODO: trigger resubscription (Client.hs:750-754)
  }
}

// -- agentCbEncrypt (Client.hs:2074-2082)
// Per-queue E2E encrypt with stored DH secret.
// e2ePubKey is the RAW 32-byte X25519 public key (or null for messages).
// Haskell smpEncode of PubHeader's `Maybe C.PublicKeyX25519` DER-encodes the key
// (Crypto.hs:568-570), so we DER-encode it before placing it in the header.
// Returns encoded ClientMsgEnvelope.
export function agentCbEncrypt(
  e2eDhSecret: Uint8Array,
  smpClientVersion: number,
  e2ePubKey: Uint8Array | null,
  msg: Uint8Array,
): Uint8Array {
  const cmNonce = crypto.getRandomValues(new Uint8Array(24))
  // paddedLen: e2eEncConfirmationLength (15904) for confirmations, e2eEncMessageLength (16000) for messages
  // Protocol.hs:316-320
  const paddedLen = e2ePubKey !== null ? 15904 : 16000
  const cmEncBody = cbEncrypt(e2eDhSecret, cmNonce, msg, paddedLen)
  const env: ClientMsgEnvelope = {
    cmHeader: {phVersion: smpClientVersion, phE2ePubDhKey: e2ePubKey !== null ? encodePubKeyX25519(e2ePubKey) : null},
    cmNonce,
    cmEncBody,
  }
  return encodeClientMsgEnvelope(env)
}

// agentCbEncryptOnce (Client.hs:2085-2095)
// Per-queue E2E encrypt with ephemeral DH key (for invitations).
export function agentCbEncryptOnce(
  clientVersion: number,
  dhRcvPubKey: Uint8Array,
  msg: Uint8Array,
): Uint8Array {
  const {publicKey: dhSndPubKey, privateKey: dhSndPrivKey} = generateX25519KeyPair()
  const e2eDhSecret = dh(dhRcvPubKey, dhSndPrivKey)
  return agentCbEncrypt(e2eDhSecret, clientVersion, dhSndPubKey, msg)
}

// agentCbDecrypt (Client.hs:2099-2102)
export function agentCbDecrypt(
  dhSecret: Uint8Array,
  nonce: Uint8Array,
  msg: Uint8Array,
): Uint8Array {
  const result = cbDecrypt(dhSecret, nonce, msg)
  if (result === null) throw new AgentError({tag: "AGENT", err: {tag: "A_CRYPTO", err: "DECRYPT_CB"}})
  return result
}

// -- sendAgentMessage (Client.hs:1948-1952)
// Per-queue E2E encrypt message + SEND.
// sq is raw IDB SndQueue row.
export async function sendAgentMessage(
  c: AgentClient,
  sq: any,
  msgFlags: {notification: boolean},
  agentMsg: Uint8Array,
): Promise<void> {
  const clientMsg: ClientMessage = {privHeader: {type: "PHEmpty"}, body: agentMsg}
  const msg = agentCbEncrypt(sq.e2e_dh_secret, sq.smp_client_version, null, encodeClientMessage(clientMsg))
  const smp = await getClientForQueue(c, sq)
  const privKey: AuthKey = {type: "ed25519", key: sq.snd_private_key}
  await smp.sendMessage(privKey, sq.snd_id, msgFlags.notification, msg)
}

// sendConfirmation (Client.hs:1788-1794)
export async function sendConfirmation(
  c: AgentClient,
  sq: any,
  agentConfirmation: Uint8Array,
): Promise<void> {
  if (!sq.e2e_pub_key) throw new AgentError({tag: "INTERNAL", msg: "sendConfirmation: no e2e pub key"})
  const senderCanSecure_ = sq.queue_mode === "M"
  // PHConfirmation carries C.toPublic sndPrivateKey, DER-encoded by smpEncode (Crypto.hs:568-570).
  // (Only used for non-messaging queues; messaging queues use PHEmpty.)
  const privHeader: PrivHeader = senderCanSecure_
    ? {type: "PHEmpty"}
    : {type: "PHConfirmation", key: encodePubKeyEd25519(toPublicEd25519(sq.snd_private_key))}
  const spKey: AuthKey | null = senderCanSecure_ ? {type: "ed25519", key: sq.snd_private_key} : null
  const clientMsg: ClientMessage = {privHeader, body: agentConfirmation}
  const msg = agentCbEncrypt(sq.e2e_dh_secret, sq.smp_client_version, sq.e2e_pub_key, encodeClientMessage(clientMsg))
  const smp = await getClientForQueue(c, sq)
  await smp.sendMessage(spKey, sq.snd_id, true, msg)
}

// secureQueue (Client.hs:1830-1833)
export async function secureQueue(
  c: AgentClient,
  rq: any,
  senderKey: Uint8Array,
): Promise<void> {
  const smp = await getClientForQueue(c, rq)
  await smp.secureQueue({type: "ed25519", key: rq.rcv_private_key}, rq.rcv_id, senderKey)
}

// secureSndQueue (Client.hs:1835-1841)
export async function secureSndQueue(
  c: AgentClient,
  sq: any,
): Promise<void> {
  const smp = await getClientForQueue(c, sq)
  await smp.secureSndQueue({type: "ed25519", key: sq.snd_private_key}, sq.snd_id)
}

// sendAck (Client.hs:1904-1907)
export async function sendAck(
  c: AgentClient,
  rq: any,
  msgId: Uint8Array,
): Promise<void> {
  const smp = await getClientForQueue(c, rq)
  await smp.ackMessage({type: "ed25519", key: rq.rcv_private_key}, rq.rcv_id, msgId)
}

// -- subscribeQueues (Client.hs:1543-1556)
export async function subscribeQueues(
  c: AgentClient,
  userId: number,
  queues: RcvQueueSub[],
): Promise<void> {
  const byServer = new Map<string, RcvQueueSub[]>()
  for (const q of queues) {
    const list = byServer.get(q.server) ?? []
    list.push(q)
    byServer.set(q.server, list)
  }
  for (const [server, qs] of byServer) {
    c.currentSubs.batchAddPendingSubs(tSessKey(userId, server), qs)
  }
  for (const [server, qs] of byServer) {
    await subscribeServerQueues(c, userId, server, qs)
  }
}

async function subscribeServerQueues(
  c: AgentClient,
  userId: number,
  server: string,
  queues: RcvQueueSub[],
): Promise<void> {
  const key = tSessKey(userId, server)
  const existing = tryReadSessVar(key, c.smpClients as Map<string, SessionVar<SMPConnectedClient>>)
  if (!existing) return
  const smp = existing.client
  const subReqs = queues.map(q => ({rcvId: q.rcvId, privKey: {type: "ed25519" as const, key: q.rcvPrivateKey}}))
  try {
    await smp.subscribeQueues(subReqs)
    c.currentSubs.batchAddActiveSubs(key, smp.sessionId, queues)
  } catch {
    // On error, subs stay pending
  }
}

// addNewQueueSubscription (Client.hs:1724-1728)
export function addNewQueueSubscription(
  c: AgentClient,
  rq: RcvQueueSub,
  userId: number,
  server: string,
  sessionId: Uint8Array,
): void {
  c.currentSubs.addActiveSub(tSessKey(userId, server), sessionId, rq)
}

// -- newRcvQueue (Client.hs:1373-1435, simplified: no short links, no ntf credentials)

export interface NewRcvQueueResult {
  rcvQueue: any
  sndId: Uint8Array
  e2eDhKey: Uint8Array
  sessionId: Uint8Array
}

export async function newRcvQueue(
  c: AgentClient,
  userId: number,
  connId: Uint8Array,
  server: string,
  keyHash: Uint8Array,
  wsUrl: string,
  subscribe: boolean,
): Promise<NewRcvQueueResult> {
  const {publicKey: rcvPubKey, privateKey: rcvPrivateKey} = generateEd25519KeyPair()
  const {publicKey: dhPubKey, privateKey: dhPrivKey} = generateX25519KeyPair()
  const {publicKey: e2eDhKey, privateKey: e2ePrivKey} = generateX25519KeyPair()

  const smpConn = await getSMPServerClient(c, userId, server, keyHash, wsUrl)
  const smp = smpConn.client

  const ids = await smp.createQueue({publicKey: rcvPubKey, privateKey: rcvPrivateKey}, dhPubKey, subscribe)

  const rcvDhSecret = dh(ids.srvDhKey, dhPrivKey)
  const rcvQueue = {
    host: server, port: "443",
    rcv_id: ids.rcvId,
    conn_id: connId,
    rcv_private_key: rcvPrivateKey,
    rcv_dh_secret: rcvDhSecret,
    e2e_priv_key: e2ePrivKey,
    e2e_dh_secret: null,
    snd_id: ids.sndId,
    snd_key: null,
    status: "new",
    // Haskell newRcvQueue_: smpClientVersion = maxVersion vRange (= maxVersion smpClientVRange).
    // This is VersionSMPC (used in the per-queue PubHeader), NOT the SMP transport version.
    smp_client_version: c.config.smpClientVRange[1],
    rcv_queue_id: 0,
    rcv_primary: 1,
    replace_rcv_queue_id: null,
    queue_mode: ids.queueMode,
    server_key_hash: keyHash,
    last_broker_ts: null,
    to_subscribe: subscribe ? 0 : 1,
    deleted: 0,
  }

  return {rcvQueue, sndId: ids.sndId, e2eDhKey, sessionId: smp.sessionId}
}

// -- Helpers

async function getClientForQueue(c: AgentClient, q: any): Promise<SMPClient> {
  const clients = c.smpClients as Map<string, SessionVar<SMPConnectedClient>>
  for (const [key, sv] of clients) {
    if (sv.value && key.endsWith(":" + q.host)) return sv.value.client
  }
  throw new AgentError({tag: "INTERNAL", msg: "no SMP client for " + q.host})
}

// Ed25519 public key from 64-byte private key (NaCl convention: last 32 bytes)
function toPublicEd25519(privateKey: Uint8Array): Uint8Array {
  return privateKey.slice(32, 64)
}

function toHex(b: Uint8Array): string {
  return Array.from(b, x => x.toString(16).padStart(2, "0")).join("")
}
