// XFTP HTTP/2 client — Simplex.FileTransfer.Client
//
// Connects to XFTP server via HTTP/2, performs web handshake,
// sends authenticated commands, receives responses.

import http2 from "node:http2"
import crypto from "node:crypto"
import {
  encodeAuthTransmission, encodeTransmission, decodeTransmission,
  XFTP_BLOCK_SIZE, initialXFTPVersion, currentXFTPVersion
} from "./protocol/transmission.js"
import {
  encodeClientHello, encodeClientHandshake, decodeServerHandshake,
  compatibleVRange
} from "./protocol/handshake.js"
import {verifyIdentityProof} from "./crypto/identity.js"
import {generateX25519KeyPair, encodePubKeyX25519, dh} from "./crypto/keys.js"
import {
  encodeFNEW, encodeFADD, encodeFPUT, encodeFGET, encodeFDEL, encodeFACK, encodePING,
  decodeResponse, type FileResponse, type FileInfo
} from "./protocol/commands.js"
import {decryptReceivedChunk} from "./download.js"
import type {XFTPServer} from "./protocol/address.js"

// ── Types ─────────────────────────────────────────────────────────

export interface XFTPClient {
  session: http2.ClientHttp2Session
  sessionId: Uint8Array
  xftpVersion: number
}

// ── HTTP/2 helpers ────────────────────────────────────────────────

function h2Request(
  session: http2.ClientHttp2Session,
  body: Uint8Array,
  extraBody?: Uint8Array
): Promise<Uint8Array> {
  return new Promise((resolve, reject) => {
    const stream = session.request({":method": "POST", ":path": "/"})
    const chunks: Buffer[] = []
    stream.on("data", (d: Buffer) => chunks.push(d))
    stream.on("end", () => resolve(new Uint8Array(Buffer.concat(chunks))))
    stream.on("error", reject)
    if (extraBody) {
      stream.write(Buffer.from(body))
      stream.end(Buffer.from(extraBody))
    } else {
      stream.end(Buffer.from(body))
    }
  })
}

function readBody(stream: http2.ClientHttp2Stream): Promise<Uint8Array> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = []
    stream.on("data", (d: Buffer) => chunks.push(d))
    stream.on("end", () => resolve(new Uint8Array(Buffer.concat(chunks))))
    stream.on("error", reject)
  })
}

// ── Connect + handshake ───────────────────────────────────────────

export async function connectXFTP(server: XFTPServer): Promise<XFTPClient> {
  const session = http2.connect(
    "https://" + server.host + ":" + server.port,
    {rejectUnauthorized: false}
  )

  // Step 1: send client hello with web challenge
  const challenge = new Uint8Array(crypto.randomBytes(32))
  const s1 = session.request({":method": "POST", ":path": "/"})
  s1.end(Buffer.from(encodeClientHello({webChallenge: challenge})))
  const shsBody = await readBody(s1)

  // Step 2: decode + verify server handshake
  const hs = decodeServerHandshake(shsBody)
  if (!hs.webIdentityProof) throw new Error("connectXFTP: no web identity proof")
  const idOk = verifyIdentityProof({
    certChainDer: hs.certChainDer,
    signedKeyDer: hs.signedKeyDer,
    sigBytes: hs.webIdentityProof,
    challenge,
    sessionId: hs.sessionId,
    keyHash: server.keyHash
  })
  if (!idOk) throw new Error("connectXFTP: identity verification failed")

  // Step 3: version negotiation
  const vr = compatibleVRange(hs.xftpVersionRange, {minVersion: initialXFTPVersion, maxVersion: currentXFTPVersion})
  if (!vr) throw new Error("connectXFTP: incompatible version")
  const xftpVersion = vr.maxVersion

  // Step 4: send client handshake
  const s2 = session.request({":method": "POST", ":path": "/"})
  s2.end(Buffer.from(encodeClientHandshake({xftpVersion, keyHash: server.keyHash})))
  const ack = await readBody(s2)
  if (ack.length !== 0) throw new Error("connectXFTP: non-empty handshake ack")

  return {session, sessionId: hs.sessionId, xftpVersion}
}

// ── Send command ──────────────────────────────────────────────────

