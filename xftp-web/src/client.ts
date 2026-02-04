// XFTP HTTP/2 client — Simplex.FileTransfer.Client
//
// Connects to XFTP server via HTTP/2, performs web handshake,
// sends authenticated commands, receives responses.
//
// Uses node:http2 in Node.js (tests), fetch() in browsers.

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
import {concatBytes} from "./protocol/encoding.js"

// ── Types ─────────────────────────────────────────────────────────

export interface XFTPClient {
  baseUrl: string
  sessionId: Uint8Array
  xftpVersion: number
  transport: Transport
}

interface Transport {
  post(body: Uint8Array): Promise<Uint8Array>
  close(): void
}

// ── Transport implementations ─────────────────────────────────────

const isNode = typeof globalThis.process !== "undefined" && globalThis.process.versions?.node

async function createTransport(baseUrl: string): Promise<Transport> {
  if (isNode) {
    return createNodeTransport(baseUrl)
  } else {
    return createBrowserTransport(baseUrl)
  }
}

async function createNodeTransport(baseUrl: string): Promise<Transport> {
  const http2 = await import("node:http2")
  const session = http2.connect(baseUrl, {rejectUnauthorized: false})
  return {
    async post(body: Uint8Array): Promise<Uint8Array> {
      return new Promise((resolve, reject) => {
        const req = session.request({":method": "POST", ":path": "/"})
        const chunks: Buffer[] = []
        req.on("data", (chunk: Buffer) => chunks.push(chunk))
        req.on("end", () => resolve(new Uint8Array(Buffer.concat(chunks))))
        req.on("error", reject)
        req.end(Buffer.from(body))
      })
    },
    close() {
      session.close()
    }
  }
}

function createBrowserTransport(baseUrl: string): Transport {
  return {
    async post(body: Uint8Array): Promise<Uint8Array> {
      const resp = await fetch(baseUrl, {
        method: "POST",
        body,
        duplex: "half",
      } as RequestInit)
      if (!resp.ok) throw new Error(`fetch failed: ${resp.status}`)
      return new Uint8Array(await resp.arrayBuffer())
    },
    close() {}
  }
}

// ── Client agent (connection pool) ───────────────────────────────

export interface XFTPClientAgent {
  clients: Map<string, XFTPClient>
}

export function newXFTPAgent(): XFTPClientAgent {
  return {clients: new Map()}
}

export async function getXFTPServerClient(agent: XFTPClientAgent, server: XFTPServer): Promise<XFTPClient> {
  const key = "https://" + server.host + ":" + server.port
  let c = agent.clients.get(key)
  if (!c) {
    c = await connectXFTP(server)
    agent.clients.set(key, c)
  }
  return c
}

export function closeXFTPServerClient(agent: XFTPClientAgent, server: XFTPServer): void {
  const key = "https://" + server.host + ":" + server.port
  const c = agent.clients.get(key)
  if (c) {
    agent.clients.delete(key)
    c.transport.close()
  }
}

export function closeXFTPAgent(agent: XFTPClientAgent): void {
  for (const c of agent.clients.values()) c.transport.close()
  agent.clients.clear()
}

// ── Connect + handshake ───────────────────────────────────────────

export async function connectXFTP(server: XFTPServer): Promise<XFTPClient> {
  const baseUrl = "https://" + server.host + ":" + server.port
  const transport = await createTransport(baseUrl)

  try {
    // Step 1: send client hello with web challenge
    const challenge = new Uint8Array(32)
    crypto.getRandomValues(challenge)
    const shsBody = await transport.post(encodeClientHello({webChallenge: challenge}))

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
    const ack = await transport.post(encodeClientHandshake({xftpVersion, keyHash: server.keyHash}))
    if (ack.length !== 0) throw new Error("connectXFTP: non-empty handshake ack")

    return {baseUrl, sessionId: hs.sessionId, xftpVersion, transport}
  } catch (e) {
    transport.close()
    throw e
  }
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
  const reqBody = chunkData ? concatBytes(block, chunkData) : block
  const fullResp = await client.transport.post(reqBody)
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
  const fullResp = await c.transport.post(block)
  if (fullResp.length < XFTP_BLOCK_SIZE) throw new Error("pingXFTP: response too short")
  const {command} = decodeTransmission(c.sessionId, fullResp.subarray(0, XFTP_BLOCK_SIZE))
  const response = decodeResponse(command)
  if (response.type !== "FRPong") throw new Error("unexpected response: " + response.type)
}

// ── Close ─────────────────────────────────────────────────────────

export function closeXFTP(c: XFTPClient): void {
  c.transport.close()
}
