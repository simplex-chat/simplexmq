// Tests for concurrency primitives, session, retry, and subscriptions.

import {TMVar} from "../dist/agent/tmvar.js"
import {Sem, ABQueue} from "../dist/agent/queue.js"
import {getSessVar, removeSessVar, tryReadSessVar} from "../dist/agent/session.js"
import {nextRetryDelay, type RetryInterval} from "../dist/agent/retry.js"
import {TSessionSubs, type RcvQueueSub} from "../dist/agent/subscriptions.js"

let passed = 0
let failed = 0

function assert(cond: boolean, msg: string) {
  if (!cond) { console.error("FAIL:", msg); failed++ } else { passed++ }
}

function assertEq(a: any, b: any, msg: string) {
  const av = JSON.stringify(a), bv = JSON.stringify(b)
  assert(av === bv, `${msg}: expected ${bv}, got ${av}`)
}

function hex(b: Uint8Array): string {
  return Array.from(b, x => x.toString(16).padStart(2, "0")).join("")
}

function bytes(n: number): Uint8Array {
  const b = new Uint8Array(n)
  for (let i = 0; i < n; i++) b[i] = i & 0xff
  return b
}

// -- TMVar tests

async function testTMVar() {
  console.log("  TMVar...")

  // new + tryRead + tryTake
  const mv1 = TMVar.new(42)
  assertEq(mv1.tryRead(), 42, "new: tryRead returns value")
  assertEq(mv1.isEmpty(), false, "new: not empty")
  assertEq(mv1.tryTake(), 42, "tryTake returns value")
  assertEq(mv1.isEmpty(), true, "after tryTake: empty")
  assertEq(mv1.tryTake(), undefined, "tryTake on empty: undefined")

  // empty + tryPut
  const mv2 = TMVar.empty<number>()
  assertEq(mv2.isEmpty(), true, "empty: isEmpty")
  assert(mv2.tryPut(7), "tryPut on empty: true")
  assert(!mv2.tryPut(8), "tryPut on full: false")
  assertEq(mv2.tryRead(), 7, "tryRead after tryPut: 7")

  // take blocks until put
  const mv3 = TMVar.empty<string>()
  let taken = ""
  const takePromise = mv3.take().then(v => { taken = v })
  assertEq(taken, "", "take blocks: not yet resolved")
  await mv3.put("hello")
  await takePromise
  assertEq(taken, "hello", "take unblocks after put")
  assertEq(mv3.isEmpty(), true, "after take: empty")

  // read blocks until put, doesn't take
  const mv4 = TMVar.empty<number>()
  let readVal = 0
  const readPromise = mv4.read().then(v => { readVal = v })
  await mv4.put(99)
  await readPromise
  assertEq(readVal, 99, "read unblocks after put")
  assertEq(mv4.isEmpty(), false, "read doesn't take: still full")
  assertEq(mv4.tryRead(), 99, "value still there after read")

  // doWork pattern: tryPut (signal), read (wait), tryTake (clear)
  const doWork = TMVar.new<void>(undefined)  // starts with work
  await doWork.read()  // should not block
  doWork.tryTake()     // clear
  assertEq(doWork.isEmpty(), true, "doWork cleared")
  doWork.tryPut(undefined)  // signal new work
  assertEq(doWork.isEmpty(), false, "doWork signaled")
  // double signal is no-op
  assert(!doWork.tryPut(undefined), "double signal returns false")
}

// -- Sem tests

async function testSem() {
  console.log("  Sem...")

  const sem = new Sem(1)
  await sem.wait()
  // Now permits = 0, next wait should block
  let acquired = false
  const p = sem.wait().then(() => { acquired = true })
  assertEq(acquired, false, "sem blocks when permits=0")
  sem.signal()
  await p
  assertEq(acquired, true, "sem unblocks after signal")
}

// -- ABQueue tests

