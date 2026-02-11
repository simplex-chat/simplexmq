import {test, expect, vi, beforeEach} from 'vitest'
import {
  newXFTPAgent, getXFTPServerClient, reconnectClient, removeStaleConnection,
  sendXFTPCommand,
  XFTPRetriableError, XFTPPermanentError,
  type XFTPClient, type XFTPClientAgent
} from '../src/client.js'
import {formatXFTPServer, type XFTPServer} from '../src/protocol/address.js'
import {blockPad} from '../src/protocol/transmission.js'
import {concatBytes, encodeBytes, encodeLarge} from '../src/protocol/encoding.js'

const server: XFTPServer = {
  keyHash: new Uint8Array(32),
  host: "localhost",
  port: "12345"
}
const key = formatXFTPServer(server)

function makeMockClient(overrides?: Partial<XFTPClient>): XFTPClient {
  return {
    baseUrl: "https://localhost:12345",
    sessionId: new Uint8Array(32),
    xftpVersion: 3,
    transport: {post: vi.fn(), close: vi.fn()},
    ...overrides
  }
}

function makeAgent(connectFn: (s: any) => Promise<XFTPClient>): XFTPClientAgent {
  const agent = newXFTPAgent()
  agent._connectFn = connectFn
  return agent
}

// T4: getXFTPServerClient coalesces concurrent calls
test('getXFTPServerClient coalesces concurrent calls', async () => {
  let resolve_: (v: XFTPClient) => void
  const promise = new Promise<XFTPClient>(r => { resolve_ = r })
  const connectFn = vi.fn(() => promise)
  const agent = makeAgent(connectFn)
  const p1 = getXFTPServerClient(agent, server)
  const p2 = getXFTPServerClient(agent, server)
  expect(p1).toBe(p2)  // same promise, single connection
  expect(connectFn).toHaveBeenCalledTimes(1)
  const mockClient = makeMockClient()
  resolve_!(mockClient)
  expect(await p1).toBe(mockClient)
})

// T5: getXFTPServerClient auto-cleans failed connections
test('getXFTPServerClient auto-cleans failed connections', async () => {
  const connectFn = vi.fn()
    .mockImplementationOnce(() => Promise.reject(new Error("down")))
    .mockImplementationOnce(() => Promise.resolve(makeMockClient()))
  const agent = makeAgent(connectFn)
  const p1 = getXFTPServerClient(agent, server)
  await expect(p1).rejects.toThrow("down")
  // After microtask, entry is removed
  await new Promise(r => setTimeout(r, 0))
  expect(agent.connections.has(key)).toBe(false)
  // Next call creates fresh connection
  const p2 = getXFTPServerClient(agent, server)
  expect(p2).not.toBe(p1)
  expect(connectFn).toHaveBeenCalledTimes(2)
})

// T6: removeStaleConnection respects promise identity
test('removeStaleConnection respects promise identity', () => {
  const agent = newXFTPAgent()
  const mockClient1 = makeMockClient()
  const mockClient2 = makeMockClient()
  const p1 = Promise.resolve(mockClient1)
  agent.connections.set(key, {client: p1, queue: Promise.resolve()})
  // Replace with reconnect
  const p2 = Promise.resolve(mockClient2)
  agent.connections.set(key, {client: p2, queue: Promise.resolve()})
  // removeStaleConnection with old promise does NOT remove new entry
  removeStaleConnection(agent, server, p1)
  expect(agent.connections.has(key)).toBe(true)
  expect(agent.connections.get(key)!.client).toBe(p2)
  // removeStaleConnection with current promise removes it
  removeStaleConnection(agent, server, p2)
  expect(agent.connections.has(key)).toBe(false)
})

// T7: reconnectClient replaces promise but preserves queue
test('reconnectClient replaces promise but preserves queue', async () => {
  const mockClient2 = makeMockClient()
  const connectFn = vi.fn(() => Promise.resolve(mockClient2))
  const agent = makeAgent(connectFn)
  const origQueue = Promise.resolve()
  agent.connections.set(key, {client: Promise.resolve(makeMockClient()), queue: origQueue})
  reconnectClient(agent, server)
  const conn = agent.connections.get(key)!
  expect(await conn.client).toBe(mockClient2)  // new client
  expect(conn.queue).toBe(origQueue)            // queue preserved
})

// T8: Retry loop — retriable error triggers reconnect, permanent does not
test('retry loop: retriable triggers reconnect, permanent does not', async () => {
  const sessionId = new Uint8Array(32)
  const dummyKey = new Uint8Array(64)
  const dummyId = new Uint8Array(0)
  const pingCmd = new TextEncoder().encode("PING")

  // Case 1: Retriable then success — 2 _connectFn calls
  const connectFn1 = vi.fn()
    .mockImplementationOnce(() => Promise.resolve(makeMockClient({
      sessionId,
      transport: {
        post: vi.fn().mockRejectedValueOnce(new XFTPRetriableError("SESSION")),
        close: vi.fn()
      }
    })))
    .mockImplementationOnce(() => Promise.resolve(makeMockClient({
      sessionId,
      transport: {
        post: vi.fn().mockResolvedValueOnce(buildPongResponse(sessionId)),
        close: vi.fn()
      }
    })))
  const agent1 = makeAgent(connectFn1)
  const result = await sendXFTPCommand(agent1, server, dummyKey, dummyId, pingCmd)
  expect(result.response.type).toBe("FRPong")
  expect(connectFn1).toHaveBeenCalledTimes(2)

  // Case 2: All 3 retries exhausted — 3 _connectFn calls
  const connectFn2 = vi.fn(() => Promise.resolve(makeMockClient({
    sessionId,
    transport: {
      post: vi.fn().mockRejectedValue(new XFTPRetriableError("SESSION")),
      close: vi.fn()
    }
  })))
  const agent2 = makeAgent(connectFn2)
  await expect(sendXFTPCommand(agent2, server, dummyKey, dummyId, pingCmd))
    .rejects.toThrow(/expired|reconnecting/)
  expect(connectFn2).toHaveBeenCalledTimes(3)

  // Case 3: Permanent error — 1 _connectFn call (no reconnect)
  const connectFn3 = vi.fn(() => Promise.resolve(makeMockClient({
    sessionId,
    transport: {
      post: vi.fn().mockRejectedValue(new XFTPPermanentError("AUTH", "expired")),
      close: vi.fn()
    }
  })))
  const agent3 = makeAgent(connectFn3)
  await expect(sendXFTPCommand(agent3, server, dummyKey, dummyId, pingCmd))
    .rejects.toThrow(/expired/)
  expect(connectFn3).toHaveBeenCalledTimes(1)
})

// Helper: build a valid XFTP PONG response block
function buildPongResponse(sessionId: Uint8Array): Uint8Array {
  const authenticator = encodeBytes(new Uint8Array(0))
  const sessBytes = encodeBytes(sessionId)
  const corrId = encodeBytes(new Uint8Array(0))
  const entityId = encodeBytes(new Uint8Array(0))
  const pong = new TextEncoder().encode("PONG")
  const transmission = concatBytes(authenticator, sessBytes, corrId, entityId, pong)
  const batch = concatBytes(new Uint8Array([1]), encodeLarge(transmission))
  return blockPad(batch)
}
