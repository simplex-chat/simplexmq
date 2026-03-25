import {describe, it, expect, vi, beforeEach, afterEach} from "vitest"
import {calculateBackoff, serverKey, newSMPAgent} from "../agent.js"
import type {SMPClientAgent} from "../agent.js"
import type {
  SMPServerAddress,
  ChatTransport,
  TransportState,
  TransportEventHandler,
  SMPClientState,
  SMPResponseHandler,
  SMPPushHandler,
  ConnectionEvent,
} from "../types.js"
import type {SMPClient} from "../client.js"

// -- Mock SMPClient

function createMockClient(server: SMPServerAddress): SMPClient {
  let closed = false
  const mockTransport: ChatTransport = {
    state: "connected" as TransportState,
    async connect() {},
    async send() {},
    onMessage() {},
    close() {
      (mockTransport as {state: TransportState}).state = "disconnected"
    },
  }

  return {
    sessionId: new Uint8Array(32),
    smpVersion: 7,
    transport: mockTransport,
    get state(): SMPClientState {
      return closed ? "closed" : "ready"
    },
    async sendCommand() {},
    onResponse() {},
    onServerPush() {},
    startKeepalive() {},
    close() {
      closed = true
      mockTransport.close()
    },
  }
}

const testServer1: SMPServerAddress = {
  host: "smp1.example.com",
  port: 443,
  keyHash: new Uint8Array(32).fill(0x01),
}

const testServer2: SMPServerAddress = {
  host: "smp2.example.com",
  port: 5223,
  keyHash: new Uint8Array(32).fill(0x02),
}

// -- calculateBackoff tests

describe("calculateBackoff", () => {
  it("returns correct exponential values (base 500, multiplier 2)", () => {
    // Use 0 jitter for deterministic testing
    const config = {reconnectJitter: 0}
    expect(calculateBackoff(0, config)).toBe(500)
    expect(calculateBackoff(1, config)).toBe(1000)
    expect(calculateBackoff(2, config)).toBe(2000)
    expect(calculateBackoff(3, config)).toBe(4000)
    expect(calculateBackoff(4, config)).toBe(8000)
    expect(calculateBackoff(5, config)).toBe(16000)
  })

  it("respects max cap at 30000ms (before jitter)", () => {
    const config = {reconnectJitter: 0}
    // Attempt 6+: 500 * 2^6 = 32000 -> capped to 30000
    expect(calculateBackoff(6, config)).toBe(30000)
    expect(calculateBackoff(10, config)).toBe(30000)
    expect(calculateBackoff(11, config)).toBe(30000)
  })

  it("applies jitter - result varies between runs", () => {
    const config = {reconnectJitter: 0.5}
    const results = new Set<number>()
    for (let i = 0; i < 20; i++) {
      results.add(calculateBackoff(0, config))
    }
    // With 50% jitter on 500ms base, values should be between 500 and 750
    // Multiple runs should produce different values
    expect(results.size).toBeGreaterThan(1)
    for (const val of results) {
      expect(val).toBeGreaterThanOrEqual(500)
      expect(val).toBeLessThanOrEqual(750)
    }
  })

  it("respects custom config values", () => {
    const config = {
      reconnectBaseMs: 100,
      reconnectMultiplier: 3,
      reconnectMaxMs: 5000,
      reconnectJitter: 0,
    }
    expect(calculateBackoff(0, config)).toBe(100)
    expect(calculateBackoff(1, config)).toBe(300)
    expect(calculateBackoff(2, config)).toBe(900)
    expect(calculateBackoff(3, config)).toBe(2700)
    expect(calculateBackoff(4, config)).toBe(5000) // capped
  })
})

// -- serverKey tests

describe("serverKey", () => {
  it("produces consistent keys for same server", () => {
    const key1 = serverKey(testServer1)
    const key2 = serverKey(testServer1)
    expect(key1).toBe(key2)
  })

  it("produces different keys for different servers", () => {
    expect(serverKey(testServer1)).not.toBe(serverKey(testServer2))
  })

  it("formats as host:port", () => {
    expect(serverKey(testServer1)).toBe("smp1.example.com:443")
    expect(serverKey(testServer2)).toBe("smp2.example.com:5223")
  })
})

// -- SMPClientAgent tests

