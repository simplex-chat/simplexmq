// SMPClient - wraps transport + handshake + command dispatch + PING/PONG keepalive.
//
// After connectSMP() completes, the client is ready to send commands and receive
// responses. SMP is NOT request/response like XFTP - the server can push MSG
// notifications at any time. The client dispatches incoming blocks by correlation
// ID: matching corrId goes to the response handler, empty corrId goes to the
// server push handler.

import {Decoder, concatBytes, encodeBytes, encodeLarge} from "@simplex-chat/xftp-web/dist/protocol/encoding.js"
import {encodeTransmission, decodeTransmission} from "./protocol.js"
import {SMPWebSocketTransport, SMP_BLOCK_SIZE} from "./transport.js"
import {
  decodeSMPServerHandshake,
  encodeSMPClientHandshake,
  compatibleVRange,
  smpClientVersionRange,
  verifyServerIdentity,
  buildCommandBlock,
  parseResponseBlock,
} from "./handshake.js"
import type {
  SMPServerAddress,
  ChatTransport,
  SMPClientState,
  SMPResponseHandler,
  SMPPushHandler,
} from "./types.js"
import {SMPTransportError} from "./types.js"

// -- Configuration

export interface SMPClientConfig {
  connectTimeoutMs?: number    // default 15000
  keepaliveIntervalMs?: number // default 30000 (30s PING interval)
  handshakeTimeoutMs?: number  // default 15000
}

const DEFAULT_CLIENT_CONFIG: Required<SMPClientConfig> = {
  connectTimeoutMs: 15000,
  keepaliveIntervalMs: 30000,
  handshakeTimeoutMs: 15000,
}

// -- SMPClient interface

export interface SMPClient {
  readonly sessionId: Uint8Array
  readonly smpVersion: number
  readonly transport: ChatTransport
  readonly state: SMPClientState

  // Send a pre-encoded 16KB command block (fire and forget).
  // Response comes through onResponse or onServerPush.
  sendCommand(block: Uint8Array): Promise<void>

  // Register handler for responses to our commands (matched by corrId)
  onResponse(handler: SMPResponseHandler): void

  // Register handler for server-initiated pushes (MSG with empty corrId)
  onServerPush(handler: SMPPushHandler): void

  // Start PING/PONG keepalive
  startKeepalive(): void

  // Stop keepalive and close transport
  close(): void
}

// -- PING command encoding

// PING: ASCII bytes [0x50, 0x49, 0x4e, 0x47]
export function encodePING(): Uint8Array {
  return new Uint8Array([0x50, 0x49, 0x4e, 0x47])
}

// Generate a random 24-byte correlation ID for client commands.
// Format: 24 random bytes (corrId on wire is shortString: 0x18 + 24 bytes).
function generateCorrId(): Uint8Array {
  const id = new Uint8Array(24)
  crypto.getRandomValues(id)
  return id
}

// -- SMPClient implementation

class SMPClientImpl implements SMPClient {
  readonly sessionId: Uint8Array
  readonly smpVersion: number
  readonly transport: ChatTransport
  private currentState: SMPClientState = "ready"
  private responseHandler: SMPResponseHandler | null = null
  private pushHandler: SMPPushHandler | null = null
  private keepaliveTimer: ReturnType<typeof setInterval> | null = null
  private readonly keepaliveIntervalMs: number

  constructor(
    sessionId: Uint8Array,
    smpVersion: number,
    transport: ChatTransport,
    keepaliveIntervalMs: number,
  ) {
    this.sessionId = sessionId
    this.smpVersion = smpVersion
    this.transport = transport
    this.keepaliveIntervalMs = keepaliveIntervalMs
    this.setupDispatch()
  }

  get state(): SMPClientState {
    return this.currentState
  }

  private setupDispatch(): void {
    this.transport.onMessage((block: Uint8Array) => {
      try {
        // Parse the 16KB block into raw transmission bytes
        const transmissionBytes = parseResponseBlock(block)
        // Decode the transmission: auth, corrId, entityId, command
        const td = new Decoder(transmissionBytes)
        const {corrId, entityId, command} = decodeTransmission(td)

        // Dispatch by corrId:
        // - Non-empty corrId = response to our command
        // - Empty corrId = server push (MSG notification)
        if (corrId.length > 0) {
          if (this.responseHandler !== null) {
            this.responseHandler(corrId, entityId, command)
          }
        } else {
          if (this.pushHandler !== null) {
            this.pushHandler(entityId, command)
          }
        }
      } catch (_e) {
        // Protocol error in incoming block.
        // Do not crash the dispatch loop. Reconnection (Task 4) handles dead connections.
      }
    })
  }

