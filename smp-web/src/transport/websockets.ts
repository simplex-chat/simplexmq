// WebSocket transport for SMP protocol.
// Mirrors: Simplex.Messaging.Transport.WebSockets (client side)

import WebSocket from "ws"
import {Decoder} from "@simplex-chat/xftp-web/dist/protocol/encoding.js"
import {blockPad, blockUnpad} from "@simplex-chat/xftp-web/dist/protocol/transmission.js"
import {decodeSMPServerHandshake, encodeSMPClientHandshake, SMP_BLOCK_SIZE} from "../transport.js"
import type {SMPServerHandshake} from "../transport.js"

export interface SMPConnection {
  ws: WebSocket
  sessionId: Uint8Array
  smpVersion: number
}

export async function connectSMP(url: string, keyHash: Uint8Array, wsOptions?: object): Promise<SMPConnection> {
  const ws = new WebSocket(url, wsOptions)
  ws.binaryType = "arraybuffer"

  await new Promise<void>((resolve, reject) => {
    ws.onopen = () => resolve()
    ws.onerror = (e) => reject(e)
  })

  // Receive server handshake (first block)
  const serverBlock = await receiveBlock(ws)
  const serverHs = decodeSMPServerHandshake(new Decoder(blockUnpad(serverBlock)))

  // Negotiate version
  const version = Math.min(serverHs.smpVersionRange.max, 18)
  if (version < 6) throw new Error("Incompatible server version")

  // Send client handshake
  const clientHs = encodeSMPClientHandshake({
    smpVersion: version,
    keyHash,
    authPubKey: null,
    proxyServer: false,
    clientService: null
  })
  sendBlock(ws, blockPad(clientHs, SMP_BLOCK_SIZE))

  return {ws, sessionId: serverHs.sessionId, smpVersion: version}
}

export function receiveBlock(ws: WebSocket): Promise<Uint8Array> {
  return new Promise((resolve, reject) => {
    ws.onmessage = (e) => {
      const data = e.data
      if (data instanceof ArrayBuffer) {
        resolve(new Uint8Array(data))
      } else if (data instanceof Buffer) {
        resolve(new Uint8Array(data))
      } else {
        reject(new Error("Expected binary frame"))
      }
    }
    ws.onerror = (e) => reject(e)
  })
}

export function sendBlock(ws: WebSocket, data: Uint8Array): void {
  if (data.length !== SMP_BLOCK_SIZE) throw new Error("Block must be " + SMP_BLOCK_SIZE + " bytes")
  ws.send(data)
}
