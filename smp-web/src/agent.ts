// SMPClientAgent - connection pool with automatic reconnection.
//
// Manages connections to multiple SMP servers. Each server gets at most one
// connection. Dropped connections trigger exponential backoff reconnection.
// Network-aware: pauses reconnection when offline, resumes on network recovery,
// checks for stale connections when a backgrounded tab becomes visible.
//
// Adapts the XFTPClientAgent pattern from xftp-web/src/client.ts with additions
// for persistent WebSocket connections and automatic reconnection.

import type {SMPClient, SMPClientConfig} from "./client.js"
import {connectSMP} from "./client.js"
import {SMPWebSocketTransport} from "./transport.js"
import type {
  SMPServerAddress,
  ConnectionEvent,
  ConnectionChangeHandler,
} from "./types.js"
import {SMPTransportError} from "./types.js"

// -- Configuration

export interface SMPAgentConfig extends SMPClientConfig {
  reconnectBaseMs?: number      // default 500
  reconnectMultiplier?: number  // default 2
  reconnectMaxMs?: number       // default 30000 (30s cap)
  reconnectJitter?: number      // default 0.5 (50% multiplicative jitter)
  reconnectMaxAttempts?: number // default 12 (~2 minutes before giving up)
}

const DEFAULT_AGENT_CONFIG: Required<SMPAgentConfig> = {
  connectTimeoutMs: 15000,
  keepaliveIntervalMs: 30000,
  handshakeTimeoutMs: 15000,
  reconnectBaseMs: 500,
  reconnectMultiplier: 2,
  reconnectMaxMs: 30000,
  reconnectJitter: 0.5,
  reconnectMaxAttempts: 12,
}

// -- Types

interface ServerConnection {
  client: Promise<SMPClient>
  queue: Promise<void> // sequential command chain (for future Season 3 use)
}

// -- Backoff calculation

// Calculate delay for reconnection attempt N.
// delay = min(baseMs * multiplier^attempt, maxMs)
// actualDelay = delay * (1 + random() * jitter)
export function calculateBackoff(attempt: number, config: Partial<SMPAgentConfig> = {}): number {
  const base = config.reconnectBaseMs ?? DEFAULT_AGENT_CONFIG.reconnectBaseMs
  const multiplier = config.reconnectMultiplier ?? DEFAULT_AGENT_CONFIG.reconnectMultiplier
  const maxMs = config.reconnectMaxMs ?? DEFAULT_AGENT_CONFIG.reconnectMaxMs
  const jitter = config.reconnectJitter ?? DEFAULT_AGENT_CONFIG.reconnectJitter

  const delay = Math.min(base * Math.pow(multiplier, attempt), maxMs)
  const actualDelay = delay * (1 + Math.random() * jitter)
  return Math.round(actualDelay)
}

// -- Server key

export function serverKey(server: SMPServerAddress): string {
  return server.host + ":" + server.port
}

// -- SMPClientAgent interface

export interface SMPClientAgent {
  // Get or create a connection to a server.
  // Returns existing client if connected, creates new connection if not.
  getClient(server: SMPServerAddress): Promise<SMPClient>

  // Force reconnect to a server (closes existing, creates new).
  reconnect(server: SMPServerAddress): Promise<SMPClient>

  // Close connection to a specific server.
  closeServer(server: SMPServerAddress): void

  // Close all connections and clean up event listeners.
  closeAll(): void

  // Register handler for connection state changes.
  onConnectionChange(handler: ConnectionChangeHandler): void
}

// -- SMPClientAgent implementation

class SMPClientAgentImpl implements SMPClientAgent {
  private readonly connections: Map<string, ServerConnection> = new Map()
  private readonly cfg: Required<SMPAgentConfig>
  private connectionChangeHandler: ConnectionChangeHandler | null = null
  private readonly servers: Map<string, SMPServerAddress> = new Map()
  private readonly onlineHandler: () => void
  private readonly visibilityHandler: () => void
  private destroyed = false