async function testABQueue() {
  console.log("  ABQueue...")

  const q = new ABQueue<number>(3)
  await q.enqueue(1)
  await q.enqueue(2)
  await q.enqueue(3)
  // Queue is full (size 3), next enqueue should block
  let enqueued = false
  const ep = q.enqueue(4).then(() => { enqueued = true })
  assertEq(enqueued, false, "enqueue blocks when full")
  const v = await q.dequeue()
  assertEq(v, 1, "dequeue returns first item")
  await ep
  assertEq(enqueued, true, "enqueue unblocks after dequeue")

  // dequeue remaining
  assertEq(await q.dequeue(), 2, "dequeue 2")
  assertEq(await q.dequeue(), 3, "dequeue 3")
  assertEq(await q.dequeue(), 4, "dequeue 4")
}

// -- SessionVar tests

async function testSessionVar() {
  console.log("  SessionVar...")

  const seq = {val: 0}
  const vars = new Map<string, any>()

  // getSessVar: new
  const r1 = getSessVar(seq, "srv1", vars)
  assert(r1.isNew, "first getSessVar is new")
  assertEq(r1.v.id, 0, "first id is 0")

  // getSessVar: existing
  const r2 = getSessVar(seq, "srv1", vars)
  assert(!r2.isNew, "second getSessVar is existing")
  assertEq(r2.v.id, 0, "same id")

  // different key: new
  const r3 = getSessVar(seq, "srv2", vars)
  assert(r3.isNew, "different key is new")
  assertEq(r3.v.id, 1, "incremented id")

  // tryReadSessVar before resolve
  assertEq(tryReadSessVar("srv1", vars), undefined, "tryRead before resolve: undefined")

  // resolve + tryRead
  r1.v.resolve("client1")
  await r1.v.promise
  assertEq(tryReadSessVar("srv1", vars), "client1", "tryRead after resolve")

  // multiple readers get same value
  const v1 = await r1.v.promise
  const v2 = await r2.v.promise
  assertEq(v1, "client1", "reader 1")
  assertEq(v2, "client1", "reader 2 (same promise)")

  // removeSessVar: wrong id doesn't remove
  removeSessVar({...r1.v, id: 999}, "srv1", vars)
  assert(vars.has("srv1"), "removeSessVar with wrong id: not removed")

  // removeSessVar: correct id removes
  removeSessVar(r1.v, "srv1", vars)
  assert(!vars.has("srv1"), "removeSessVar with correct id: removed")
}

// -- RetryInterval tests

async function testRetryInterval() {
  console.log("  RetryInterval...")

  const ri: RetryInterval = {initialInterval: 2_000_000, increaseAfter: 10_000_000, maxInterval: 180_000_000}

  // Before increaseAfter: delay unchanged
  assertEq(nextRetryDelay(0, 2_000_000, ri), 2_000_000, "before increaseAfter: unchanged")
  assertEq(nextRetryDelay(4_000_000, 2_000_000, ri), 2_000_000, "still before increaseAfter")

  // After increaseAfter: delay * 3/2
  assertEq(nextRetryDelay(10_000_000, 2_000_000, ri), 3_000_000, "after increaseAfter: 2M -> 3M")
  assertEq(nextRetryDelay(13_000_000, 3_000_000, ri), 4_500_000, "3M -> 4.5M")

  // At maxInterval: stays at max
  assertEq(nextRetryDelay(999_000_000, 180_000_000, ri), 180_000_000, "at max: unchanged")

  // Approaching max: capped
  assertEq(nextRetryDelay(100_000_000, 150_000_000, ri), 180_000_000, "capped at max")
}

// -- TSessionSubs tests

