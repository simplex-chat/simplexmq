// AgentClient — agent state, worker infrastructure, locking, server selection.
// Transpilation of Agent/Client.hs (AgentClient record, workers, operation state, locks, server selection).
// Session management and queue operations will be added in subsequent steps.

import {ABQueue} from "./queue.js"
import {TMVar} from "./tmvar.js"
import {Sem} from "./queue.js"
import {TSessionSubs} from "./subscriptions.js"
import type {AgentStore} from "./store.js"
import type {RetryInterval2} from "./retry.js"

// -- Error types (Client.hs:2296-2310 storeError, Client.hs:2104-2115 cryptoError)

export class AgentError extends Error {
  constructor(public readonly type: AgentErrorType) {
    super(agentErrorToString(type))
  }
}

export type AgentErrorType =
  | {tag: "AGENT", err: AgentErr}
  | {tag: "BROKER", addr: string, err: BrokerErr}
  | {tag: "SMP", addr: string, err: string}
  | {tag: "PROXY", proxyServer: string, relayServer: string, proxyErr: string}
  | {tag: "CONN", err: ConnErr, context: string}
  | {tag: "CMD", err: CmdErr, context: string}
  | {tag: "INTERNAL", msg: string}
  | {tag: "CRITICAL", important: boolean, msg: string}
  | {tag: "INACTIVE"}
  | {tag: "NO_USER"}

export type AgentErr =
  | "A_VERSION" | "A_ENCRYPTION" | "A_DUPLICATE" | "A_PROHIBITED" | "A_MESSAGE"
  | {tag: "A_QUEUE", msg: string}
  | {tag: "A_CRYPTO", err: string}

export type BrokerErr = "TIMEOUT" | "NETWORK" | "HOST" | "TRANSPORT" | {tag: "RESPONSE", err: string} | {tag: "UNEXPECTED", msg: string}

export type ConnErr = "NOT_FOUND" | "DUPLICATE" | "SIMPLEX" | "NOT_ACCEPTED" | "NOT_AVAILABLE"

export type CmdErr = "PROHIBITED" | "SYNTAX" | "NO_CONN" | {tag: "LARGE", msg: string}

function agentErrorToString(e: AgentErrorType): string {
  switch (e.tag) {
    case "INTERNAL": return `INTERNAL: ${e.msg}`
    case "CRITICAL": return `CRITICAL: ${e.msg}`
    case "AGENT": return `AGENT ${typeof e.err === "string" ? e.err : e.err.tag}`
    case "BROKER": return `BROKER ${e.addr} ${typeof e.err === "string" ? e.err : e.err.tag}`
    case "SMP": return `SMP ${e.addr} ${e.err}`
    case "CONN": return `CONN ${e.err} ${e.context}`
    case "CMD": return `CMD ${typeof e.err === "string" ? e.err : e.err.tag} ${e.context}`
    default: return e.tag
  }
}

// -- Agent config (Env/SQLite.hs:136-180, 182-205)

export interface AgentConfig {
  tbqSize: number
  connIdBytes: number
  smpAgentVRange: [number, number]  // [min, max]
  smpClientVRange: [number, number]
  e2eEncryptVRange: [number, number]
  messageRetryInterval: RetryInterval2
  messageTimeout: number  // ms
  helloTimeout: number    // ms
  quotaExceededTimeout: number  // ms
  maxWorkerRestartsPerMin: number
}

export const defaultAgentConfig: AgentConfig = {
  tbqSize: 128,
  connIdBytes: 12,
  smpAgentVRange: [1, 8],
  smpClientVRange: [7, 18],
  e2eEncryptVRange: [1, 2],
  messageRetryInterval: {
    riFast: {initialInterval: 2_000_000, increaseAfter: 10_000_000, maxInterval: 120_000_000},
    riSlow: {initialInterval: 300_000_000, increaseAfter: 60_000_000, maxInterval: 6 * 3600_000_000},
  },
  messageTimeout: 2 * 86400_000,
  helloTimeout: 2 * 86400_000,
  quotaExceededTimeout: 7 * 86400_000,
  maxWorkerRestartsPerMin: 5,
}

// -- Server types

export interface SMPServerWithAuth {
  server: string  // serialized server address
  auth: Uint8Array | null
}

export interface UserServers {
  storageSrvs: Array<[number | null, SMPServerWithAuth]>  // [(Maybe OperatorId, ProtoServerWithAuth)]
  proxySrvs: Array<[number | null, SMPServerWithAuth]>
  knownHosts: Set<string>
}

// -- Worker (Env/SQLite.hs:317-332)

