import {describe, it, expect, vi, beforeEach, afterEach} from "vitest"
import {
  SMPWebSocketTransport,
} from "../transport.js"
import {
  SMPTransportError,
} from "../types.js"
import type {
  ChatTransport,
  SMPServerAddress,
  TransportState,
  TransportEventHandler,
  SMPTransportErrorCode,
} from "../types.js"

// -- Type export tests

describe("types.ts exports", () => {
  it("SMPTransportError is constructable with code and message", () => {
    const err = new SMPTransportError("NETWORK", "test error")
    expect(err).toBeInstanceOf(Error)
    expect(err).toBeInstanceOf(SMPTransportError)
    expect(err.code).toBe("NETWORK")
    expect(err.message).toBe("test error")
    expect(err.name).toBe("SMPTransportError")
  })

  it("all error codes are valid string literals", () => {
    const codes: SMPTransportErrorCode[] = [
      "NETWORK", "TIMEOUT", "CLOSED", "BLOCK_SIZE",
      "HANDSHAKE", "VERSION", "IDENTITY",
    ]
    expect(codes).toHaveLength(7)
  })
})

// -- Mock WebSocket for unit tests

class MockWebSocket {
  static instances: MockWebSocket[] = []
  binaryType = "blob"
  readyState = 0 // CONNECTING
  private listeners: Record<string, Array<(event: unknown) => void>> = {}

  constructor(public url: string) {
    MockWebSocket.instances.push(this)
  }

  addEventListener(type: string, listener: (event: unknown) => void): void {
    if (!this.listeners[type]) this.listeners[type] = []
    this.listeners[type].push(listener)
  }

  removeEventListener(): void {
    // not needed for tests
  }

  send(_data: unknown): void {
    // mock send
  }

  close(): void {
    this.readyState = 3 // CLOSED
    this.emit("close", {})
  }

  // Test helpers

  emit(type: string, event: unknown): void {
    const handlers = this.listeners[type] || []
    for (const handler of handlers) {
      handler(event)
    }
  }

  simulateOpen(): void {
    this.readyState = 1 // OPEN
    this.emit("open", {})
  }

  simulateError(): void {
    this.emit("error", {})
  }

  simulateMessage(data: ArrayBuffer): void {
    this.emit("message", {data})
  }
}

// -- Transport unit tests