async function testTSessionSubs() {
  console.log("  TSessionSubs...")

  const ss = new TSessionSubs()
  const tSess = "user1:smp1.example.com"
  const sessId1 = bytes(32)
  const sessId2 = new Uint8Array(32).fill(0xff)

  const rq1: RcvQueueSub = {
    userId: 1, connId: bytes(24), server: "smp1.example.com",
    rcvId: new Uint8Array([1, 2, 3]), rcvPrivateKey: bytes(32),
    status: "new", enableNtfs: true, clientNoticeId: null,
    dbQueueId: 1, primary: true, dbReplaceQueueId: null,
  }
  const rq2: RcvQueueSub = {
    ...rq1, rcvId: new Uint8Array([4, 5, 6]), dbQueueId: 2,
    connId: new Uint8Array(24).fill(0xaa),
  }
  const rq1Key = hex(rq1.rcvId)
  const rq2Key = hex(rq2.rcvId)

  // addPendingSub
  ss.addPendingSub(tSess, rq1)
  assert(ss.hasPendingSub(tSess, rq1Key), "addPendingSub: hasPendingSub")
  assert(!ss.hasActiveSub(tSess, rq1Key), "addPendingSub: not active")
  assert(ss.hasPendingSubs(tSess), "hasPendingSubs")

  // setSessionId
  ss.setSessionId(tSess, sessId1)
  const sessSubs = ss.sessionSubs.get(tSess)!
  assertEq(hex(sessSubs.sessId!), hex(sessId1), "setSessionId sets sessId")

  // addActiveSub with matching sessId: moves from pending to active
  ss.addActiveSub(tSess, sessId1, rq1)
  assert(ss.hasActiveSub(tSess, rq1Key), "addActiveSub: now active")
  assert(!ss.hasPendingSub(tSess, rq1Key), "addActiveSub: no longer pending")

  // addActiveSub with wrong sessId: goes to pending
  ss.addActiveSub(tSess, sessId2, rq2)
  assert(!ss.hasActiveSub(tSess, rq2Key), "wrong sessId: not active")
  assert(ss.hasPendingSub(tSess, rq2Key), "wrong sessId: goes to pending")

  // batchAddActiveSubs
  ss.batchAddActiveSubs(tSess, sessId1, [rq2])
  assert(ss.hasActiveSub(tSess, rq2Key), "batchAddActiveSubs: now active")
  assert(!ss.hasPendingSub(tSess, rq2Key), "batchAddActiveSubs: removed from pending")

  // getPendingSubs / getActiveSubs
  assertEq(ss.getActiveSubs(tSess).size, 2, "getActiveSubs: 2 active")
  assertEq(ss.getPendingSubs(tSess).size, 0, "getPendingSubs: 0 pending")

  // setSubsPending: moves active to pending
  const moved = ss.setSubsPending(tSess, sessId1)
  assertEq(moved.size, 2, "setSubsPending: returned 2 moved subs")
  assertEq(ss.getActiveSubs(tSess).size, 0, "after setSubsPending: 0 active")
  assertEq(ss.getPendingSubs(tSess).size, 2, "after setSubsPending: 2 pending")
  assertEq(sessSubs.sessId, null, "after setSubsPending: sessId cleared")

  // setSubsPending with wrong sessId: no-op
  ss.setSessionId(tSess, sessId1)
  ss.batchAddActiveSubs(tSess, sessId1, [rq1, rq2])
  const moved2 = ss.setSubsPending(tSess, sessId2)
  assertEq(moved2.size, 0, "setSubsPending wrong sessId: no-op")
  assertEq(ss.getActiveSubs(tSess).size, 2, "still 2 active")

  // deleteSub
  ss.deleteSub(tSess, rq1Key)
  assert(!ss.hasActiveSub(tSess, rq1Key), "deleteSub: removed from active")
  assert(!ss.hasPendingSub(tSess, rq1Key), "deleteSub: removed from pending")
  assertEq(ss.getActiveSubs(tSess).size, 1, "1 active remains")

  // batchDeleteSubs
  ss.batchDeleteSubs(tSess, [rq2Key])
  assertEq(ss.getActiveSubs(tSess).size, 0, "batchDeleteSubs: 0 active")

  // batchAddPendingSubs
  ss.batchAddPendingSubs(tSess, [rq1, rq2])
  assertEq(ss.getPendingSubs(tSess).size, 2, "batchAddPendingSubs: 2 pending")

  // deletePendingSub
  ss.deletePendingSub(tSess, rq1Key)
  assertEq(ss.getPendingSubs(tSess).size, 1, "deletePendingSub: 1 pending")

  // batchDeletePendingSubs
  ss.batchDeletePendingSubs(tSess, new Set([rq2Key]))
  assertEq(ss.getPendingSubs(tSess).size, 0, "batchDeletePendingSubs: 0 pending")

  // setSessionId with change: moves active to pending
  ss.setSessionId(tSess, sessId1)
  ss.batchAddActiveSubs(tSess, sessId1, [rq1])
  ss.setSessionId(tSess, sessId2)  // different sessId → moves active to pending
  assert(!ss.hasActiveSub(tSess, rq1Key), "sessId change: not active")
  assert(ss.hasPendingSub(tSess, rq1Key), "sessId change: moved to pending")

  // clear
  ss.clear()
  assertEq(ss.sessionSubs.size, 0, "clear: empty")

  // foldSessionSubs
  ss.addPendingSub("a", rq1)
  ss.addPendingSub("b", rq2)
  const count = ss.foldSessionSubs((acc, _) => acc + 1, 0)
  assertEq(count, 2, "foldSessionSubs: 2 sessions")

  // mapSubs
  const s = ss.sessionSubs.get("a")!
  const [activeCount, pendingCount] = ss.mapSubs(m => m.size, s)
  assertEq(activeCount, 0, "mapSubs: 0 active")
  assertEq(pendingCount, 1, "mapSubs: 1 pending")
}

