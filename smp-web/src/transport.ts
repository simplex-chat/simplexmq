// SMPWebSocketTransport - WebSocket transport with SMP 16KB block framing.
//
// Handles ONLY:
// - Opening/closing a WebSocket connection (WSS only)
// - Sending and receiving exactly 16,384-byte blocks
// - Connection state tracking
// - Connect timeout
//
// Does NOT handle:
// - SMP handshake (Task 2)
// - Reconnection logic (Task 4)
// - Connection pooling (Task 4)
// - PING/PONG (Task 2, needs handshake first)
// - SMP command encoding/decoding (Season 3)

import type {
  ChatTransport,
  SMPServerAddress,
  TransportState,
  TransportEventHandler,
} from "./types.js"
import {SMPTransportError} from "./types.js"

// SMP uses the same 16,384-byte block size as XFTP (XFTP_BLOCK_SIZE).
// Defined here to avoid pulling in the xftp-web dependency chain
// (which requires libsodium-wrappers-sumo). This is a fixed protocol constant.
export const SMP_BLOCK_SIZE = 16384

export interface SMPTransportConfig {
  connectTimeoutMs?: number
}

const DEFAULT_CONFIG: Required<SMPTransportConfig> = {
  connectTimeoutMs: 15000,
}

export class SMPWebSocketTransport implements ChatTransport {
  private ws: WebSocket | null = null
  private currentState: TransportState = "disconnected"
  private messageHandler: TransportEventHandler | null = null
  private readonly config: Required<SMPTransportConfig>

  constructor(config?: SMPTransportConfig) {
    this.config = {...DEFAULT_CONFIG, ...config}
  }

  get state(): TransportState {
    return this.currentState
  }

  async connect(server: SMPServerAddress): Promise<void> {
    if (this.currentState !== "disconnected") {
      throw new SMPTransportError("NETWORK", "Transport is not disconnected")
    }

    this.currentState = "connecting"

    const url = "wss://" + server.host + ":" + server.port

    return new Promise<void>((resolve, reject) => {
      let timeoutId: ReturnType<typeof setTimeout> | null = null
      let settled = false

      const cleanup = () => {
        if (timeoutId !== null) {
          clearTimeout(timeoutId)
          timeoutId = null
        }
      }

      const settle = (fn: () => void) => {
        if (settled) return
        settled = true
        cleanup()
        fn()
      }

      try {
        const ws = new WebSocket(url)
        ws.binaryType = "arraybuffer"
        this.ws = ws

        timeoutId = setTimeout(() => {
          settle(() => {
            ws.close()
            this.ws = null
            this.currentState = "disconnected"
            reject(new SMPTransportError("TIMEOUT", "Connection timed out after " + this.config.connectTimeoutMs + "ms"))
          })
        }, this.config.connectTimeoutMs)

        ws.addEventListener("open", () => {
          settle(() => {
            this.currentState = "connected"
            resolve()
          })
        })

        ws.addEventListener("error", () => {
          settle(() => {
            this.ws = null
            this.currentState = "disconnected"
            reject(new SMPTransportError("NETWORK", "WebSocket connection failed to " + url))
          })
        })

        ws.addEventListener("close", () => {
          // If we are still connecting (error before open), the error handler
          // will have already settled the promise. This handles unexpected
          // close after connection was established.
          if (!settled) {
            settle(() => {
              this.ws = null
              this.currentState = "disconnected"
              reject(new SMPTransportError("CLOSED", "Connection closed during connect"))
            })
          } else {
            this.ws = null
            this.currentState = "disconnected"
          }
        })

        ws.addEventListener("message", (event: MessageEvent) => {
          const data = event.data as ArrayBuffer
          if (data.byteLength !== SMP_BLOCK_SIZE) {
            const error = new SMPTransportError(
              "BLOCK_SIZE",
              "Received block of " + data.byteLength + " bytes, expected " + SMP_BLOCK_SIZE
            )
            // Close the connection on protocol violation
            this.close()
            throw error
          }
          if (this.messageHandler !== null) {
            this.messageHandler(new Uint8Array(data))
          }
        })
      } catch (e) {
        settle(() => {
          this.ws = null
          this.currentState = "disconnected"
          if (e instanceof SMPTransportError) {
            reject(e)
          } else {
            reject(new SMPTransportError("NETWORK", "Failed to create WebSocket: " + String(e)))
          }
        })
      }
    })
  }

  async send(block: Uint8Array): Promise<void> {
    if (this.currentState !== "connected") {
      throw new SMPTransportError("CLOSED", "Cannot send: transport is not connected")
    }
    if (block.length !== SMP_BLOCK_SIZE) {
      throw new SMPTransportError(
        "BLOCK_SIZE",
        "Block must be exactly " + SMP_BLOCK_SIZE + " bytes, got " + block.length
      )
    }
    this.ws!.send(block)
  }

  onMessage(handler: TransportEventHandler): void {
    this.messageHandler = handler
  }

  close(): void {
    if (this.ws === null) {
      this.currentState = "disconnected"
      return
    }
    if (this.currentState === "connected" || this.currentState === "connecting") {
      this.currentState = "closing"
      this.ws.close()
    }
  }
}
