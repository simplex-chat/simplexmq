// SMP client: command/response correlation, authentication, typed async API.
// Mirrors: Simplex.Messaging.Client

import {
  encodeTransmission, encodeTransmissionForAuth, authTransmission,
  tEncodeBatch1, tEncodeForBatch, batchTransmissions, tEncode,
  tParse, tDecodeClient, protocolError, encodePING,
  decodeResponse, paddedProxiedTLength, encodePRXY, encodePFWD,
  type AuthKey, type SMPResponse, type RawTransmission,
  encodeNEW, encodeKEY, encodeSKEY, encodeSUB, encodeACK,
  encodeSEND, encodeOFF, encodeDEL, encodeGET, encodeQUE, encodeLGET,
  type IDSResponse, type MSGResponse,
} from "./protocol.js"
import {
  connectSMP,
  type SMPConnection,
} from "./transport/websockets.js"
import {SMP_BLOCK_SIZE} from "./transport.js"
import {sbEncryptBlock, sbDecryptBlock, cbAuthenticator, reverseNonce, cbDecryptNoPad} from "./crypto.js"
import {blockPad, blockUnpad} from "@simplex-chat/xftp-web/dist/protocol/transmission.js"
import {Decoder} from "@simplex-chat/xftp-web/dist/protocol/encoding.js"
import {generateX25519KeyPair, x25519KeyPairFromPrivate, dh, encodePubKeyX25519} from "@simplex-chat/xftp-web/dist/crypto/keys.js"
import {cbEncrypt, cbDecrypt} from "@simplex-chat/xftp-web/dist/crypto/secretbox.js"
import {extractSignedKey} from "@simplex-chat/xftp-web/dist/protocol/handshake.js"

// -- Error types (Client.hs:741-770)

// ProxiedRelay (Client.hs:1095-1100)
export interface ProxiedRelay {
  sessionId: Uint8Array
  version: number       // negotiated version with relay
  basicAuth: Uint8Array | null
  relayKey: Uint8Array  // relay's X25519 public key (raw 32 bytes)
}

// ProxyClientError (Client.hs:1102-1109)
export type ProxyClientError =
  | {type: "ProxyProtocolError", error: string}
  | {type: "ProxyUnexpectedResponse", response: string}
  | {type: "ProxyResponseError", error: string}

export type SMPClientError =
  | {type: "PROTOCOL", error: string}    // ERR response from server
  | {type: "RESPONSE", error: string}    // failed to parse response
  | {type: "UNEXPECTED", raw: string}    // wrong response type for command
  | {type: "TIMEOUT"}                    // response timeout
  | {type: "NETWORK", error: string}     // connection failure
  | {type: "TRANSPORT", error: string}   // handshake/transport error

// -- SMPClient

export interface SMPClient {
  readonly sessionId: Uint8Array
  readonly smpVersion: number
  readonly serverPubKey: Uint8Array

  // Core: send pre-encoded command, await correlated response
  sendCommand(privKey: AuthKey | null, entityId: Uint8Array, command: Uint8Array): Promise<SMPResponse>

  // High-level commands
  createQueue(authKeyPair: {publicKey: Uint8Array, privateKey: Uint8Array}, dhKey: Uint8Array, subscribe: boolean): Promise<IDSResponse>
  subscribeQueue(privKey: AuthKey, rcvId: Uint8Array): Promise<void>
  getMessage(privKey: AuthKey, rcvId: Uint8Array): Promise<MSGResponse | null>
  sendMessage(privKey: AuthKey | null, sndId: Uint8Array, notification: boolean, msg: Uint8Array): Promise<void>
  ackMessage(privKey: AuthKey, rcvId: Uint8Array, msgId: Uint8Array): Promise<void>
  secureQueue(privKey: AuthKey, rcvId: Uint8Array, senderKey: Uint8Array): Promise<void>
  secureSndQueue(privKey: AuthKey, sndId: Uint8Array): Promise<void>
  getQueueLink(linkId: Uint8Array): Promise<SMPResponse>
  deleteQueue(privKey: AuthKey, rcvId: Uint8Array): Promise<void>
  suspendQueue(privKey: AuthKey, rcvId: Uint8Array): Promise<void>

  // Batch commands (Client.hs:840-845, 1062-1065)
  subscribeQueues(queues: Array<{rcvId: Uint8Array, privKey: AuthKey}>): Promise<void[]>
  deleteQueues(queues: Array<{rcvId: Uint8Array, privKey: AuthKey}>): Promise<void[]>