// -- Worker tests

import {
  newAgentClient, newWorker, waitForWork, noWorkToDo, hasWorkToDo, hasWorkToDo_,
  getAgentWorker, withWork, withConnLock, getNextServer, throwWhenInactive,
  beginAgentOperation, endAgentOperation, defaultAgentConfig, AgentError,
  type AgentClient as AC, type Worker as W,
} from "../dist/agent/client.js"

async function testWorker() {
  console.log("  Worker...")

  const store = null as any  // workers don't use store directly
  const c = newAgentClient(defaultAgentConfig, store, new Map())

  // newWorker starts with doWork full (has work)
  const w = newWorker(c)
  assertEq(w.doWork.isEmpty(), false, "newWorker: doWork has work")
  assertEq(w.action.tryRead(), null, "newWorker: action is null (not running)")
  assertEq(w.workerId, 0, "newWorker: first id is 0")

  // waitForWork / noWorkToDo / hasWorkToDo cycle
  await waitForWork(w.doWork)  // should resolve immediately (doWork is full)
  noWorkToDo(w.doWork)
  assertEq(w.doWork.isEmpty(), true, "noWorkToDo: cleared")
  hasWorkToDo(w)
  assertEq(w.doWork.isEmpty(), false, "hasWorkToDo: signaled")
  // double signal is idempotent
  hasWorkToDo(w)
  assertEq(w.doWork.isEmpty(), false, "double hasWorkToDo: still signaled")

  // workerSeq increments
  const w2 = newWorker(c)
  assertEq(w2.workerId, 1, "second worker id is 1")
}

async function testWithWork() {
  console.log("  withWork...")

  const store = null as any
  const c = newAgentClient(defaultAgentConfig, store, new Map())

  const doWork = TMVar.new<void>(undefined)
  let actionRan = false

  // withWork: clear signal, get work, if found re-signal and run action
  await withWork(c, doWork, async () => "item", async (item) => {
    assertEq(item, "item", "withWork action receives item")
    actionRan = true
  })
  assert(actionRan, "withWork: action ran")
  assertEq(doWork.isEmpty(), false, "withWork: re-signaled after finding work")

  // withWork: no work — action doesn't run, signal stays cleared
  let actionRan2 = false
  hasWorkToDo_(doWork)
  await withWork(c, doWork, async () => null, async () => { actionRan2 = true })
  assert(!actionRan2, "withWork: action did not run (no work)")
  assertEq(doWork.isEmpty(), true, "withWork: signal cleared when no work")
}

