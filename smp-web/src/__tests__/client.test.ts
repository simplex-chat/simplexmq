import {describe, it, expect, vi, beforeEach, afterEach} from "vitest"
import {connectSMP, encodePING} from "../client.js"
import {encodeTransmission, decodeTransmission} from "../protocol.js"
import {buildCommandBlock, parseResponseBlock, blockPad, blockUnpad} from "../handshake.js"
import {SMPTransportError} from "../types.js"
import type {
  ChatTransport,
  SMPServerAddress,
  TransportState,
  TransportEventHandler,
  SMPResponseHandler,
  SMPPushHandler,
} from "../types.js"
import {SMP_BLOCK_SIZE} from "../transport.js"
import {
  Decoder, concatBytes, encodeBytes, encodeLarge,
} from "@simplex-chat/xftp-web/dist/protocol/encoding.js"

// -- Mock WebSocket (same as transport tests)

class MockWebSocket {
  static instances: MockWebSocket[] = []
  binaryType = "blob"
  readyState = 0
  private listeners: Record<string, Array<(event: unknown) => void>> = {}

  constructor(public url: string) {
    MockWebSocket.instances.push(this)
  }

  addEventListener(type: string, listener: (event: unknown) => void): void {
    if (!this.listeners[type]) this.listeners[type] = []
    this.listeners[type].push(listener)
  }

  removeEventListener(): void {}

  send(_data: unknown): void {}

  close(): void {
    this.readyState = 3
    this.emit("close", {})
  }

  emit(type: string, event: unknown): void {
    const handlers = this.listeners[type] || []
    for (const handler of handlers) handler(event)
  }

  simulateOpen(): void {
    this.readyState = 1
    this.emit("open", {})
  }

  simulateError(): void {
    this.emit("error", {})
  }

  simulateMessage(data: ArrayBuffer): void {
    this.emit("message", {data})
  }
}

// -- Mock transport for client dispatch tests

class MockTransport implements ChatTransport {
  currentState: TransportState = "disconnected"
  messageHandler: TransportEventHandler | null = null
  sentBlocks: Uint8Array[] = []

  get state(): TransportState {
    return this.currentState
  }

  async connect(_server: SMPServerAddress): Promise<void> {
    this.currentState = "connected"
  }

  async send(block: Uint8Array): Promise<void> {
    this.sentBlocks.push(block)
  }

  onMessage(handler: TransportEventHandler): void {
    this.messageHandler = handler
  }

  close(): void {
    this.currentState = "disconnected"
  }

  // Test helper: inject a message as if received from server
  injectMessage(block: Uint8Array): void {
    if (this.messageHandler) {
      this.messageHandler(block)
    }
  }
}

const testServer: SMPServerAddress = {
  host: "smp.example.com",
  port: 443,
  keyHash: new Uint8Array(32),
}

describe("connectSMP", () => {
  let originalWebSocket: typeof globalThis.WebSocket

  beforeEach(() => {
    MockWebSocket.instances = []
    originalWebSocket = globalThis.WebSocket
    globalThis.WebSocket = MockWebSocket as unknown as typeof WebSocket
  })

  afterEach(() => {
    globalThis.WebSocket = originalWebSocket
  })

  it("rejects on transport connect failure (network error)", async () => {
    const connectPromise = connectSMP(testServer, {connectTimeoutMs: 100})
    const ws = MockWebSocket.instances[0]
    ws.simulateError()

    await expect(connectPromise).rejects.toThrow(SMPTransportError)
    try {
      await connectPromise
    } catch (e) {
      expect((e as SMPTransportError).code).toBe("NETWORK")
    }
  })

  it("rejects on handshake timeout (no ServerHello received)", async () => {
    const connectPromise = connectSMP(testServer, {
      connectTimeoutMs: 50,
      handshakeTimeoutMs: 50,
    })
    const ws = MockWebSocket.instances[0]
    // WebSocket connects successfully
    ws.simulateOpen()
    // But server never sends ServerHello - should timeout

    await expect(connectPromise).rejects.toThrow(SMPTransportError)
    try {
      await connectPromise
    } catch (e) {
      expect((e as SMPTransportError).code).toBe("TIMEOUT")
      expect((e as SMPTransportError).message).toContain("ServerHello")
    }
  })
})

describe("encodePING", () => {
  it("produces correct ASCII bytes for PING", () => {
    const ping = encodePING()
    expect(ping).toEqual(new Uint8Array([0x50, 0x49, 0x4e, 0x47]))
  })

  it("decodes back to 'PING' string", () => {
    const ping = encodePING()
    const text = String.fromCharCode(...ping)
    expect(text).toBe("PING")
  })
})

describe("command dispatch", () => {
  it("separates responses from pushes by corrId", () => {
    // Build a response block (non-empty corrId = response to our command)
    const corrId = new Uint8Array(24).fill(0x42)
    const entityId = new Uint8Array(8).fill(0x01)
    const commandBytes = new TextEncoder().encode("OK")
    const transmission = encodeTransmission(corrId, entityId, commandBytes)
    const responseBlock = buildCommandBlock(transmission)

    // Build a push block (empty corrId = server push)
    const pushEntityId = new Uint8Array(8).fill(0x02)
    const pushCommand = new TextEncoder().encode("MSG")
    const pushTransmission = encodeTransmission(new Uint8Array(0), pushEntityId, pushCommand)
    const pushBlock = buildCommandBlock(pushTransmission)

    // Verify response block parses with non-empty corrId
    const respTxBytes = parseResponseBlock(responseBlock)
    const respTd = new Decoder(respTxBytes)
    const resp = decodeTransmission(respTd)
    expect(resp.corrId.length).toBeGreaterThan(0)
    expect(resp.corrId).toEqual(corrId)

    // Verify push block parses with empty corrId
    const pushTxBytes = parseResponseBlock(pushBlock)
    const pushTd = new Decoder(pushTxBytes)
    const push = decodeTransmission(pushTd)
    expect(push.corrId.length).toBe(0)
  })

  it("buildCommandBlock produces exactly 16384 bytes", () => {
    const corrId = new Uint8Array(24).fill(0x01)
    const transmission = encodeTransmission(corrId, new Uint8Array(0), encodePING())
    const block = buildCommandBlock(transmission)
    expect(block.length).toBe(SMP_BLOCK_SIZE)
  })

  it("parseResponseBlock roundtrips with buildCommandBlock", () => {
    const corrId = new Uint8Array(24)
    corrId[0] = 0xff
    corrId[23] = 0xee
    const entityId = new Uint8Array(4).fill(0xab)
    const command = new TextEncoder().encode("PONG")
    const transmission = encodeTransmission(corrId, entityId, command)
    const block = buildCommandBlock(transmission)

    // Parse it back
    const txBytes = parseResponseBlock(block)
    const td = new Decoder(txBytes)
    const parsed = decodeTransmission(td)

    expect(parsed.corrId).toEqual(corrId)
    expect(parsed.entityId).toEqual(entityId)
    expect(String.fromCharCode(...parsed.command)).toBe("PONG")
  })
})
