// XFTP HTTP/2 client -- Simplex.FileTransfer.Client
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
  encodeFNEW, encodeFADD, encodeFPUT, encodeFGET, encodeFDEL, encodePING,
  decodeResponse, type FileResponse, type FileInfo
} from "./protocol/commands.js"
import {decryptReceivedChunk} from "./download.js"
import type {XFTPServer} from "./protocol/address.js"
import {concatBytes} from "./protocol/encoding.js"

// -- Types

export interface XFTPClient {
  baseUrl: string
  sessionId: Uint8Array
  xftpVersion: number
  transport: Transport
}

interface Transport {
  post(body: Uint8Array, headers?: Record<string, string>): Promise<Uint8Array>
  close(): void
}

// -- Transport implementations

const isNode = typeof globalThis.process !== "undefined" && globalThis.process.versions?.node

// In development mode, use HTTP proxy to avoid self-signed cert issues in browser
// __XFTP_PROXY_PORT__ is injected by vite build (null in production)
declare const __XFTP_PROXY_PORT__: string | null

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
    async post(body: Uint8Array, headers?: Record<string, string>): Promise<Uint8Array> {
      return new Promise((resolve, reject) => {
        const req = session.request({":method": "POST", ":path": "/", ...headers})
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
  // In dev mode, route through /xftp-proxy to avoid self-signed cert rejection
  // __XFTP_PROXY_PORT__ is 'proxy' in dev mode (uses relative path), null in production
  const effectiveUrl = typeof __XFTP_PROXY_PORT__ !== 'undefined' && __XFTP_PROXY_PORT__
    ? '/xftp-proxy'
    : baseUrl
  console.log('[DEBUG transport] baseUrl=%s effectiveUrl=%s proxy=%s', baseUrl, effectiveUrl, __XFTP_PROXY_PORT__)
  return {
    async post(body: Uint8Array, headers?: Record<string, string>): Promise<Uint8Array> {
      console.log('[DEBUG transport.post] url=%s bodyLen=%d headers=%o', effectiveUrl, body.length, headers)
      const resp = await fetch(effectiveUrl, {
        method: "POST",
        headers,
        body,
      })
      console.log('[DEBUG transport.post] status=%d statusText=%s', resp.status, resp.statusText)
      console.log('[DEBUG transport.post] response headers:', Object.fromEntries(resp.headers.entries()))
      if (!resp.ok) throw new Error(`fetch failed: ${resp.status}`)
      const buf = new Uint8Array(await resp.arrayBuffer())
      console.log('[DEBUG transport.post] responseLen=%d first16=%s', buf.length, Array.from(buf.subarray(0, 16)).map(b => b.toString(16).padStart(2,'0')).join(' '))
      return buf
    },
    close() {}
  }
}

// -- Client agent (connection pool)

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

// -- Connect + handshake

export async function connectXFTP(server: XFTPServer): Promise<XFTPClient> {
  const baseUrl = "https://" + server.host + ":" + server.port
  const transport = await createTransport(baseUrl)

  try {
    // Step 1: send client hello with web challenge
    console.log('[DEBUG connectXFTP] Step 1: sending client hello')
    const challenge = new Uint8Array(32)
    crypto.getRandomValues(challenge)
    const clientHelloBytes = encodeClientHello({webChallenge: challenge})
    console.log('[DEBUG connectXFTP] clientHelloBytes.length=%d', clientHelloBytes.length)
    const shsBody = await transport.post(clientHelloBytes, {"xftp-web-hello": "1"})
    console.log('[DEBUG connectXFTP] Step 1 done: shsBody.length=%d', shsBody.length)

    // Step 2: decode + verify server handshake
    console.log('[DEBUG connectXFTP] Step 2: decoding server handshake')
    const hs = decodeServerHandshake(shsBody)
    console.log('[DEBUG connectXFTP] Step 2 decoded: sessionId.length=%d certChain.length=%d signedKey.length=%d webProof=%s',
      hs.sessionId.length, hs.certChainDer.length, hs.signedKeyDer.length, hs.webIdentityProof ? hs.webIdentityProof.length : 'null')
    if (!hs.webIdentityProof) throw new Error("connectXFTP: no web identity proof")
    const idOk = verifyIdentityProof({
      certChainDer: hs.certChainDer,
      signedKeyDer: hs.signedKeyDer,
      sigBytes: hs.webIdentityProof,
      challenge,
      sessionId: hs.sessionId,
      keyHash: server.keyHash
    })
    console.log('[DEBUG connectXFTP] Step 2 identity verified=%s', idOk)
    if (!idOk) throw new Error("connectXFTP: identity verification failed")

    // Step 3: version negotiation
    const vr = compatibleVRange(hs.xftpVersionRange, {minVersion: initialXFTPVersion, maxVersion: currentXFTPVersion})
    console.log('[DEBUG connectXFTP] Step 3: version range=%o negotiated=%o', hs.xftpVersionRange, vr)
    if (!vr) throw new Error("connectXFTP: incompatible version")
    const xftpVersion = vr.maxVersion

    // Step 4: send client handshake
    console.log('[DEBUG connectXFTP] Step 4: sending client handshake v=%d', xftpVersion)
    const ack = await transport.post(encodeClientHandshake({xftpVersion, keyHash: server.keyHash}), {"xftp-handshake": "1"})
    console.log('[DEBUG connectXFTP] Step 4 done: ack.length=%d', ack.length)
    if (ack.length !== 0) throw new Error("connectXFTP: non-empty handshake ack")

    console.log('[DEBUG connectXFTP] handshake complete, sessionId=%s', Array.from(hs.sessionId.subarray(0, 8)).map(b => b.toString(16).padStart(2,'0')).join(''))
    return {baseUrl, sessionId: hs.sessionId, xftpVersion, transport}
  } catch (e) {
    transport.close()
    throw e
  }
}

// -- Send command

async function sendXFTPCommand(
  client: XFTPClient,
  privateKey: Uint8Array,
  entityId: Uint8Array,
  cmdBytes: Uint8Array,
  chunkData?: Uint8Array
): Promise<{response: FileResponse, body: Uint8Array}> {
  const cmdTag = String.fromCharCode(...cmdBytes.subarray(0, 4))
  console.log('[DEBUG sendXFTPCommand] cmd=%s entityId.len=%d chunkData=%s', cmdTag, entityId.length, chunkData ? chunkData.length : 'none')
  const corrId = new Uint8Array(0)
  const block = encodeAuthTransmission(client.sessionId, corrId, entityId, cmdBytes, privateKey)
  const reqBody = chunkData ? concatBytes(block, chunkData) : block
  console.log('[DEBUG sendXFTPCommand] reqBody.length=%d (block=%d + chunk=%d)', reqBody.length, block.length, chunkData?.length ?? 0)
  const fullResp = await client.transport.post(reqBody)
  console.log('[DEBUG sendXFTPCommand] fullResp.length=%d', fullResp.length)
  if (fullResp.length < XFTP_BLOCK_SIZE) throw new Error("sendXFTPCommand: response too short (" + fullResp.length + " < " + XFTP_BLOCK_SIZE + ")")
  const respBlock = fullResp.subarray(0, XFTP_BLOCK_SIZE)
  const body = fullResp.subarray(XFTP_BLOCK_SIZE)
  console.log('[DEBUG sendXFTPCommand] respBlock first4: %s', Array.from(respBlock.subarray(0, 4)).map(b => b.toString(16).padStart(2,'0')).join(' '))
  const {command} = decodeTransmission(client.sessionId, respBlock)
  console.log('[DEBUG sendXFTPCommand] decoded command=%s', String.fromCharCode(...command.subarray(0, Math.min(20, command.length))))
  const response = decodeResponse(command)
  console.log('[DEBUG sendXFTPCommand] response.type=%s', response.type)
  if (response.type === "FRErr") throw new Error("XFTP error: " + response.err.type)
  return {response, body}
}

// -- Command wrappers

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

export interface RawChunkResponse {
  dhSecret: Uint8Array
  nonce: Uint8Array
  body: Uint8Array
}

export async function downloadXFTPChunkRaw(
  c: XFTPClient, rpKey: Uint8Array, fId: Uint8Array
): Promise<RawChunkResponse> {
  const {publicKey, privateKey} = generateX25519KeyPair()
  const cmd = encodeFGET(encodePubKeyX25519(publicKey))
  const {response, body} = await sendXFTPCommand(c, rpKey, fId, cmd)
  if (response.type !== "FRFile") throw new Error("unexpected response: " + response.type)
  const dhSecret = dh(response.rcvDhKey, privateKey)
  return {dhSecret, nonce: response.nonce, body}
}

export async function downloadXFTPChunk(
  c: XFTPClient, rpKey: Uint8Array, fId: Uint8Array, digest?: Uint8Array
): Promise<Uint8Array> {
  const {dhSecret, nonce, body} = await downloadXFTPChunkRaw(c, rpKey, fId)
  return decryptReceivedChunk(dhSecret, nonce, body, digest ?? null)
}

export async function deleteXFTPChunk(
  c: XFTPClient, spKey: Uint8Array, sId: Uint8Array
): Promise<void> {
  const {response} = await sendXFTPCommand(c, spKey, sId, encodeFDEL())
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

// -- Close

export function closeXFTP(c: XFTPClient): void {
  c.transport.close()
}
