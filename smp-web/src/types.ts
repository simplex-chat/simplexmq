// GoChat transport types - ChatTransport interface and SMP transport types.
//
// ChatTransport is the day-one abstraction for GoChat's dual-profile
// architecture. ALL transport code MUST go through this interface.
// Application code NEVER talks to WebSocket directly.
//
// Season 2: SMPWebSocketTransport implements ChatTransport
// Season 9: GRPWebSocketTransport will implement ChatTransport

// -- Server address (parsed from SimpleX URI: smp://fingerprint@host:port)

export interface SMPServerAddress {
  host: string
  port: number
  keyHash: Uint8Array // SHA-256 fingerprint of CA cert (32 bytes)
}

// -- Transport state machine
//
// disconnected -> connecting  (on connect() call)
// connecting   -> connected   (on WebSocket 'open' event)
// connecting   -> disconnected (on timeout or error)
// connected    -> closing     (on close() call)
// connected    -> disconnected (on WebSocket 'close' or 'error' event)
// closing      -> disconnected (on WebSocket 'close' event)

export type TransportState = "disconnected" | "connecting" | "connected" | "closing"

// -- ChatTransport interface
//
// SMP is NOT request/response like XFTP. The server can push MSG at any time.
// The transport delivers raw 16KB blocks. The client layer (Season 2 Task 2)
// dispatches them by corrId (response to our command) vs empty corrId (server push).

export interface ChatTransport {
  connect(server: SMPServerAddress): Promise<void>
  send(block: Uint8Array): Promise<void>
  onMessage(handler: TransportEventHandler): void
  close(): void
  readonly state: TransportState
}

// -- Transport events (for async MSG handling)

export type TransportEventHandler = (block: Uint8Array) => void

// -- Error types

export type SMPTransportErrorCode =
  | "NETWORK"   // WebSocket connection failed
  | "TIMEOUT"   // Connection or handshake timeout
  | "CLOSED"    // Connection closed unexpectedly
  | "BLOCK_SIZE" // Received block is not exactly 16384 bytes
  | "HANDSHAKE" // Handshake failed (Season 2 Task 2)
  | "VERSION"   // Version negotiation failed (Season 2 Task 2)
  | "IDENTITY"  // Server identity verification failed (Season 2 Task 2)

export class SMPTransportError extends Error {
  constructor(
    public readonly code: SMPTransportErrorCode,
    message: string
  ) {
    super(message)
    this.name = "SMPTransportError"
  }
}

// -- SMPClient types (Season 2 Task 2)

export type SMPClientState = "handshaking" | "ready" | "closed"

export interface SMPResponseHandler {
  (corrId: Uint8Array, entityId: Uint8Array, command: Uint8Array): void
}

export interface SMPPushHandler {
  (entityId: Uint8Array, command: Uint8Array): void
}
