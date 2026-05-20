// SMP client: command/response correlation, authentication, typed async API.
// Mirrors: Simplex.Messaging.Client

import {
  encodeTransmission, encodeTransmissionForAuth, authTransmission,
  tEncodeBatch1, tParse, tDecodeClient, protocolError, encodePING,
  decodeResponse,
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
import {sbEncryptBlock, sbDecryptBlock} from "./crypto.js"
import {blockPad, blockUnpad} from "@simplex-chat/xftp-web/dist/protocol/transmission.js"
import {Decoder} from "@simplex-chat/xftp-web/dist/protocol/encoding.js"
import {x25519KeyPairFromPrivate, encodePubKeyX25519} from "@simplex-chat/xftp-web/dist/crypto/keys.js"

// -- Error types (Client.hs:741-770)

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
    process.stderr.write("WebSocket closed\n")
    if (!closed) {
      closed = true
      cleanup()
      onDisconnected()
    }
  }
  conn.ws.onerror = (e) => {
    process.stderr.write("WebSocket error: " + String(e) + "\n")
  }

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

  function sendCommand(privKey: AuthKey | null, entityId: Uint8Array, command: Uint8Array): Promise<SMPResponse> {
    if (closed) return Promise.reject({type: "NETWORK", error: "closed"} as SMPClientError)

    // Generate random corrId/nonce (24 bytes)
    const nonce = crypto.getRandomValues(new Uint8Array(24))

    // Encode transmission
    const {tForAuth, tToSend} = encodeTransmissionForAuth(conn.sessionId, nonce, entityId, command)

    // Authenticate
    const auth = authTransmission(serverPubKey, privKey, nonce, tForAuth)

    // Encode as single-command batch
    const block = tEncodeBatch1(auth, tToSend)

    // Send encrypted block
    if (conn.sndKey) {
      const {encrypted, nextChainKey} = sbEncryptBlock(conn.sndKey, block, SMP_BLOCK_SIZE - 16)
      conn.sndKey = nextChainKey
      conn.ws.send(encrypted)
    } else {
      conn.ws.send(blockPad(block, SMP_BLOCK_SIZE))
    }


    // Create pending request with timeout
    return new Promise<SMPResponse>((resolve, reject) => {
      const key = toHex(nonce)
      const timer = setTimeout(() => {
        pending.delete(key)
        timeoutCount++
        reject({type: "TIMEOUT"} as SMPClientError)
      }, timeout_)
      pending.set(key, {resolve, reject, timer})
    })
  }

  // -- High-level commands

  async function okCommand(privKey: AuthKey | null, entityId: Uint8Array, command: Uint8Array): Promise<void> {
    const resp = await sendCommand(privKey, entityId, command)
    if (resp.type !== "OK" && resp.type !== "SOK") {
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