export interface Worker {
  workerId: number
  doWork: TMVar<void>
  action: TMVar<number | null>  // null = not running, number = "running" placeholder (no threadId in JS)
  restarts: {restartMinute: number, restartCount: number}
}

// updateRestartCount (Env/SQLite.hs:329-332)
function updateRestartCount(now: number, rc: {restartMinute: number, restartCount: number}): {restartMinute: number, restartCount: number} {
  const min = Math.floor(now / 60000)
  return {restartMinute: min, restartCount: min === rc.restartMinute ? rc.restartCount + 1 : 1}
}

// -- AgentOperation (Client.hs:456-470)

export type AgentOperation = "AORcvNetwork" | "AOMsgDelivery" | "AOSndNetwork" | "AODatabase"

export interface AgentOpState {
  opSuspended: boolean
  opsInProgress: number
}

export type AgentState = "ASForeground" | "ASSuspending" | "ASSuspended"

// -- ATransmission event type

export type ATransmission = [string, Uint8Array, any]  // (corrId, connId, event)

// -- AgentClient (Client.hs:328-378)

export interface AgentClient {
  active: boolean
  subQ: ABQueue<ATransmission>
  // msgQ is per-client, stored in smpClients
  config: AgentConfig
  store: AgentStore
  smpServers: Map<number, UserServers>  // userId → servers
  smpClients: Map<string, any>  // tSessKey → SMPClient or pending
  smpProxiedRelays: Map<string, SMPServerWithAuth>
  userNetworkInfo: {networkType: string, online: boolean}
  subscrConns: Set<string>  // hex connIds being subscribed
  currentSubs: TSessionSubs
  workerSeq: number
  smpDeliveryWorkers: Map<string, {worker: Worker, retryLock: TMVar<void>}>
  asyncCmdWorkers: Map<string, Worker>
  rcvNetworkOp: AgentOpState
  msgDeliveryOp: AgentOpState
  sndNetworkOp: AgentOpState
  databaseOp: AgentOpState
  agentState: AgentState
  connLocks: Map<string, Sem>
  invLocks: Map<string, Sem>
  randomServer: {gen: () => number}  // random index generator
}

// newAgentClient (Client.hs:498-584)
export function newAgentClient(config: AgentConfig, store: AgentStore, smpServers: Map<number, UserServers>): AgentClient {
  return {
    active: true,
    subQ: new ABQueue<ATransmission>(config.tbqSize),
    config,
    store,
    smpServers,
    smpClients: new Map(),
    smpProxiedRelays: new Map(),
    userNetworkInfo: {networkType: "UNOther", online: true},
    subscrConns: new Set(),
    currentSubs: new TSessionSubs(),
    workerSeq: 0,
    smpDeliveryWorkers: new Map(),
    asyncCmdWorkers: new Map(),
    rcvNetworkOp: {opSuspended: false, opsInProgress: 0},
    msgDeliveryOp: {opSuspended: false, opsInProgress: 0},
    sndNetworkOp: {opSuspended: false, opsInProgress: 0},
    databaseOp: {opSuspended: false, opsInProgress: 0},
    agentState: "ASForeground",
    connLocks: new Map(),
    invLocks: new Map(),
    randomServer: {gen: () => Math.random()},
  }
}

// -- Worker functions (Client.hs:439-454, 2118-2176)

// newWorker (Client.hs:439-445)
export function newWorker(c: AgentClient): Worker {
  const workerId = c.workerSeq++
  return {
    workerId,
    doWork: TMVar.new<void>(undefined),  // starts with "has work"
    action: TMVar.new<number | null>(null),  // not running
    restarts: {restartMinute: 0, restartCount: 0},
  }
}

// waitForWork (Client.hs:2118-2119)
export function waitForWork(doWork: TMVar<void>): Promise<void> {
  return doWork.read().then(() => {})
}

// noWorkToDo (Client.hs:2167-2168)
export function noWorkToDo(doWork: TMVar<void>): void {
  doWork.tryTake()
}

// hasWorkToDo (Client.hs:2171-2172)
export function hasWorkToDo(w: Worker): void {
  hasWorkToDo_(w.doWork)
}

// hasWorkToDo' (Client.hs:2175-2176)
export function hasWorkToDo_(doWork: TMVar<void>): void {
  doWork.tryPut(undefined)
}

