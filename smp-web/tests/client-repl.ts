// SMP client REPL for cross-language testing.
// Holds one SMPClient, reads commands from stdin, writes results to stdout.
//
// Commands:
//   CONNECT <url> <keyHashHex> [wsOptionsJson]
//   NEW <rcvAuthKeyHex> <rcvDhKeyHex> <rcvPrivKeyHex>
//   SUB <rcvIdHex> <rcvPrivKeyHex>
//   SEND <sndIdHex> <sndPrivKeyHex|none> <notification 0|1> <bodyHex>
//   ACK <rcvIdHex> <rcvPrivKeyHex> <msgIdHex>
//   KEY <rcvIdHex> <rcvPrivKeyHex> <senderKeyHex>
//   SKEY <sndIdHex> <sndPrivKeyHex>
//   DEL <rcvIdHex> <rcvPrivKeyHex>
//   OFF <rcvIdHex> <rcvPrivKeyHex>
//   PING
//   RECV [timeoutMs]
//   CLOSE

import {createInterface} from "readline"
import {createSMPClient, type SMPClient} from "../dist/client.js"
import type {SMPResponse, AuthKey} from "../dist/protocol.js"
import {generateX25519KeyPair, dh, encodePubKeyX25519, decodePubKeyX25519} from "@simplex-chat/xftp-web/dist/crypto/keys.js"
import {cbDecrypt} from "@simplex-chat/xftp-web/dist/crypto/secretbox.js"
import {Decoder, decodeBytes, decodeBool} from "@simplex-chat/xftp-web/dist/protocol/encoding.js"

import type {ProxiedRelay} from "../dist/client.js"

// -- State

let client: SMPClient | null = null
let proxiedRelay: ProxiedRelay | null = null
// Per-queue DH shared secrets for decrypting received messages (keyed by rcvId hex)
const queueSecrets = new Map<string, Uint8Array>()
const messageQueue: Array<{entityId: Uint8Array, msg: SMPResponse}> = []
let messageWaiter: {resolve: (m: {entityId: Uint8Array, msg: SMPResponse}) => void, timer: ReturnType<typeof setTimeout>} | null = null

// -- Hex helpers

function toHex(bytes: Uint8Array): string {
  return Array.from(bytes, b => b.toString(16).padStart(2, "0")).join("")
}

function fromHex(hex: string): Uint8Array {
  const bytes = new Uint8Array(hex.length / 2)
  for (let i = 0; i < hex.length; i += 2)
    bytes[i / 2] = parseInt(hex.substring(i, i + 2), 16)
  return bytes
}

// -- Message delivery

function onMessage(entityId: Uint8Array, msg: SMPResponse): void {
  if (messageWaiter) {
    const w = messageWaiter
    messageWaiter = null
    clearTimeout(w.timer)
    w.resolve({entityId, msg})
  } else {
    messageQueue.push({entityId, msg})
  }
}

function waitForMessage(timeoutMs: number): Promise<{entityId: Uint8Array, msg: SMPResponse}> {
  if (messageQueue.length > 0) {
    return Promise.resolve(messageQueue.shift()!)
  }
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      messageWaiter = null
      reject(new Error("timeout"))
    }, timeoutMs)
    messageWaiter = {resolve, timer}
  })
}

function makeAuthKey(hexKey: string): AuthKey {
  return {type: "x25519", key: fromHex(hexKey)}
}

// -- Command parser