  async sendCommand(block: Uint8Array): Promise<void> {
    if (this.currentState !== "ready") {
      throw new SMPTransportError("CLOSED", "Client is not ready")
    }
    await this.transport.send(block)
  }

  onResponse(handler: SMPResponseHandler): void {
    this.responseHandler = handler
  }

  onServerPush(handler: SMPPushHandler): void {
    this.pushHandler = handler
  }

  startKeepalive(): void {
    if (this.keepaliveTimer !== null) return
    this.keepaliveTimer = setInterval(() => {
      if (this.currentState !== "ready") return
      const corrId = generateCorrId()
      const transmission = encodeTransmission(corrId, new Uint8Array(0), encodePING())
      const block = buildCommandBlock(transmission)
      this.transport.send(block).catch(() => {
        // Send failed - connection may be dead.
        // Reconnection is Task 4's responsibility.
      })
    }, this.keepaliveIntervalMs)
  }

  close(): void {
    this.currentState = "closed"
    if (this.keepaliveTimer !== null) {
      clearInterval(this.keepaliveTimer)
      this.keepaliveTimer = null
    }
    this.transport.close()
  }
}

// -- Connect and handshake

// Connect to an SMP server, perform the handshake, and return an SMPClient.
//
// Flow:
// 1. Create SMPWebSocketTransport and open WSS connection
// 2. Wait for first 16KB block from server (ServerHello)
// 3. Decode ServerHello: version range, sessionId, certs, signed DH key
// 4. Verify server identity (fingerprint + DH key signature)
// 5. Version negotiation: agree on highest mutual version
// 6. Send ClientHello: negotiated version + key hash
// 7. Set up command dispatch and return SMPClient
export async function connectSMP(
  server: SMPServerAddress,
  config?: Partial<SMPClientConfig>
): Promise<SMPClient> {
  const cfg: Required<SMPClientConfig> = {...DEFAULT_CLIENT_CONFIG, ...config}

  // 1. Create transport and connect
  const transport = new SMPWebSocketTransport({connectTimeoutMs: cfg.connectTimeoutMs})
  await transport.connect(server)

  try {
    // 2. Wait for ServerHello (first 16KB block from server)
    const serverHelloBlock = await waitForBlock(transport, cfg.handshakeTimeoutMs)

    // 3. Decode ServerHello
    const serverHello = decodeSMPServerHandshake(serverHelloBlock)

    // 4. Verify server identity
    verifyServerIdentity(serverHello, server.keyHash)

    // 5. Version negotiation
    const vr = compatibleVRange(serverHello.smpVersionRange, smpClientVersionRange)
    if (vr === null) {
      throw new SMPTransportError(
        "VERSION",
        "Incompatible SMP version: server " +
          serverHello.smpVersionRange.minVersion + "-" +
          serverHello.smpVersionRange.maxVersion +
          ", client " + smpClientVersionRange.minVersion + "-" +
          smpClientVersionRange.maxVersion
      )
    }
    const smpVersion = vr.maxVersion

    // 6. Send ClientHello
    const clientHello = encodeSMPClientHandshake({
      smpVersion,
      keyHash: server.keyHash,
    })
    await transport.send(clientHello)

    // 7. Return client with command dispatch
    return new SMPClientImpl(
      serverHello.sessionId,
      smpVersion,
      transport,
      cfg.keepaliveIntervalMs,
    )
  } catch (e) {
    transport.close()
    throw e
  }
}

// Wait for one 16KB block from the transport with a timeout.
// Used to receive the ServerHello during handshake.
function waitForBlock(transport: ChatTransport, timeoutMs: number): Promise<Uint8Array> {
  return new Promise<Uint8Array>((resolve, reject) => {
    let settled = false

    const timer = setTimeout(() => {
      if (!settled) {
        settled = true
        reject(new SMPTransportError("TIMEOUT", "Handshake timeout: no ServerHello received"))
      }
    }, timeoutMs)

    transport.onMessage((block: Uint8Array) => {
      if (!settled) {
        settled = true
        clearTimeout(timer)
        resolve(block)
      }
    })
  })
}