describe("SMPWebSocketTransport", () => {
  let originalWebSocket: typeof globalThis.WebSocket

  beforeEach(() => {
    MockWebSocket.instances = []
    originalWebSocket = globalThis.WebSocket
    globalThis.WebSocket = MockWebSocket as unknown as typeof WebSocket
  })

  afterEach(() => {
    globalThis.WebSocket = originalWebSocket
  })

  const testServer: SMPServerAddress = {
    host: "smp.example.com",
    port: 443,
    keyHash: new Uint8Array(32),
  }

  it("state starts as disconnected", () => {
    const transport = new SMPWebSocketTransport()
    expect(transport.state).toBe("disconnected")
  })

  it("implements ChatTransport interface", () => {
    const transport: ChatTransport = new SMPWebSocketTransport()
    expect(typeof transport.connect).toBe("function")
    expect(typeof transport.send).toBe("function")
    expect(typeof transport.onMessage).toBe("function")
    expect(typeof transport.close).toBe("function")
    expect(transport.state).toBe("disconnected")
  })

  it("send() throws CLOSED when not connected", async () => {
    const transport = new SMPWebSocketTransport()
    const block = new Uint8Array(16384)

    await expect(transport.send(block)).rejects.toThrow(SMPTransportError)
    try {
      await transport.send(block)
    } catch (e) {
      expect(e).toBeInstanceOf(SMPTransportError)
      expect((e as SMPTransportError).code).toBe("CLOSED")
    }
  })

  it("send() throws BLOCK_SIZE on wrong block size", async () => {
    const transport = new SMPWebSocketTransport()

    // Connect first
    const connectPromise = transport.connect(testServer)
    const ws = MockWebSocket.instances[0]
    ws.simulateOpen()
    await connectPromise

    const smallBlock = new Uint8Array(100)
    await expect(transport.send(smallBlock)).rejects.toThrow(SMPTransportError)
    try {
      await transport.send(smallBlock)
    } catch (e) {
      expect(e).toBeInstanceOf(SMPTransportError)
      expect((e as SMPTransportError).code).toBe("BLOCK_SIZE")
    }
  })

  it("connect() transitions state to connecting then connected", async () => {
    const transport = new SMPWebSocketTransport()
    expect(transport.state).toBe("disconnected")

    const connectPromise = transport.connect(testServer)
    expect(transport.state).toBe("connecting")

    const ws = MockWebSocket.instances[0]
    ws.simulateOpen()
    await connectPromise

    expect(transport.state).toBe("connected")
  })

  it("connect() creates WSS URL correctly", async () => {
    const transport = new SMPWebSocketTransport()
    const connectPromise = transport.connect(testServer)
    const ws = MockWebSocket.instances[0]

    expect(ws.url).toBe("wss://smp.example.com:443")

    ws.simulateOpen()
    await connectPromise
  })

  it("connect() sets binaryType to arraybuffer", async () => {
    const transport = new SMPWebSocketTransport()
    const connectPromise = transport.connect(testServer)
    const ws = MockWebSocket.instances[0]

    expect(ws.binaryType).toBe("arraybuffer")

    ws.simulateOpen()
    await connectPromise
  })

  it("connect() rejects with TIMEOUT when server is unreachable", async () => {
    const transport = new SMPWebSocketTransport({connectTimeoutMs: 50})
    const connectPromise = transport.connect(testServer)

    // Do not simulate open - let it time out
    await expect(connectPromise).rejects.toThrow(SMPTransportError)
    try {
      await transport.connect(testServer) // will fail because state check
    } catch (e) {
      // state should be back to disconnected after timeout
    }
    // After timeout, state should be disconnected
    // (need to wait for the original promise to reject first)
  })

  it("connect() rejects with TIMEOUT and correct error code", async () => {
    const transport = new SMPWebSocketTransport({connectTimeoutMs: 50})

    try {
      const connectPromise = transport.connect(testServer)
      await connectPromise
    } catch (e) {
      expect(e).toBeInstanceOf(SMPTransportError)
      expect((e as SMPTransportError).code).toBe("TIMEOUT")
      expect(transport.state).toBe("disconnected")
    }
  })

  it("connect() rejects with NETWORK on WebSocket error", async () => {
    const transport = new SMPWebSocketTransport()
    const connectPromise = transport.connect(testServer)
    const ws = MockWebSocket.instances[0]

    ws.simulateError()

    await expect(connectPromise).rejects.toThrow(SMPTransportError)
  })

  it("send() sends exact 16384-byte block", async () => {
    const transport = new SMPWebSocketTransport()
    const connectPromise = transport.connect(testServer)
    const ws = MockWebSocket.instances[0]
    const sendSpy = vi.spyOn(ws, "send")

    ws.simulateOpen()
    await connectPromise

    const block = new Uint8Array(16384)
    block[0] = 0x42
    await transport.send(block)

    expect(sendSpy).toHaveBeenCalledOnce()
    expect(sendSpy).toHaveBeenCalledWith(block)
  })

  it("onMessage delivers 16384-byte blocks to handler", async () => {
    const transport = new SMPWebSocketTransport()
    const received: Uint8Array[] = []
    transport.onMessage((block) => received.push(block))

    const connectPromise = transport.connect(testServer)
    const ws = MockWebSocket.instances[0]
    ws.simulateOpen()
    await connectPromise

    const data = new ArrayBuffer(16384)
    new Uint8Array(data)[0] = 0xff
    ws.simulateMessage(data)

    expect(received).toHaveLength(1)
    expect(received[0].length).toBe(16384)
    expect(received[0][0]).toBe(0xff)
  })

  it("onMessage handler is last-one-wins", async () => {
    const transport = new SMPWebSocketTransport()
    const first: Uint8Array[] = []
    const second: Uint8Array[] = []

    transport.onMessage((block) => first.push(block))
    transport.onMessage((block) => second.push(block))

    const connectPromise = transport.connect(testServer)
    const ws = MockWebSocket.instances[0]
    ws.simulateOpen()
    await connectPromise

    ws.simulateMessage(new ArrayBuffer(16384))

    expect(first).toHaveLength(0)
    expect(second).toHaveLength(1)
  })

  it("close() transitions through closing to disconnected", async () => {
    const transport = new SMPWebSocketTransport()
    const connectPromise = transport.connect(testServer)
    const ws = MockWebSocket.instances[0]
    ws.simulateOpen()
    await connectPromise

    expect(transport.state).toBe("connected")
    transport.close()
    // After ws.close() fires the close event, state should be disconnected
    expect(transport.state).toBe("disconnected")
  })

  it("close() on disconnected transport is a no-op", () => {
    const transport = new SMPWebSocketTransport()
    expect(transport.state).toBe("disconnected")
    transport.close() // should not throw
    expect(transport.state).toBe("disconnected")
  })
})