async function parseLine(line: string): Promise<string> {
  const parts = line.split(" ")
  const cmd = parts[0]

  try {
    switch (cmd) {
      case "CONNECT": {
        const url = parts[1]
        const keyHash = fromHex(parts[2])
        const wsOptions = parts[3] ? JSON.parse(parts[3]) : undefined
        client = await createSMPClient(url, keyHash, onMessage, () => {
          process.stderr.write("disconnected\n")
        }, {wsOptions, timeout: 15000})
        return "ok"
      }

      case "NEW": {
        if (!client) return "error: not connected"
        const rcvAuthKey = fromHex(parts[1])
        const rcvPrivKey = fromHex(parts[2])
        // Generate DH keypair for per-queue E2E
        const dhKp = generateX25519KeyPair()
        const dhPubDer = encodePubKeyX25519(dhKp.publicKey)
        const resp = await client.createQueue(
          {publicKey: rcvAuthKey, privateKey: rcvPrivKey},
          dhPubDer,
          true,
        )
        // Compute and store DH shared secret for decrypting received messages
        const srvDhRaw = decodePubKeyX25519(resp.srvDhKey)
        const dhShared = dh(srvDhRaw, dhKp.privateKey)
        queueSecrets.set(toHex(resp.rcvId), dhShared)
        return "ok: " + toHex(resp.rcvId) + " " + toHex(resp.sndId) + " " + toHex(resp.srvDhKey)
      }

      case "SUB": {
        if (!client) return "error: not connected"
        await client.subscribeQueue(makeAuthKey(parts[2]), fromHex(parts[1]))
        return "ok"
      }

      case "SEND": {
        if (!client) return "error: not connected"
        const sndId = fromHex(parts[1])
        const privKey: AuthKey | null = parts[2] === "none" ? null : makeAuthKey(parts[2])
        const notification = parts[3] === "1"
        const body = fromHex(parts[4])
        await client.sendMessage(privKey, sndId, notification, body)
        return "ok"
      }

      case "ACK": {
        if (!client) return "error: not connected"
        await client.ackMessage(makeAuthKey(parts[2]), fromHex(parts[1]), fromHex(parts[3]))
        return "ok"
      }

      case "KEY": {
        if (!client) return "error: not connected"
        await client.secureQueue(makeAuthKey(parts[2]), fromHex(parts[1]), fromHex(parts[3]))
        return "ok"
      }

      case "SKEY": {
        if (!client) return "error: not connected"
        await client.secureSndQueue(makeAuthKey(parts[2]), fromHex(parts[1]))
        return "ok"
      }

      case "DEL": {
        if (!client) return "error: not connected"
        await client.deleteQueue(makeAuthKey(parts[2]), fromHex(parts[1]))
        return "ok"
      }

      case "OFF": {
        if (!client) return "error: not connected"
        await client.suspendQueue(makeAuthKey(parts[2]), fromHex(parts[1]))
        return "ok"
      }

      case "PING": {
        if (!client) return "error: not connected"
        // Optional auth key as second arg: PING <privKeyHex>
        const pingKey: AuthKey | null = parts[1] ? makeAuthKey(parts[1]) : null
        const resp = await client.sendCommand(pingKey, new Uint8Array(0), new TextEncoder().encode("PING"))
        return resp.type === "PONG" ? "ok" : "error: unexpected " + resp.type
      }

      case "RECV": {
        if (!client) return "error: not connected"
        const timeoutMs = parts[1] ? parseInt(parts[1]) : 5000
        const m = await waitForMessage(timeoutMs)
        if (m.msg.type === "MSG") {
          const {msgId, msgBody} = m.msg.response
          // Decrypt per-queue E2E: cbDecrypt(dhShared, cbNonce(msgId), body)
          const dhShared = queueSecrets.get(toHex(m.entityId))
          if (dhShared) {
            // decryptMsgV3: cbDecrypt then parse ClientRcvMsgBody (msgTs + msgFlags + space + Tail msgBody)
            const decrypted = cbDecrypt(dhShared, msgId, msgBody)
            const dd = new Decoder(decrypted)
            dd.take(8) // skip msgTs (SystemTime = Int64 = 8 bytes)
            dd.take(1) // skip msgFlags (Bool = 1 byte)
            dd.take(1) // skip space (0x20)
            const body = dd.takeAll()
            return "ok: " + toHex(m.entityId) + " " + toHex(msgId) + " " + toHex(body)
          }
          // No DH secret (sender queue) — return raw
          return "ok: " + toHex(m.entityId) + " " + toHex(msgId) + " " + toHex(msgBody)
        }
        return "ok: " + toHex(m.entityId) + " " + m.msg.type
      }

      // BSUB <rcvId1Hex>:<privKey1Hex> <rcvId2Hex>:<privKey2Hex> ...
      case "BSUB": {
        if (!client) return "error: not connected"
        const queues = parts.slice(1).map(p => {
          const [rcvIdHex, privKeyHex] = p.split(":")
          return {rcvId: fromHex(rcvIdHex), privKey: makeAuthKey(privKeyHex)}
        })
        await client.subscribeQueues(queues)
        return "ok"
      }

      // PRXY <host1,host2,...> <port> <keyHashHex> [basicAuthHex]
      case "PRXY": {
        if (!client) return "error: not connected"
        const hosts = parts[1].split(",")
        const port = parts[2]
        const keyHash = fromHex(parts[3])
        const auth = parts[4] ? fromHex(parts[4]) : null
        proxiedRelay = await client.connectProxiedRelay(hosts, port, keyHash, auth)
        return "ok: " + toHex(proxiedRelay.sessionId) + " " + proxiedRelay.version
      }

      // PSEND <sndIdHex> <sndPrivKeyHex|none> <notification 0|1> <bodyHex>
      case "PSEND": {
        if (!client || !proxiedRelay) return "error: not connected or no proxy session"
        const sndId = fromHex(parts[1])
        const privKey: AuthKey | null = parts[2] === "none" ? null : makeAuthKey(parts[2])
        const notification = parts[3] === "1"
        const body = fromHex(parts[4])
        await client.proxySendMessage(proxiedRelay, privKey, sndId, notification, body)
        return "ok"
      }

      case "CLOSE": {
        if (client) client.close()
        client = null
        return "ok"
      }

      default:
        return "error: unknown command: " + cmd
    }
  } catch (e: any) {
    if (e.type) return "error: " + e.type + (e.error ? " " + e.error : "")
    return "error: " + (e.message || String(e))
  }
}

// -- Main

async function main() {
  const rl = createInterface({input: process.stdin, terminal: false})
  for await (const line of rl) {
    const trimmed = line.trim()
    if (!trimmed) continue
    const response = await parseLine(trimmed)
    process.stdout.write(response + "\n")
  }
}

main().catch(e => {
  process.stderr.write("FATAL: " + e.message + "\n")
  process.exit(1)
})