// runWorkerAsync (Client.hs:447-454)
// Ensures work runs at most once concurrently. If already running, no-op.
// In Haskell this uses bracket + forkIO. In JS, fire-and-forget Promise.
//
// bracket (takeTMVar action) (tryPutTMVar action) (\a -> when (isNothing a) start)
// start = putTMVar action . Just =<< mkWeakThreadId =<< forkIO work
export async function runWorkerAsync(w: Worker, work: () => Promise<void>): Promise<void> {
  const a = await w.action.take()
  if (a !== null) {
    // Already running — put back and return
    w.action.tryPut(a)
    return
  }
  // Mark as running, start work in background
  await w.action.put(1)
  // forkIO — fire and forget. Work function contains its own restart loop (runWork).
  // When work eventually stops (max restarts or worker removed), reset action to null.
  work().catch(() => {}).finally(() => {
    w.action.tryTake()
    w.action.tryPut(null)
  })
}

// getAgentWorker (Client.hs:387-437)
// Get or create a worker for the given key. If hasWork=true, signal the worker.
// Starts the worker async loop if not already running.
// The work function should use `forever` internally — this function handles crash restart.
export async function getAgentWorker(
  name: string,
  hasWork_: boolean,
  c: AgentClient,
  key: string,
  workers: Map<string, Worker>,
  work: (w: Worker) => Promise<void>,
): Promise<Worker> {
  // getWorker >>= maybe createWorker whenExists
  let w = workers.get(key)
  if (w) {
    if (hasWork_) hasWorkToDo(w)
  } else {
    w = newWorker(c)
    workers.set(key, w)
  }
  const worker = w
  // runWorker w = runWorkerAsync (toW w) runWork
  await runWorkerAsync(worker, () => runWork(name, c, key, workers, worker, work))
  return worker
}

// runWork (Client.hs:405-413) — runs work, on error checks whether to restart
async function runWork(
  name: string,
  c: AgentClient,
  key: string,
  workers: Map<string, Worker>,
  worker: Worker,
  work: (w: Worker) => Promise<void>,
): Promise<void> {
  // tryAllErrors' (work w) >>= restartOrDelete
  let error: unknown = undefined
  try {
    await work(worker)
  } catch (e) {
    error = e
  }
  // restartOrDelete (Client.hs:407-413)
  const now = Date.now()
  // getWorker >>= maybe (pure False) (shouldRestart ...)
  const currentWorker = workers.get(key)
  if (!currentWorker) return  // worker was removed from map, don't restart
  if (currentWorker.workerId !== worker.workerId) return  // replaced by new worker
  // shouldRestart (Client.hs:414-437)
  const rc = updateRestartCount(now, worker.restarts)
  const isActive = c.active
  const errStr = error !== undefined ? `, error: ${error}` : ", no error"
  const msg = `Worker ${name} for ${key} terminated ${rc.restartCount} times${errStr}`
  if (isActive && rc.restartCount < c.config.maxWorkerRestartsPerMin) {
    // checkRestarts: restart
    worker.restarts = rc
    hasWorkToDo_(worker.doWork)
    worker.action.tryTake()
    worker.action.tryPut(null)
    c.subQ.enqueue(["", new Uint8Array(0), {tag: "ERR", err: {tag: "INTERNAL", msg}}])
    // when restart runWork — restart the worker
    await runWork(name, c, key, workers, worker, work)
  } else {
    // checkRestarts: delete
    workers.delete(key)
    if (isActive) {
      c.subQ.enqueue(["", new Uint8Array(0), {tag: "ERR", err: {tag: "CRITICAL", important: true, msg}}])
    }
  }
}

// withWork_ (Client.hs:2126-2140)
// Clear work signal, get work from store, if found re-signal and run action.
export async function withWork<T>(
  c: AgentClient,
  doWork: TMVar<void>,
  getWork: () => Promise<T | null>,
  action: (item: T) => Promise<void>,
): Promise<void> {
  noWorkToDo(doWork)
  let item: T | null
  try {
    item = await getWork()
  } catch (e) {
    hasWorkToDo_(doWork)
    const msg = `withWork error: ${e}`
    c.subQ.enqueue(["", new Uint8Array(0), {tag: "ERR", err: {tag: "INTERNAL", msg}}])
    return
  }
  if (item !== null) {
    hasWorkToDo_(doWork)
    await action(item)
  }
}

// -- Operation state (Client.hs:2179-2253)

function agentOpState(c: AgentClient, op: AgentOperation): AgentOpState {
  switch (op) {
    case "AORcvNetwork": return c.rcvNetworkOp
    case "AOMsgDelivery": return c.msgDeliveryOp
    case "AOSndNetwork": return c.sndNetworkOp
    case "AODatabase": return c.databaseOp
  }
}

