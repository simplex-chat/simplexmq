// Agent-level REPL for cross-language testing.
// Uses AgentClient + smp-ops layer (not raw SMP client).
// Reads commands from stdin, writes results to stdout.
//
// Commands:
//   INIT <wsUrl> <keyHashHex> <userId>
//   CREATE_QUEUE <connIdHex>
//   SUBSCRIBE <connIdHex>
//   RECV [timeoutMs]
//   CB_ENCRYPT <dhSecretHex> <version> <bodyHex>
//   CB_DECRYPT <dhSecretHex> <nonceHex> <ciphertextHex>
//   CLOSE

import "fake-indexeddb/auto"
import {createInterface} from "readline"
import {newAgentClient, defaultAgentConfig, type AgentClient as AC} from "../dist/agent/client.js"
import {getSMPServerClient, agentCbEncrypt, agentCbDecrypt, newRcvQueue, subscribeQueues, type ServerMsg} from "../dist/agent/smp-ops.js"
import {openAgentStore} from "../dist/agent/store-idb.js"
import type {AgentStore} from "../dist/agent/store.js"
import type {RcvQueueSub} from "../dist/agent/subscriptions.js"

let agentClient: AC | null = null
let store: AgentStore | null = null
let serverUrl = ""
let serverKeyHash: Uint8Array = new Uint8Array(0)
let userId = 1

function toHex(bytes: Uint8Array): string {
  return Array.from(bytes, b => b.toString(16).padStart(2, "0")).join("")
}

function fromHex(hex: string): Uint8Array {
  const bytes = new Uint8Array(hex.length / 2)
  for (let i = 0; i < hex.length; i += 2)
    bytes[i / 2] = parseInt(hex.substring(i, i + 2), 16)
  return bytes
}

async function waitForMsg(c: AC, timeoutMs: number): Promise<ServerMsg> {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("timeout")), timeoutMs)
    c.msgQ.dequeue().then(msg => {
      clearTimeout(timer)
      resolve(msg as ServerMsg)
    }).catch(reject)
  })
}

async function parseLine(line: string): Promise<string> {
  const parts = line.trim().split(" ")
  const cmd = parts[0]

  try {
    switch (cmd) {
      case "INIT": {
        serverUrl = parts[1]
        serverKeyHash = fromHex(parts[2])
        userId = parseInt(parts[3], 10)
        store = await openAgentStore()
        await store.createUserRecord()
        agentClient = newAgentClient(defaultAgentConfig, store, new Map([[userId, {
          storageSrvs: [[null, {server: parts[1], auth: null}]],
          proxySrvs: [[null, {server: parts[1], auth: null}]],
          knownHosts: new Set(),
        }]]) as any)
        const conn = await getSMPServerClient(agentClient, userId, parts[1], serverKeyHash, parts[1])
        return "ok: " + toHex(conn.client.sessionId)
      }

      case "CREATE_QUEUE": {
        if (!agentClient || !store) return "error: not initialized"
        const connId = fromHex(parts[1])
        await store.createNewConn({
          connId, connMode: "INV", userId, smpAgentVersion: 7,
          enableNtfs: true, duplexHandshake: true, deleted: false,
          ratchetSyncState: "ok", pqSupport: false,
          lastInternalMsgId: 0, lastInternalRcvMsgId: 0, lastInternalSndMsgId: 0,
          lastExternalSndMsgId: 0, lastRcvMsgHash: new Uint8Array(0), lastSndMsgHash: new Uint8Array(0),
        }, "INV")
        const result = await newRcvQueue(agentClient, userId, connId, serverUrl, serverKeyHash, serverUrl, true)
        await store.addConnRcvQueue(connId, {
          host: result.rcvQueue.host, port: result.rcvQueue.port,
          rcvId: result.rcvQueue.rcv_id, connId,
          rcvPrivateKey: result.rcvQueue.rcv_private_key,
          rcvDhSecret: result.rcvQueue.rcv_dh_secret,
          e2ePrivKey: result.rcvQueue.e2e_priv_key,
          e2eDhSecret: null,
          sndId: result.rcvQueue.snd_id,
          sndKey: null, status: "new",
          smpClientVersion: result.rcvQueue.smp_client_version,
          dbQueueId: 0, primary: true,
          replaceRcvQueueId: null, queueMode: result.rcvQueue.queue_mode,
          serverKeyHash, lastBrokerTs: null,
        }, "SMSubscribe")
        return "ok: " + toHex(result.rcvQueue.rcv_id) + " " + toHex(result.sndId) + " " + toHex(result.e2eDhKey)
      }

      case "SUBSCRIBE": {
        if (!agentClient || !store) return "error: not initialized"
        const connId = fromHex(parts[1])
        const conn = await store.getConn(connId)
        if (!conn) return "error: connection not found"
        const rcvQueues = conn.rcvQueues as any[]
        if (rcvQueues.length === 0) return "error: no rcv queues"
        const subs: RcvQueueSub[] = rcvQueues.map((rq: any) => ({
          userId, connId: rq.conn_id, server: serverUrl,
          rcvId: rq.rcv_id, rcvPrivateKey: rq.rcv_private_key,
          status: rq.status, enableNtfs: true, clientNoticeId: null,
          dbQueueId: rq.rcv_queue_id, primary: !!rq.rcv_primary,
          dbReplaceQueueId: null,
        }))
        await subscribeQueues(agentClient, userId, subs)
        return "ok"
      }

      case "RECV": {
        if (!agentClient) return "error: not initialized"
        const timeoutMs = parts[1] ? parseInt(parts[1], 10) : 5000
        const msg = await waitForMsg(agentClient, timeoutMs)
        return "ok: " + toHex(msg.entityId) + " " + JSON.stringify(msg.msg)
      }

      case "CB_ENCRYPT": {
        // CB_ENCRYPT <dhSecretHex> <version> <bodyHex> [e2ePubKeyHex]
        // If e2ePubKeyHex is given (raw 32 bytes), it goes in the PubHeader (confirmation mode).
        const dhSecret = fromHex(parts[1])
        const version = parseInt(parts[2], 10)
        const body = fromHex(parts[3])
        const e2ePubKey = parts[4] ? fromHex(parts[4]) : null
        const envelope = agentCbEncrypt(dhSecret, version, e2ePubKey, body)
        return "ok: " + toHex(envelope)
      }

      case "CB_DECRYPT": {
        const dhSecret = fromHex(parts[1])
        const nonce = fromHex(parts[2])
        const ct = fromHex(parts[3])
        const pt = agentCbDecrypt(dhSecret, nonce, ct)
        return "ok: " + toHex(pt)
      }

      case "CLOSE": {
        if (agentClient) {
          agentClient.active = false
          for (const [, sv] of agentClient.smpClients as Map<string, any>) {
            if (sv.value?.client) sv.value.client.close()
          }
        }
        return "ok"
      }

      default:
        return "error: unknown command: " + cmd
    }
  } catch (e: any) {
    return "error: " + (e?.message || String(e))
  }
}

const rl = createInterface({input: process.stdin, output: process.stdout, terminal: false})

rl.on("line", async (line: string) => {
  const result = await parseLine(line)
  process.stdout.write(result + "\n")
})

rl.on("close", () => process.exit(0))
