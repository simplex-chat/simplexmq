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
  decodeResponse, type FileResponse, type FileInfo, type XFTPErrorType
} from "./protocol/commands.js"
import {decryptReceivedChunk} from "./download.js"
import type {XFTPServer} from "./protocol/address.js"
import {formatXFTPServer} from "./protocol/address.js"
import {concatBytes} from "./protocol/encoding.js"
import {blockUnpad} from "./protocol/transmission.js"

// -- Error types

export class XFTPRetriableError extends Error {
  constructor(public readonly errorType: string) {
    super(humanReadableMessage(errorType))
    this.name = "XFTPRetriableError"
  }
}

export class XFTPPermanentError extends Error {
  constructor(public readonly errorType: string, message: string) {
    super(message)
    this.name = "XFTPPermanentError"
  }
}

export function isRetriable(e: unknown): boolean {
  if (e instanceof XFTPRetriableError) return true
  if (e instanceof XFTPPermanentError) return false
  if (e instanceof TypeError) return true  // fetch network error
  if (e instanceof Error && e.name === "AbortError") return true  // timeout
  return false
}

export function categorizeError(e: unknown): Error {
  if (e instanceof XFTPRetriableError || e instanceof XFTPPermanentError) return e
  if (e instanceof TypeError) return new XFTPRetriableError("NETWORK")
  if (e instanceof Error && e.name === "AbortError") return new XFTPRetriableError("TIMEOUT")
  return e instanceof Error ? e : new Error(String(e))
}

export function humanReadableMessage(errorType: string | XFTPErrorType): string {
  const t = typeof errorType === "string" ? errorType : errorType.type
  switch (t) {
    case "SESSION": return "Session expired, reconnecting..."
    case "HANDSHAKE": return "Connection interrupted, reconnecting..."
    case "NETWORK": return "Network error, retrying..."
    case "TIMEOUT": return "Server timeout, retrying..."
    case "AUTH": return "File is invalid, expired, or has been removed"
    case "NO_FILE": return "File not found — it may have expired"
    case "SIZE": return "File size exceeds server limit"
    case "QUOTA": return "Server storage quota exceeded"
    case "BLOCKED": return "File has been blocked by server"
    case "DIGEST": return "File integrity check failed"
    case "INTERNAL": return "Server internal error"
    case "CMD": return "Protocol error"
    default: return "Server error: " + t
  }
}

// -- Types

export interface XFTPClient {
  baseUrl: string
  sessionId: Uint8Array
  xftpVersion: number
  transport: Transport
}

export interface TransportConfig {
  timeoutMs: number  // default 30000 (30s), lower for tests
}

const DEFAULT_TRANSPORT_CONFIG: TransportConfig = {timeoutMs: 30000}

interface Transport {
  post(body: Uint8Array, headers?: Record<string, string>): Promise<Uint8Array>
  close(): void
}

// -- Transport implementations

const isNode = typeof globalThis.process !== "undefined" && globalThis.process.versions?.node

// In development mode, use HTTP proxy to avoid self-signed cert issues in browser
// __XFTP_PROXY_PORT__ is injected by vite build (null in production)
declare const __XFTP_PROXY_PORT__: string | null

async function createTransport(baseUrl: string, config: TransportConfig): Promise<Transport> {
  if (isNode) {
    return createNodeTransport(baseUrl, config)
  } else {
    return createBrowserTransport(baseUrl, config)
  }
}