// beginAgentOperation (Client.hs:2223-2230)
export function beginAgentOperation(c: AgentClient, op: AgentOperation): void {
  const s = agentOpState(c, op)
  if (s.opSuspended) throw new AgentError({tag: "INACTIVE"})
  s.opsInProgress++
}

// endAgentOperation (Client.hs:2179-2197)
export function endAgentOperation(c: AgentClient, op: AgentOperation): void {
  const s = agentOpState(c, op)
  s.opsInProgress = Math.max(0, s.opsInProgress - 1)
  if (s.opSuspended && s.opsInProgress === 0 && c.agentState === "ASSuspending") {
    cascadeSuspend(c, op)
  }
}

function cascadeSuspend(c: AgentClient, op: AgentOperation): void {
  switch (op) {
    case "AORcvNetwork":
      suspendOp(c, "AOMsgDelivery", () => suspendSendingAndDatabase(c))
      break
    case "AOMsgDelivery":
      suspendSendingAndDatabase(c)
      break
    case "AOSndNetwork":
      suspendOp(c, "AODatabase", () => notifySuspended(c))
      break
    case "AODatabase":
      notifySuspended(c)
      break
  }
}

function suspendSendingAndDatabase(c: AgentClient): void {
  suspendOp(c, "AOSndNetwork", () => suspendOp(c, "AODatabase", () => notifySuspended(c)))
}

function suspendOp(c: AgentClient, op: AgentOperation, endedAction: () => void): void {
  const s = agentOpState(c, op)
  s.opSuspended = true
  if (s.opsInProgress === 0 && c.agentState === "ASSuspending") endedAction()
}

function notifySuspended(c: AgentClient): void {
  c.subQ.enqueue(["", new Uint8Array(0), {tag: "SUSPENDED"}])
  c.agentState = "ASSuspended"
}

// throwWhenInactive (Client.hs:959-962)
export function throwWhenInactive(c: AgentClient): void {
  if (!c.active) throw new AgentError({tag: "INACTIVE"})
}

// waitForUserNetwork (Client.hs:924-928)
// In browser: if offline, we just throw. No blocking wait.
export function checkUserNetwork(c: AgentClient): void {
  if (!c.userNetworkInfo.online) throw new AgentError({tag: "BROKER", addr: "", err: "NETWORK"})
}

// -- Locking (Lock.hs, Client.hs:1003-1030)

// withConnLock (Client.hs:1003-1006)
export async function withConnLock<T>(c: AgentClient, connId: Uint8Array, fn: () => Promise<T>): Promise<T> {
  const key = toHex(connId)
  return withLock(c.connLocks, key, fn)
}

// withInvLock (Client.hs:1012-1015)
export async function withInvLock<T>(c: AgentClient, invKey: Uint8Array, fn: () => Promise<T>): Promise<T> {
  return withLock(c.invLocks, toHex(invKey), fn)
}

async function withLock<T>(locks: Map<string, Sem>, key: string, fn: () => Promise<T>): Promise<T> {
  let sem = locks.get(key)
  if (!sem) { sem = new Sem(1); locks.set(key, sem) }
  await sem.wait()
  try { return await fn() } finally { sem.signal() }
}

// -- Server selection (Client.hs:2312-2394)

// getNextServer (Client.hs:2325-2334)
export function getNextServer(
  c: AgentClient,
  userId: number,
  srvsSel: (us: UserServers) => Array<[number | null, SMPServerWithAuth]>,
  usedSrvs: string[],
): SMPServerWithAuth {
  const us = c.smpServers.get(userId)
  if (!us) throw new AgentError({tag: "INTERNAL", msg: "unknown userId - no user servers"})
  const srvs = srvsSel(us)
  if (srvs.length === 0) throw new AgentError({tag: "INTERNAL", msg: "no servers configured"})
  const usedHosts = new Set(usedSrvs)
  // Prefer servers with unused hosts
  const unused = srvs.filter(([, s]) => !usedHosts.has(s.server))
  const pool = unused.length > 0 ? unused : srvs
  return pickServer(pool, c.randomServer)
}

// pickServer (Client.hs:2318-2323)
function pickServer(
  srvs: Array<[number | null, SMPServerWithAuth]>,
  rng: {gen: () => number},
): SMPServerWithAuth {
  if (srvs.length === 1) return srvs[0][1]
  const idx = Math.floor(rng.gen() * srvs.length)
  return srvs[idx][1]
}

// -- Helpers

function toHex(b: Uint8Array): string {
  return Array.from(b, x => x.toString(16).padStart(2, "0")).join("")
}