async function testLocking() {
  console.log("  Locking...")

  const store = null as any
  const c = newAgentClient(defaultAgentConfig, store, new Map())
  const connId = bytes(24)

  // withConnLock serializes
  const order: number[] = []
  const delay = (ms: number) => new Promise(r => setTimeout(r, ms))

  const p1 = withConnLock(c, connId, async () => {
    order.push(1)
    await delay(20)
    order.push(2)
  })
  const p2 = withConnLock(c, connId, async () => {
    order.push(3)
  })
  await Promise.all([p1, p2])
  assertEq(JSON.stringify(order), JSON.stringify([1, 2, 3]), "withConnLock serializes: 1,2,3")
}

async function testServerSelection() {
  console.log("  Server selection...")

  const store = null as any
  const srv1: any = {server: "smp1.example.com:5223", auth: null}
  const srv2: any = {server: "smp2.example.com:5223", auth: null}
  const srv3: any = {server: "smp3.example.com:5223", auth: null}
  const us: any = {
    storageSrvs: [[null, srv1], [null, srv2], [null, srv3]],
    proxySrvs: [[null, srv1]],
    knownHosts: new Set(["smp1.example.com", "smp2.example.com", "smp3.example.com"]),
  }
  const servers = new Map([[1, us]])
  const c = newAgentClient(defaultAgentConfig, store, servers)
  // Force deterministic selection
  c.randomServer = {gen: () => 0}

  // getNextServer avoids used servers
  const s = getNextServer(c, 1, u => u.storageSrvs, ["smp1.example.com:5223"])
  assert(s.server !== "smp1.example.com:5223", "getNextServer avoids used server")

  // getNextServer with all used: falls back to any
  const s2 = getNextServer(c, 1, u => u.storageSrvs, ["smp1.example.com:5223", "smp2.example.com:5223", "smp3.example.com:5223"])
  assert(s2 !== undefined, "getNextServer with all used: returns something")

  // getNextServer with unknown userId throws
  let threw = false
  try { getNextServer(c, 999, u => u.storageSrvs, []) } catch (e) {
    if (e instanceof AgentError) threw = true
  }
  assert(threw, "getNextServer unknown userId throws")
}

async function testOperationState() {
  console.log("  Operation state...")

  const store = null as any
  const c = newAgentClient(defaultAgentConfig, store, new Map())

  beginAgentOperation(c, "AOSndNetwork")
  assertEq(c.sndNetworkOp.opsInProgress, 1, "beginAgentOperation: incremented")
  beginAgentOperation(c, "AOSndNetwork")
  assertEq(c.sndNetworkOp.opsInProgress, 2, "beginAgentOperation: incremented again")
  endAgentOperation(c, "AOSndNetwork")
  assertEq(c.sndNetworkOp.opsInProgress, 1, "endAgentOperation: decremented")
  endAgentOperation(c, "AOSndNetwork")
  assertEq(c.sndNetworkOp.opsInProgress, 0, "endAgentOperation: zero")
  endAgentOperation(c, "AOSndNetwork")
  assertEq(c.sndNetworkOp.opsInProgress, 0, "endAgentOperation: clamped at 0")

  // throwWhenInactive
  c.active = false
  let threw = false
  try { throwWhenInactive(c) } catch { threw = true }
  assert(threw, "throwWhenInactive throws when inactive")
  c.active = true
  throwWhenInactive(c)  // should not throw
}

// -- agentCbEncrypt / ClientMsgEnvelope round-trip tests

import {agentCbEncrypt, agentCbDecrypt, agentCbEncryptOnce} from "../dist/agent/smp-ops.js"
import {decodeClientMsgEnvelope, decodeClientMessage, type ClientMsgEnvelope} from "../dist/protocol.js"
import {Decoder} from "@simplex-chat/xftp-web/dist/protocol/encoding.js"
import {cbDecrypt} from "@simplex-chat/xftp-web/dist/crypto/secretbox.js"
import {generateX25519KeyPair, dh} from "@simplex-chat/xftp-web/dist/crypto/keys.js"