  // Proxy commands (Client.hs:1069-1206)
  connectProxiedRelay(relayHosts: string[], relayPort: string, relayKeyHash: Uint8Array, basicAuth: Uint8Array | null): Promise<ProxiedRelay>
  proxySMPCommand(relay: ProxiedRelay, privKey: AuthKey | null, entityId: Uint8Array, command: Uint8Array): Promise<SMPResponse>
  proxySendMessage(relay: ProxiedRelay, privKey: AuthKey | null, sndId: Uint8Array, notification: boolean, msg: Uint8Array): Promise<void>

  close(): void
}

interface PendingRequest {
  resolve: (resp: SMPResponse) => void
  reject: (err: SMPClientError) => void
  timer: ReturnType<typeof setTimeout>
}

function toHex(bytes: Uint8Array): string {
  return Array.from(bytes, b => b.toString(16).padStart(2, "0")).join("")
}

export async function createSMPClient(
  url: string,
  keyHash: Uint8Array,
  onMessage: (entityId: Uint8Array, msg: SMPResponse) => void,
  onDisconnected: () => void,
  config?: {timeout?: number, pingInterval?: number, pingMaxCount?: number, wsOptions?: object},
): Promise<SMPClient> {
  const timeout_ = config?.timeout ?? 10_000
  const pingInterval = config?.pingInterval ?? 600_000
  const pingMaxCount = config?.pingMaxCount ?? 3

  const conn = await connectSMP(url, keyHash, config?.wsOptions)
  if (!conn.serverPubKey) throw new Error("createSMPClient: server has no auth key")

  const serverPubKey = conn.serverPubKey
  const pending = new Map<string, PendingRequest>()
  let closed = false
  let pingTimer: ReturnType<typeof setInterval> | null = null
  let timeoutCount = 0

  // -- Receive loop

  function onBlock(data: ArrayBuffer | Buffer) {
    if (closed) return
    timeoutCount = 0
    try {
      const raw = data instanceof ArrayBuffer ? data : data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength)
      const block = new Uint8Array(raw)
      // Decrypt block
      const decrypted = decryptBlock(block)
      // Parse batch
      const transmissions = tParse(decrypted)
      for (const raw of transmissions) {
        dispatch(raw)
      }
    } catch (e: any) {
      // Parse error — log to stderr
      process.stderr.write("SMP client receive error: " + e.message + "\n")
    }
  }

  function decryptBlock(block: Uint8Array): Uint8Array {
    if (conn.rcvKey) {
      const {decrypted, nextChainKey} = sbDecryptBlock(conn.rcvKey, block)
      conn.rcvKey = nextChainKey
      return decrypted
    }
    // No block encryption — strip padding
    return blockUnpad(block)
  }

  function dispatch(raw: RawTransmission) {
    // Parse response
    let response: SMPResponse
    try {
      response = decodeResponse(new Decoder(raw.command))
    } catch (e: any) {
      process.stderr.write("dispatch parse error: " + e.message + " command=" + toHex(raw.command) + "\n")
      // If we can correlate, reject the pending request
      const key = toHex(raw.corrId)
      const req = pending.get(key)
      if (req) {
        pending.delete(key)
        clearTimeout(req.timer)
        req.reject({type: "RESPONSE", error: e.message})
      }
      return
    }

    // Classify: ERR → PCEProtocolError
    const err = protocolError(response)

    // Correlate by corrId
    const corrIdBytes = raw.corrId
    if (corrIdBytes.length === 0) {
      // Server push (no corrId) — deliver to event callback
      onMessage(raw.entityId, response)
      return
    }

    const key = toHex(corrIdBytes)
    const req = pending.get(key)
    if (req) {
      pending.delete(key)
      clearTimeout(req.timer)
      if (err) {
        req.reject({type: "PROTOCOL", error: err})
      } else {
        req.resolve(response)
      }
    } else {
      // No pending request — might be a late response or server push with corrId
      // Deliver as event
      if (!err) onMessage(raw.entityId, response)
    }
  }

  // Wire up WebSocket receive
  conn.ws.onmessage = (event) => onBlock(event.data as ArrayBuffer)
  conn.ws.onclose = () => {
    if (!closed) {
      closed = true
      cleanup()
      onDisconnected()
    }
  }
  conn.ws.onerror = () => {}

  // -- Ping

  function startPing() {
    if (pingInterval <= 0) return
    pingTimer = setInterval(async () => {
      try {
        await client.sendCommand(null, new Uint8Array(0), encodePING())
      } catch {
        timeoutCount++
        if (pingMaxCount > 0 && timeoutCount >= pingMaxCount) {
          client.close()
        }
      }
    }, pingInterval)
  }

  function cleanup() {
    if (pingTimer) {
      clearInterval(pingTimer)
      pingTimer = null
    }
    // Reject all pending requests
    for (const [, req] of pending) {
      clearTimeout(req.timer)
      req.reject({type: "NETWORK", error: "disconnected"})
    }
    pending.clear()
  }

  // -- Send

  // mkTransmission (Client.hs:1349-1370)
  // Encode, authenticate, register pending request. Returns encoded transmission + promise.
  // nonce_ parameter: if provided, used as corrId (for proxy commands where nonce = corrId)
  function mkTransmission(privKey: AuthKey | null, entityId: Uint8Array, command: Uint8Array, nonce_?: Uint8Array): {auth: Uint8Array | null, tToSend: Uint8Array, promise: Promise<SMPResponse>} {
    const nonce = nonce_ ?? crypto.getRandomValues(new Uint8Array(24))
    const {tForAuth, tToSend} = encodeTransmissionForAuth(conn.sessionId, nonce, entityId, command)
    const auth = authTransmission(serverPubKey, privKey, nonce, tForAuth)
    const promise = new Promise<SMPResponse>((resolve, reject) => {
      const key = toHex(nonce)
      const timer = setTimeout(() => {
        pending.delete(key)
        timeoutCount++
        reject({type: "TIMEOUT"} as SMPClientError)
      }, timeout_)
      pending.set(key, {resolve, reject, timer})
    })
    return {auth, tToSend, promise}
  }

  // Send a pre-encoded block (encrypt + write to WebSocket)
  function sendBlock(block: Uint8Array): void {
    if (conn.sndKey) {
      const {encrypted, nextChainKey} = sbEncryptBlock(conn.sndKey, block, SMP_BLOCK_SIZE - 16)
      conn.sndKey = nextChainKey
      conn.ws.send(encrypted)
    } else {
      conn.ws.send(blockPad(block, SMP_BLOCK_SIZE))
    }
  }

  // sendProtocolCommand (Client.hs:1300-1326) — single command
  // nonce_: if provided, used as corrId (for proxy where nonce = corrId)
  function sendCommand(privKey: AuthKey | null, entityId: Uint8Array, command: Uint8Array, nonce_?: Uint8Array): Promise<SMPResponse> {
    if (closed) return Promise.reject({type: "NETWORK", error: "closed"} as SMPClientError)
    const {auth, tToSend, promise} = mkTransmission(privKey, entityId, command, nonce_)
    sendBlock(tEncodeBatch1(auth, tToSend))
    return promise
  }

  // sendProtocolCommands (Client.hs:1262-1298) — batch multiple commands
  function sendCommands(commands: Array<{privKey: AuthKey | null, entityId: Uint8Array, command: Uint8Array}>): Promise<SMPResponse>[] {
    if (closed) return commands.map(() => Promise.reject({type: "NETWORK", error: "closed"} as SMPClientError))
    // mkTransmission for each
    const transmissions = commands.map(c => mkTransmission(c.privKey, c.entityId, c.command))
    // Encode for batching: tEncodeForBatch each
    const encoded = transmissions.map(t => tEncodeForBatch(t.auth, t.tToSend))
    // Pack into blocks
    const blocks = batchTransmissions(SMP_BLOCK_SIZE, encoded)
    // Send each block
    for (const block of blocks) sendBlock(block)
    // Return all promises
    return transmissions.map(t => t.promise)
  }

  // -- High-level commands

  // okSMPCommand (Client.hs:1239-1243) — only accepts OK, not SOK
  async function okCommand(privKey: AuthKey | null, entityId: Uint8Array, command: Uint8Array): Promise<void> {
    const resp = await sendCommand(privKey, entityId, command)
    if (resp.type !== "OK") {
      throw {type: "UNEXPECTED", raw: resp.type} as SMPClientError
    }
  }

  const client: SMPClient = {
    sessionId: conn.sessionId,
    smpVersion: conn.smpVersion,
    serverPubKey,
    sendCommand,

    // createQueue (Client.hs:813-827)
    async createQueue(authKeyPair, dhKey, subscribe) {
      const command = encodeNEW(authKeyPair.publicKey, dhKey, null, subscribe)
      // Auth with the X25519 private key from the keypair
      const privKey: AuthKey = {type: "x25519", key: authKeyPair.privateKey}
      const resp = await sendCommand(privKey, new Uint8Array(0), command)
      if (resp.type !== "IDS") throw {type: "UNEXPECTED", raw: resp.type} as SMPClientError
      return resp.response
    },

    // subscribeSMPQueue (Client.hs:833-836)
    async subscribeQueue(privKey, rcvId) {
      const resp = await sendCommand(privKey, rcvId, encodeSUB())
      // SUB can return MSG (queued message) — push to onMessage
      if (resp.type === "MSG") {
        onMessage(rcvId, resp)
        return
      }
      if (resp.type !== "OK" && resp.type !== "SOK") {
        throw {type: "UNEXPECTED", raw: resp.type} as SMPClientError
      }
    },

    // getSMPMessage (Client.hs:875-880)
    async getMessage(privKey, rcvId) {
      const resp = await sendCommand(privKey, rcvId, encodeGET())
      if (resp.type === "OK") return null
      if (resp.type === "MSG") {
        onMessage(rcvId, resp)
        return resp.response
      }
      throw {type: "UNEXPECTED", raw: resp.type} as SMPClientError
    },

    // sendSMPMessage (Client.hs:1027-1031)
    async sendMessage(privKey, sndId, notification, msg) {
      await okCommand(privKey, sndId, encodeSEND(notification, msg))
    },

    // ackSMPMessage (Client.hs:1040-1045)
    async ackMessage(privKey, rcvId, msgId) {
      const resp = await sendCommand(privKey, rcvId, encodeACK(msgId))
      // ACK can return MSG — push to onMessage
      if (resp.type === "MSG") {
        onMessage(rcvId, resp)
        return
      }
      if (resp.type !== "OK") {
        throw {type: "UNEXPECTED", raw: resp.type} as SMPClientError
      }
    },

    // secureSMPQueue (Client.hs:938-939)
    async secureQueue(privKey, rcvId, senderKey) {
      await okCommand(privKey, rcvId, encodeKEY(senderKey))
    },

    // secureSndSMPQueue (Client.hs:943-944)
    // SKEY sends the public key derived from the private key
    async secureSndQueue(privKey, sndId) {
      // x25519KeyPairFromPrivate derives public from private
      const pubKey = x25519KeyPairFromPrivate(privKey.key).publicKey
      await okCommand(privKey, sndId, encodeSKEY(encodePubKeyX25519(pubKey)))
    },

    // getSMPQueueLink (Client.hs:976-980)
    async getQueueLink(linkId) {
      return sendCommand(null, linkId, encodeLGET())
    },

    // deleteSMPQueue (Client.hs:1058-1059)
    async deleteQueue(privKey, rcvId) {
      await okCommand(privKey, rcvId, encodeDEL())
    },

    // suspendSMPQueue (Client.hs:1051-1052)
    async suspendQueue(privKey, rcvId) {
      await okCommand(privKey, rcvId, encodeOFF())
    },

    // subscribeSMPQueues (Client.hs:840-845)
    async subscribeQueues(queues) {
      const commands = queues.map(q => ({privKey: q.privKey, entityId: q.rcvId, command: encodeSUB()}))
      const promises = sendCommands(commands)
      return Promise.all(promises.map(async (p, i) => {
        const resp = await p
        // processSUBResponse_ (Client.hs:857-862)
        if (resp.type === "MSG") {
          onMessage(queues[i].rcvId, resp)
          return
        }
        if (resp.type !== "OK" && resp.type !== "SOK") {
          throw {type: "UNEXPECTED", raw: resp.type} as SMPClientError
        }
      }))
    },

    // deleteSMPQueues (Client.hs:1062-1065) via okSMPCommands (Client.hs:1245-1253)
    async deleteQueues(queues) {
      const commands = queues.map(q => ({privKey: q.privKey, entityId: q.rcvId, command: encodeDEL()}))
      const promises = sendCommands(commands)
      return Promise.all(promises.map(async (p) => {
        const resp = await p
        if (resp.type !== "OK") {
          throw {type: "UNEXPECTED", raw: resp.type} as SMPClientError
        }
      }))
    },

    // connectSMPProxiedRelay (Client.hs:1069-1093)
    async connectProxiedRelay(relayHosts, relayPort, relayKeyHash, basicAuth) {
      // Send PRXY to proxy server
      const command = encodePRXY(relayHosts, relayPort, relayKeyHash, basicAuth)
      const resp = await sendCommand(null, new Uint8Array(0), command)
      if (resp.type !== "PKEY") throw {type: "UNEXPECTED", raw: resp.type} as SMPClientError
      const {sessionId: relaySessId, versionRange, signedKeyDer} = resp.response
      // Check version compatibility
      const version = Math.min(versionRange.max, conn.smpVersion)
      if (version < versionRange.min) throw {type: "TRANSPORT", error: "incompatible relay version"} as SMPClientError
      // Extract relay's X25519 DH key from signed key (same as connectSMP handshake)
      const relayKey = extractSignedKey(signedKeyDer).dhKey
      // TODO: full certificate chain validation against relayKeyHash
      // For now we trust the proxy's PKEY response (proxy already validated the relay)
      return {sessionId: relaySessId, version, basicAuth, relayKey}
    },

    // proxySMPCommand (Client.hs:1157-1206)
    async proxySMPCommand(relay, privKey, entityId, command) {
      // Prepare relay params — encode as if sending directly to relay
      const relaySessionId = relay.sessionId
      // Generate ephemeral X25519 keypair for this command
      const cmdKp = generateX25519KeyPair()
      const cmdSecret = dh(relay.relayKey, cmdKp.privateKey)
      const nonce = crypto.getRandomValues(new Uint8Array(24))
      // Encode transmission for relay (using relay's sessionId)
      const {tForAuth, tToSend} = encodeTransmissionForAuth(relaySessionId, nonce, entityId, command)
      // Authenticate against relay's key
      const auth = privKey
        ? cbAuthenticator(relay.relayKey, privKey.key, nonce, tForAuth)
        : null
      // Batch into single block (for relay)
      const batchBlock = tEncodeBatch1(auth, tToSend)
      // Encrypt for relay: cbEncrypt(cmdSecret, nonce, batchBlock, paddedProxiedTLength)
      const encTransmission = cbEncrypt(cmdSecret, nonce, batchBlock, paddedProxiedTLength)
      // Send PFWD to proxy (entityId = relay sessionId from PKEY)
      // IMPORTANT: nonce is also used as corrId for PFWD (Client.hs:1175,1188)
      // The relay extracts it from FwdTransmission.fwdCorrId to decrypt
      const cmdPubKeyDer = encodePubKeyX25519(cmdKp.publicKey)
      const pfwdCommand = encodePFWD(relay.version, cmdPubKeyDer, encTransmission)
      const pfwdResp = await sendCommand(null, relay.sessionId, pfwdCommand, nonce)
      // Handle response
      if (pfwdResp.type === "PRES") {
        // Decrypt relay's response: cbDecrypt(cmdSecret, reverseNonce(nonce), encResponse)
        const decrypted = cbDecrypt(cmdSecret, reverseNonce(nonce), pfwdResp.encResponse)
        // Parse as relay's response
        const transmissions = tParse(decrypted)
        if (transmissions.length !== 1) throw {type: "TRANSPORT", error: "bad proxy response block"} as SMPClientError
        const decoded = tDecodeClient(transmissions[0])
        const relayResp = decoded.response
        const err = protocolError(relayResp)
        if (err) throw {type: "PROTOCOL", error: err} as SMPClientError
        return relayResp
      }
      if (pfwdResp.type === "ERR") {
        throw {type: "PROTOCOL", error: pfwdResp.error} as SMPClientError
      }
      throw {type: "UNEXPECTED", raw: pfwdResp.type} as SMPClientError
    },

    // proxySMPMessage — convenience for SEND via proxy
    async proxySendMessage(relay, privKey, sndId, notification, msg) {
      const command = encodeSEND(notification, msg)
      const resp = await client.proxySMPCommand(relay, privKey, sndId, command)
      if (resp.type !== "OK") throw {type: "UNEXPECTED", raw: resp.type} as SMPClientError
    },

    close() {
      if (closed) return
      closed = true
      cleanup()
      conn.ws.close()
    },
  }

  startPing()
  return client
}