async function createNodeTransport(baseUrl: string, config: TransportConfig): Promise<Transport> {
  const http2 = await import("node:http2")
  const session = http2.connect(baseUrl, {rejectUnauthorized: false})
  return {
    async post(body: Uint8Array, headers?: Record<string, string>): Promise<Uint8Array> {
      return new Promise((resolve, reject) => {
        const req = session.request({":method": "POST", ":path": "/", ...headers})
        req.setTimeout(config.timeoutMs, () => {
          req.close()
          reject(Object.assign(new Error("Request timeout"), {name: "AbortError"}))
        })
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

function createBrowserTransport(baseUrl: string, config: TransportConfig): Transport {
  // In dev mode, route through /xftp-proxy to avoid self-signed cert rejection
  // __XFTP_PROXY_PORT__ is 'proxy' in dev mode (uses relative path), null in production
  const effectiveUrl = typeof __XFTP_PROXY_PORT__ !== 'undefined' && __XFTP_PROXY_PORT__
    ? '/xftp-proxy'
    : baseUrl
  return {
    async post(body: Uint8Array, headers?: Record<string, string>): Promise<Uint8Array> {
      const controller = new AbortController()
      const timer = setTimeout(() => controller.abort(), config.timeoutMs)
      try {
        const resp = await fetch(effectiveUrl, {
          method: "POST",
          headers,
          body,
          signal: controller.signal
        })
        if (!resp.ok) {
          console.error('[XFTP] fetch %s failed: %d %s', effectiveUrl, resp.status, resp.statusText)
          throw new Error(`Server request failed: ${resp.status} ${resp.statusText}`)
        }
        return new Uint8Array(await resp.arrayBuffer())
      } finally {
        clearTimeout(timer)
      }
    },
    close() {}
  }
}

// -- Client agent (connection pool with Promise-based lock)

interface ServerConnection {
  client: Promise<XFTPClient>   // resolves to connected client; replaced on reconnect
  queue: Promise<void>          // tail of sequential command chain
}

export interface XFTPClientAgent {
  connections: Map<string, ServerConnection>
  /** @internal Injectable for testing — defaults to connectXFTP */
  _connectFn: (server: XFTPServer) => Promise<XFTPClient>
}

export function newXFTPAgent(): XFTPClientAgent {
  return {connections: new Map(), _connectFn: connectXFTP}
}

export function getXFTPServerClient(agent: XFTPClientAgent, server: XFTPServer): Promise<XFTPClient> {
  const key = formatXFTPServer(server)
  let conn = agent.connections.get(key)
  if (!conn) {
    const p = agent._connectFn(server)
    conn = {client: p, queue: Promise.resolve()}
    agent.connections.set(key, conn)
    p.catch(() => {
      const cur = agent.connections.get(key)
      if (cur && cur.client === p) agent.connections.delete(key)
    })
  }
  return conn.client
}

export function reconnectClient(agent: XFTPClientAgent, server: XFTPServer): Promise<XFTPClient> {
  const key = formatXFTPServer(server)
  const old = agent.connections.get(key)
  old?.client.then(c => c.transport.close(), () => {})
  const p = agent._connectFn(server)
  const conn: ServerConnection = {client: p, queue: old?.queue ?? Promise.resolve()}
  agent.connections.set(key, conn)
  p.catch(() => {
    const cur = agent.connections.get(key)
    if (cur && cur.client === p) agent.connections.delete(key)
  })
  return p
}

export function removeStaleConnection(
  agent: XFTPClientAgent, server: XFTPServer, failedP: Promise<XFTPClient>
): void {
  const key = formatXFTPServer(server)
  const conn = agent.connections.get(key)
  if (conn && conn.client === failedP) {
    agent.connections.delete(key)
    failedP.then(c => c.transport.close(), () => {})
  }
}

export function closeXFTPServerClient(agent: XFTPClientAgent, server: XFTPServer): void {
  const key = formatXFTPServer(server)
  const conn = agent.connections.get(key)
  if (conn) {
    agent.connections.delete(key)
    conn.client.then(c => c.transport.close(), () => {})
  }
}

export function closeXFTPAgent(agent: XFTPClientAgent): void {
  for (const conn of agent.connections.values()) {
    conn.client.then(c => c.transport.close(), () => {})
  }
  agent.connections.clear()
}

// -- Connect + handshake

export async function connectXFTP(server: XFTPServer, config?: Partial<TransportConfig>): Promise<XFTPClient> {
  const cfg: TransportConfig = {...DEFAULT_TRANSPORT_CONFIG, ...config}
  const baseUrl = "https://" + server.host + ":" + server.port
  const transport = await createTransport(baseUrl, cfg)

  try {
    // Step 1: send client hello with web challenge
    const challenge = new Uint8Array(32)
    crypto.getRandomValues(challenge)
    const clientHelloBytes = encodeClientHello({webChallenge: challenge})
    const shsBody = await transport.post(clientHelloBytes, {"xftp-web-hello": "1"})

    // Step 2: decode + verify server handshake
    const hs = decodeServerHandshake(shsBody)
    if (!hs.webIdentityProof) {
      console.error('[XFTP] Server did not provide web identity proof')
      throw new Error("Server did not provide web identity proof")
    }
    const idOk = verifyIdentityProof({
      certChainDer: hs.certChainDer,
      signedKeyDer: hs.signedKeyDer,
      sigBytes: hs.webIdentityProof,
      challenge,
      sessionId: hs.sessionId,
      keyHash: server.keyHash
    })
    if (!idOk) {
      console.error('[XFTP] Server identity verification failed')
      throw new Error("Server identity verification failed")
    }

    // Step 3: version negotiation
    const vr = compatibleVRange(hs.xftpVersionRange, {minVersion: initialXFTPVersion, maxVersion: currentXFTPVersion})
    if (!vr) {
      console.error('[XFTP] Incompatible server version: %o', hs.xftpVersionRange)
      throw new Error("Incompatible server version")
    }
    const xftpVersion = vr.maxVersion

    // Step 4: send client handshake
    const ack = await transport.post(encodeClientHandshake({xftpVersion, keyHash: server.keyHash}), {"xftp-handshake": "1"})
    if (ack.length !== 0) {
      console.error('[XFTP] Non-empty handshake ack (%d bytes)', ack.length)
      throw new Error("Server handshake failed")
    }

    return {baseUrl, sessionId: hs.sessionId, xftpVersion, transport}
  } catch (e) {
    console.error('[XFTP] Connection to %s failed:', baseUrl, e)
    transport.close()
    throw e
  }
}

// -- Send command (single attempt, no retry)

async function sendXFTPCommandOnce(
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
  console.log(`[XFTP-DBG] sendOnce: fullResp.length=${fullResp.length} entityId=${_hex(entityId)} cmdTag=${cmdBytes[0]}`)
  if (fullResp.length < XFTP_BLOCK_SIZE) {
    console.error('[XFTP] Response too short: %d bytes (expected >= %d)', fullResp.length, XFTP_BLOCK_SIZE)
    throw new Error("Server response too short")
  }
  const respBlock = fullResp.subarray(0, XFTP_BLOCK_SIZE)
  const body = fullResp.subarray(XFTP_BLOCK_SIZE)
  console.log(`[XFTP-DBG] sendOnce: body.length=${body.length} body.byteOffset=${body.byteOffset} body.buffer.byteLength=${body.buffer.byteLength}`)
  // Detect padded error strings (HANDSHAKE, SESSION) before decodeTransmission
  const raw = blockUnpad(respBlock)
  if (raw.length < 20) {
    const text = new TextDecoder().decode(raw)
    if (/^[A-Z_]+$/.test(text)) {
      throw new XFTPRetriableError(text)
    }
  }
  const {command} = decodeTransmission(client.sessionId, respBlock)
  const response = decodeResponse(command)
  if (response.type === "FRErr") {
    const err = response.err
    if (err.type === "SESSION" || err.type === "HANDSHAKE") {
      throw new XFTPRetriableError(err.type)
    }
    throw new XFTPPermanentError(err.type, humanReadableMessage(err))
  }
  return {response, body}
}

function _hex(b: Uint8Array, n = 8): string {
  return Array.from(b.slice(0, n)).map(x => x.toString(16).padStart(2, '0')).join('')
}

// -- Send command (with retry + reconnect)

export async function sendXFTPCommand(
  agent: XFTPClientAgent,
  server: XFTPServer,
  privateKey: Uint8Array,
  entityId: Uint8Array,
  cmdBytes: Uint8Array,
  chunkData?: Uint8Array,
  maxRetries: number = 3
): Promise<{response: FileResponse, body: Uint8Array}> {
  let clientP = getXFTPServerClient(agent, server)
  let client = await clientP
  for (let attempt = 1; attempt <= maxRetries; attempt++) {
    try {
      if (attempt > 1) console.log(`[XFTP-DBG] sendCmd: retry attempt=${attempt}/${maxRetries}`)
      return await sendXFTPCommandOnce(client, privateKey, entityId, cmdBytes, chunkData)
    } catch (e) {
      console.log(`[XFTP-DBG] sendCmd: attempt=${attempt} failed: ${e instanceof Error ? e.message : String(e)} retriable=${isRetriable(e)}`)
      if (!isRetriable(e)) {
        throw categorizeError(e)
      }
      if (attempt === maxRetries) {
        removeStaleConnection(agent, server, clientP)
        throw categorizeError(e)
      }
      clientP = reconnectClient(agent, server)
      client = await clientP
    }
  }
  throw new Error("unreachable")
}

// -- Command wrappers

export async function createXFTPChunk(
  agent: XFTPClientAgent, server: XFTPServer, spKey: Uint8Array, file: FileInfo,
  rcvKeys: Uint8Array[], auth: Uint8Array | null = null
): Promise<{senderId: Uint8Array, recipientIds: Uint8Array[]}> {
  const {response} = await sendXFTPCommand(agent, server, spKey, new Uint8Array(0), encodeFNEW(file, rcvKeys, auth))
  if (response.type !== "FRSndIds") throw new Error("unexpected response: " + response.type)
  return {senderId: response.senderId, recipientIds: response.recipientIds}
}

export async function addXFTPRecipients(
  agent: XFTPClientAgent, server: XFTPServer, spKey: Uint8Array, fId: Uint8Array, rcvKeys: Uint8Array[]
): Promise<Uint8Array[]> {
  const {response} = await sendXFTPCommand(agent, server, spKey, fId, encodeFADD(rcvKeys))
  if (response.type !== "FRRcvIds") throw new Error("unexpected response: " + response.type)
  return response.recipientIds
}

export async function uploadXFTPChunk(
  agent: XFTPClientAgent, server: XFTPServer, spKey: Uint8Array, fId: Uint8Array, chunkData: Uint8Array
): Promise<void> {
  const {response} = await sendXFTPCommand(agent, server, spKey, fId, encodeFPUT(), chunkData)
  if (response.type !== "FROk") throw new Error("unexpected response: " + response.type)
}

export interface RawChunkResponse {
  dhSecret: Uint8Array
  nonce: Uint8Array
  body: Uint8Array
}

export async function downloadXFTPChunkRaw(
  agent: XFTPClientAgent, server: XFTPServer, rpKey: Uint8Array, fId: Uint8Array
): Promise<RawChunkResponse> {
  const {publicKey, privateKey} = generateX25519KeyPair()
  const cmd = encodeFGET(encodePubKeyX25519(publicKey))
  const {response, body} = await sendXFTPCommand(agent, server, rpKey, fId, cmd)
  if (response.type !== "FRFile") throw new Error("unexpected response: " + response.type)
  const dhSecret = dh(response.rcvDhKey, privateKey)
  console.log(`[XFTP-DBG] dlChunkRaw: body.length=${body.length} nonce=${_hex(response.nonce, 24)} dhSecret=${_hex(dhSecret)} body[0..8]=${_hex(body)} body[-8..]=${_hex(body.slice(-8))}`)
  return {dhSecret, nonce: response.nonce, body}
}

export async function downloadXFTPChunk(
  agent: XFTPClientAgent, server: XFTPServer, rpKey: Uint8Array, fId: Uint8Array, digest?: Uint8Array
): Promise<Uint8Array> {
  const {dhSecret, nonce, body} = await downloadXFTPChunkRaw(agent, server, rpKey, fId)
  return decryptReceivedChunk(dhSecret, nonce, body, digest ?? null)
}

export async function deleteXFTPChunk(
  agent: XFTPClientAgent, server: XFTPServer, spKey: Uint8Array, sId: Uint8Array
): Promise<void> {
  const {response} = await sendXFTPCommand(agent, server, spKey, sId, encodeFDEL())
  if (response.type !== "FROk") throw new Error("unexpected response: " + response.type)
}

export async function pingXFTP(agent: XFTPClientAgent, server: XFTPServer): Promise<void> {
  const client = await getXFTPServerClient(agent, server)
  const corrId = new Uint8Array(0)
  const block = encodeTransmission(client.sessionId, corrId, new Uint8Array(0), encodePING())
  const fullResp = await client.transport.post(block)
  if (fullResp.length < XFTP_BLOCK_SIZE) throw new Error("pingXFTP: response too short")
  const {command} = decodeTransmission(client.sessionId, fullResp.subarray(0, XFTP_BLOCK_SIZE))
  const response = decodeResponse(command)
  if (response.type !== "FRPong") throw new Error("unexpected response: " + response.type)
}

// -- Close

export function closeXFTP(c: XFTPClient): void {
  c.transport.close()
}