async function sendXFTPCommand(
  client: XFTPClient,
  privateKey: Uint8Array,
  entityId: Uint8Array,
  cmdBytes: Uint8Array,
  chunkData?: Uint8Array
): Promise<{response: FileResponse, body: Uint8Array}> {
  const corrId = new Uint8Array(0)
  const block = encodeAuthTransmission(client.sessionId, corrId, entityId, cmdBytes, privateKey)
  const fullResp = await h2Request(client.session, block, chunkData)
  if (fullResp.length < XFTP_BLOCK_SIZE) throw new Error("sendXFTPCommand: response too short")
  const respBlock = fullResp.subarray(0, XFTP_BLOCK_SIZE)
  const body = fullResp.subarray(XFTP_BLOCK_SIZE)
  const {command} = decodeTransmission(client.sessionId, respBlock)
  const response = decodeResponse(command)
  if (response.type === "FRErr") throw new Error("XFTP error: " + response.err.type)
  return {response, body}
}

// ── Command wrappers ──────────────────────────────────────────────

export async function createXFTPChunk(
  c: XFTPClient, spKey: Uint8Array, file: FileInfo,
  rcvKeys: Uint8Array[], auth: Uint8Array | null = null
): Promise<{senderId: Uint8Array, recipientIds: Uint8Array[]}> {
  const {response} = await sendXFTPCommand(c, spKey, new Uint8Array(0), encodeFNEW(file, rcvKeys, auth))
  if (response.type !== "FRSndIds") throw new Error("unexpected response: " + response.type)
  return {senderId: response.senderId, recipientIds: response.recipientIds}
}

export async function addXFTPRecipients(
  c: XFTPClient, spKey: Uint8Array, fId: Uint8Array, rcvKeys: Uint8Array[]
): Promise<Uint8Array[]> {
  const {response} = await sendXFTPCommand(c, spKey, fId, encodeFADD(rcvKeys))
  if (response.type !== "FRRcvIds") throw new Error("unexpected response: " + response.type)
  return response.recipientIds
}

export async function uploadXFTPChunk(
  c: XFTPClient, spKey: Uint8Array, fId: Uint8Array, chunkData: Uint8Array
): Promise<void> {
  const {response} = await sendXFTPCommand(c, spKey, fId, encodeFPUT(), chunkData)
  if (response.type !== "FROk") throw new Error("unexpected response: " + response.type)
}

export async function downloadXFTPChunk(
  c: XFTPClient, rpKey: Uint8Array, fId: Uint8Array, digest?: Uint8Array
): Promise<Uint8Array> {
  const {publicKey, privateKey} = generateX25519KeyPair()
  const cmd = encodeFGET(encodePubKeyX25519(publicKey))
  const {response, body} = await sendXFTPCommand(c, rpKey, fId, cmd)
  if (response.type !== "FRFile") throw new Error("unexpected response: " + response.type)
  const dhSecret = dh(response.rcvDhKey, privateKey)
  return decryptReceivedChunk(dhSecret, response.nonce, body, digest ?? null)
}

export async function deleteXFTPChunk(
  c: XFTPClient, spKey: Uint8Array, sId: Uint8Array
): Promise<void> {
  const {response} = await sendXFTPCommand(c, spKey, sId, encodeFDEL())
  if (response.type !== "FROk") throw new Error("unexpected response: " + response.type)
}

export async function ackXFTPChunk(
  c: XFTPClient, rpKey: Uint8Array, rId: Uint8Array
): Promise<void> {
  const {response} = await sendXFTPCommand(c, rpKey, rId, encodeFACK())
  if (response.type !== "FROk") throw new Error("unexpected response: " + response.type)
}

export async function pingXFTP(c: XFTPClient): Promise<void> {
  const corrId = new Uint8Array(0)
  const block = encodeTransmission(c.sessionId, corrId, new Uint8Array(0), encodePING())
  const fullResp = await h2Request(c.session, block)
  if (fullResp.length < XFTP_BLOCK_SIZE) throw new Error("pingXFTP: response too short")
  const {command} = decodeTransmission(c.sessionId, fullResp.subarray(0, XFTP_BLOCK_SIZE))
  const response = decodeResponse(command)
  if (response.type !== "FRPong") throw new Error("unexpected response: " + response.type)
}

// ── Close ─────────────────────────────────────────────────────────

export function closeXFTP(c: XFTPClient): void {
  c.session.close()
}