async function testAgentCbEncrypt() {
  console.log("  agentCbEncrypt...")

  // Generate a DH secret (simulating queue E2E setup)
  const {publicKey: rcvPub, privateKey: rcvPriv} = generateX25519KeyPair()
  const {publicKey: sndPub, privateKey: sndPriv} = generateX25519KeyPair()
  const dhSecret = dh(rcvPub, sndPriv)
  const dhSecretRcv = dh(sndPub, rcvPriv)
  // Both sides should compute the same secret
  assertEq(hex(dhSecret), hex(dhSecretRcv), "DH secrets match")

  const plaintext = new Uint8Array([1, 2, 3, 4, 5])
  const smpVersion = 18

  // Encrypt: agentCbEncrypt wraps plaintext in ClientMsgEnvelope
  const envelope = agentCbEncrypt(dhSecret, smpVersion, null, plaintext)
  assert(envelope.length > 0, "agentCbEncrypt produces output")

  // Decode the ClientMsgEnvelope
  const d = new Decoder(envelope)
  const env = decodeClientMsgEnvelope(d)
  assertEq(env.cmHeader.phVersion, smpVersion, "envelope version matches")
  assertEq(env.cmHeader.phE2ePubDhKey, null, "no pub key for message (not confirmation)")
  assertEq(env.cmNonce.length, 24, "nonce is 24 bytes")
  assert(env.cmEncBody.length > 0, "encrypted body is non-empty")

  // Decrypt with receiver's DH secret
  const decrypted = cbDecrypt(dhSecretRcv, env.cmNonce, env.cmEncBody)
  assert(decrypted !== null, "cbDecrypt succeeds")
  // The decrypted content is the padded plaintext (with padding)
  // First bytes should match our plaintext
  let match = true
  for (let i = 0; i < plaintext.length; i++) {
    if (decrypted![i] !== plaintext[i]) { match = false; break }
  }
  assert(match, "decrypted content starts with plaintext")

  // Encrypt with e2ePubKey (confirmation mode — has DH pub key in header)
  const envConf = agentCbEncrypt(dhSecret, smpVersion, sndPub, plaintext)
  const d2 = new Decoder(envConf)
  const env2 = decodeClientMsgEnvelope(d2)
  assertEq(env2.cmHeader.phVersion, smpVersion, "confirmation envelope version")
  assert(env2.cmHeader.phE2ePubDhKey !== null, "confirmation has pub key")
  assertEq(env2.cmHeader.phE2ePubDhKey!.length, 32, "pub key is 32 bytes")

  // agentCbDecrypt
  const decrypted2 = agentCbDecrypt(dhSecretRcv, env2.cmNonce, env2.cmEncBody)
  for (let i = 0; i < plaintext.length; i++) {
    if (decrypted2[i] !== plaintext[i]) { match = false; break }
  }
  assert(match, "agentCbDecrypt matches plaintext")

  // agentCbEncryptOnce — ephemeral DH
  const envOnce = agentCbEncryptOnce(smpVersion, rcvPub, plaintext)
  const d3 = new Decoder(envOnce)
  const env3 = decodeClientMsgEnvelope(d3)
  assert(env3.cmHeader.phE2ePubDhKey !== null, "encryptOnce has ephemeral pub key")
  // Receiver can decrypt using their private key + sender's ephemeral pub key
  const ephDhSecret = dh(env3.cmHeader.phE2ePubDhKey!, rcvPriv)
  const decrypted3 = cbDecrypt(ephDhSecret, env3.cmNonce, env3.cmEncBody)
  assert(decrypted3 !== null, "encryptOnce: receiver can decrypt")
}

// -- Run all

async function main() {
  console.log("Infrastructure tests")
  await testTMVar()
  await testSem()
  await testABQueue()
  await testSessionVar()
  await testRetryInterval()
  await testTSessionSubs()
  await testWorker()
  await testWithWork()
  await testLocking()
  await testServerSelection()
  await testOperationState()
  await testAgentCbEncrypt()
  console.log(`\n${passed} passed, ${failed} failed`)
  if (failed > 0) process.exit(1)
}

main().catch(e => { console.error("FATAL:", e?.message || e, e?.stack); process.exit(1) })