  // Injectable connect function for testing
  _connectFn: (server: SMPServerAddress, config?: Partial<SMPClientConfig>) => Promise<SMPClient>

  constructor(config?: Partial<SMPAgentConfig>) {
    this.cfg = {...DEFAULT_AGENT_CONFIG, ...config}
    this._connectFn = connectSMP

    // Network-aware: reconnect all disconnected servers when network comes back
    this.onlineHandler = () => {
      if (!this.destroyed) this.reconnectAllDisconnected()
    }

    // Network-aware: check stale connections when tab becomes visible
    this.visibilityHandler = () => {
      if (!this.destroyed && typeof document !== "undefined" && document.visibilityState === "visible") {
        this.checkStaleConnections()
      }
    }

    if (typeof window !== "undefined") {
      window.addEventListener("online", this.onlineHandler)
    }
    if (typeof document !== "undefined") {
      document.addEventListener("visibilitychange", this.visibilityHandler)
    }
  }

  getClient(server: SMPServerAddress): Promise<SMPClient> {
    const key = serverKey(server)
    const existing = this.connections.get(key)
    if (existing) return existing.client

    return this.createConnection(server)
  }

  reconnect(server: SMPServerAddress): Promise<SMPClient> {
    const key = serverKey(server)
    const old = this.connections.get(key)
    if (old) {
      old.client.then(c => c.close(), () => {})
    }

    const clientPromise = this._connectFn(server, this.cfg)
    const conn: ServerConnection = {
      client: clientPromise,
      queue: old?.queue ?? Promise.resolve(),
    }
    this.connections.set(key, conn)
    this.servers.set(key, server)

    clientPromise.then(
      (client) => {
        this.emitEvent(server, {type: "connected"})
        this.wireDisconnectHandler(server, client, clientPromise)
      },
      () => {
        // Clean up failed connection if it is still the current one
        const cur = this.connections.get(key)
        if (cur && cur.client === clientPromise) {
          this.connections.delete(key)
          this.servers.delete(key)
        }
      }
    )

    return clientPromise
  }

  closeServer(server: SMPServerAddress): void {
    const key = serverKey(server)
    const conn = this.connections.get(key)
    if (conn) {
      this.connections.delete(key)
      this.servers.delete(key)
      conn.client.then(c => c.close(), () => {})
    }
  }

  closeAll(): void {
    this.destroyed = true
    for (const conn of this.connections.values()) {
      conn.client.then(c => c.close(), () => {})
    }
    this.connections.clear()
    this.servers.clear()

    if (typeof window !== "undefined") {
      window.removeEventListener("online", this.onlineHandler)
    }
    if (typeof document !== "undefined") {
      document.removeEventListener("visibilitychange", this.visibilityHandler)
    }
  }

  onConnectionChange(handler: ConnectionChangeHandler): void {
    this.connectionChangeHandler = handler
  }

  // -- Internal methods

  private createConnection(server: SMPServerAddress): Promise<SMPClient> {
    const key = serverKey(server)
    const clientPromise = this._connectFn(server, this.cfg)
    const conn: ServerConnection = {client: clientPromise, queue: Promise.resolve()}
    this.connections.set(key, conn)
    this.servers.set(key, server)

    clientPromise.then(
      (client) => {
        this.emitEvent(server, {type: "connected"})
        this.wireDisconnectHandler(server, client, clientPromise)
      },
      () => {
        // Clean up failed connection if it is still the current one
        const cur = this.connections.get(key)
        if (cur && cur.client === clientPromise) {
          this.connections.delete(key)
          this.servers.delete(key)
        }
      }
    )

    return clientPromise
  }