describe("SMPClientAgent", () => {
  let agent: SMPClientAgent
  let mockConnectFn: ReturnType<typeof vi.fn>

  beforeEach(() => {
    agent = newSMPAgent()
    mockConnectFn = vi.fn(async (server: SMPServerAddress) => {
      return createMockClient(server)
    });
    // Inject mock connect function
    (agent as any)._connectFn = mockConnectFn
  })

  afterEach(() => {
    agent.closeAll()
  })

  it("creates empty agent with no connections initially", () => {
    // Calling closeAll on empty agent should not throw
    const freshAgent = newSMPAgent()
    freshAgent.closeAll()
  })

  it("getClient creates connection on first call", async () => {
    const client = await agent.getClient(testServer1)
    expect(client).toBeDefined()
    expect(client.smpVersion).toBe(7)
    expect(mockConnectFn).toHaveBeenCalledTimes(1)
  })

  it("getClient returns existing client on second call", async () => {
    const client1 = await agent.getClient(testServer1)
    const client2 = await agent.getClient(testServer1)
    expect(client1).toBe(client2)
    expect(mockConnectFn).toHaveBeenCalledTimes(1) // not called again
  })

  it("getClient creates separate connections for different servers", async () => {
    const client1 = await agent.getClient(testServer1)
    const client2 = await agent.getClient(testServer2)
    expect(client1).not.toBe(client2)
    expect(mockConnectFn).toHaveBeenCalledTimes(2)
  })

  it("closeServer removes connection and next getClient creates new", async () => {
    const client1 = await agent.getClient(testServer1)
    agent.closeServer(testServer1)

    const client2 = await agent.getClient(testServer1)
    expect(client2).not.toBe(client1)
    expect(mockConnectFn).toHaveBeenCalledTimes(2)
  })

  it("closeAll clears all connections", async () => {
    await agent.getClient(testServer1)
    await agent.getClient(testServer2)

    agent.closeAll()

    // Create a new agent since closeAll destroys it
    const newAgent = newSMPAgent();
    (newAgent as any)._connectFn = mockConnectFn
    mockConnectFn.mockClear()

    await newAgent.getClient(testServer1)
    expect(mockConnectFn).toHaveBeenCalledTimes(1) // fresh connection
    newAgent.closeAll()
  })

  it("reconnect replaces existing connection", async () => {
    const client1 = await agent.getClient(testServer1)
    const client2 = await agent.reconnect(testServer1)
    expect(client2).not.toBe(client1)
    expect(mockConnectFn).toHaveBeenCalledTimes(2)
  })

  it("reconnect works when no existing connection", async () => {
    const client = await agent.reconnect(testServer1)
    expect(client).toBeDefined()
    expect(mockConnectFn).toHaveBeenCalledTimes(1)
  })

  it("onConnectionChange fires connected event", async () => {
    const events: ConnectionEvent[] = []
    agent.onConnectionChange((_server, event) => {
      events.push(event)
    })

    await agent.getClient(testServer1)

    // Wait a tick for the async .then() callback
    await new Promise(r => setTimeout(r, 10))

    expect(events.some(e => e.type === "connected")).toBe(true)
  })

  it("closeServer on non-existent server is a no-op", () => {
    // Should not throw
    agent.closeServer(testServer1)
  })

  it("getClient cleans up on connect failure", async () => {
    let callCount = 0
    ;(agent as any)._connectFn = vi.fn(async () => {
      callCount++
      if (callCount === 1) throw new Error("connection failed")
      return createMockClient(testServer1)
    })

    // First call fails
    await expect(agent.getClient(testServer1)).rejects.toThrow("connection failed")

    // Wait for cleanup
    await new Promise(r => setTimeout(r, 10))

    // Second call should create new connection (not return failed promise)
    const client = await agent.getClient(testServer1)
    expect(client).toBeDefined()
  })
})

// -- ConnectionEvent type tests

describe("ConnectionEvent types", () => {
  it("connected event has correct shape", () => {
    const event: ConnectionEvent = {type: "connected"}
    expect(event.type).toBe("connected")
  })

  it("disconnected event has reason", () => {
    const event: ConnectionEvent = {type: "disconnected", reason: "WebSocket closed"}
    expect(event.type).toBe("disconnected")
    expect(event.reason).toBe("WebSocket closed")
  })

  it("reconnecting event has attempt info", () => {
    const event: ConnectionEvent = {
      type: "reconnecting",
      attempt: 3,
      maxAttempts: 12,
      nextRetryMs: 2000,
    }
    expect(event.type).toBe("reconnecting")
    expect(event.attempt).toBe(3)
    expect(event.maxAttempts).toBe(12)
    expect(event.nextRetryMs).toBe(2000)
  })

  it("reconnect_failed event has reason", () => {
    const event: ConnectionEvent = {
      type: "reconnect_failed",
      reason: "All 12 reconnection attempts failed",
    }
    expect(event.type).toBe("reconnect_failed")
    expect(event.reason).toContain("12")
  })
})