  private wireDisconnectHandler(
    server: SMPServerAddress,
    client: SMPClient,
    clientPromise: Promise<SMPClient>
  ): void {
    const transport = client.transport
    if (transport instanceof SMPWebSocketTransport) {
      transport.onClose(() => {
        this.handleDisconnect(server, clientPromise, "WebSocket connection closed")
      })
    }
  }

  private handleDisconnect(
    server: SMPServerAddress,
    disconnectedPromise: Promise<SMPClient>,
    reason: string
  ): void {
    if (this.destroyed) return
    const key = serverKey(server)
    const cur = this.connections.get(key)

    // Only handle if this is still the current connection
    if (!cur || cur.client !== disconnectedPromise) return

    this.connections.delete(key)
    this.emitEvent(server, {type: "disconnected", reason})

    // Trigger automatic reconnection
    this.reconnectWithBackoff(server).catch(() => {
      // reconnect_failed event already emitted inside reconnectWithBackoff
    })
  }

  private async reconnectWithBackoff(server: SMPServerAddress): Promise<SMPClient> {
    const maxAttempts = this.cfg.reconnectMaxAttempts

    for (let attempt = 0; attempt < maxAttempts; attempt++) {
      if (this.destroyed) {
        throw new SMPTransportError("CLOSED", "Agent destroyed during reconnection")
      }

      const delayMs = calculateBackoff(attempt, this.cfg)

      this.emitEvent(server, {
        type: "reconnecting",
        attempt: attempt + 1,
        maxAttempts,
        nextRetryMs: delayMs,
      })

      // Wait for navigator.onLine if available
      if (typeof navigator !== "undefined" && !navigator.onLine) {
        await waitForOnline()
      }

      await sleep(delayMs)

      try {
        const client = await this._connectFn(server, this.cfg)
        const key = serverKey(server)
        const conn: ServerConnection = {client: Promise.resolve(client), queue: Promise.resolve()}
        this.connections.set(key, conn)
        this.servers.set(key, server)
        this.emitEvent(server, {type: "connected"})
        this.wireDisconnectHandler(server, client, conn.client)
        return client
      } catch (_e) {
        // Connection failed, try next attempt
      }
    }

    // All attempts exhausted
    const msg = "Reconnection failed after " + maxAttempts + " attempts"
    this.emitEvent(server, {type: "reconnect_failed", reason: msg})
    throw new SMPTransportError("NETWORK", msg)
  }

  private reconnectAllDisconnected(): void {
    // Reconnect servers that were previously connected but got disconnected
    for (const [key, server] of this.servers.entries()) {
      if (!this.connections.has(key)) {
        this.reconnectWithBackoff(server).catch(() => {})
      }
    }
  }

  private checkStaleConnections(): void {
    for (const [key, conn] of this.connections.entries()) {
      conn.client.then((client) => {
        if (client.transport.state === "disconnected") {
          const server = this.servers.get(key)
          if (server) {
            this.handleDisconnect(server, conn.client, "Stale connection detected after tab wake")
          }
        }
      }, () => {})
    }
  }

  private emitEvent(server: SMPServerAddress, event: ConnectionEvent): void {
    if (this.connectionChangeHandler !== null) {
      this.connectionChangeHandler(server, event)
    }
  }
}

// -- Factory

export function newSMPAgent(config?: Partial<SMPAgentConfig>): SMPClientAgent {
  return new SMPClientAgentImpl(config)
}

// -- Helpers

function sleep(ms: number): Promise<void> {
  return new Promise(resolve => setTimeout(resolve, ms))
}

function waitForOnline(): Promise<void> {
  return new Promise(resolve => {
    if (typeof navigator !== "undefined" && navigator.onLine) {
      resolve()
      return
    }
    const handler = () => {
      if (typeof window !== "undefined") {
        window.removeEventListener("online", handler)
      }
      resolve()
    }
    if (typeof window !== "undefined") {
      window.addEventListener("online", handler)
    } else {
      // No window (e.g. tests), resolve immediately
      resolve()
    }
  })
}
