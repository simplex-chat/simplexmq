// WebSocket transport for SMP protocol.
// Mirrors: Simplex.Messaging.Transport.WebSockets (client side)

import WebSocket from "ws"
import {randomBytes} from "crypto"
import {Decoder} from "@simplex-chat/xftp-web/dist/protocol/encoding.js"
import {base64urlEncode} from "@simplex-chat/xftp-web/dist/protocol/description.js"
import {blockPad, blockUnpad} from "@simplex-chat/xftp-web/dist/protocol/transmission.js"
import {verifyIdentityProof} from "@simplex-chat/xftp-web/dist/crypto/identity.js"
import {generateX25519KeyPair, dh, encodePubKeyX25519} from "@simplex-chat/xftp-web/dist/crypto/keys.js"
import {extractSignedKey} from "@simplex-chat/xftp-web/dist/protocol/handshake.js"
import {decodeSMPServerHandshake, encodeSMPClientHandshake, SMP_BLOCK_SIZE, currentSMPVersion} from "../transport.js"
import {sbcInit, sbEncryptBlock, sbDecryptBlock} from "../crypto.js"

export interface SMPConnection {
  ws: WebSocket
  sessionId: Uint8Array
  smpVersion: number
  // Block encryption state (null if no auth)
  sndKey: Uint8Array | null
  rcvKey: Uint8Array | null
}

export async function connectSMP(url: string, keyHash: Uint8Array, wsOptions?: object): Promise<SMPConnection> {
  // Generate challenge and append to URL
  const challenge = new Uint8Array(randomBytes(32))
  const challengeUrl = url + (url.includes("?") ? "&" : "?") + "challenge=" + base64urlEncode(challenge).replace(/=+$/, "")

  const ws = new WebSocket(challengeUrl, wsOptions)
  ws.binaryType = "arraybuffer"

  await new Promise<void>((resolve, reject) => {
    ws.onopen = () => resolve()
    ws.onerror = (e) => reject(e)
  })

  // Receive server handshake (first block)
  const serverBlock = await receiveBlock(ws)
  const serverHs = decodeSMPServerHandshake(new Decoder(blockUnpad(serverBlock)))

  // Negotiate version
  const version = Math.min(serverHs.smpVersionRange.max, currentSMPVersion)
  if (version < 6) throw new Error("Incompatible server version")

  // Verify server identity and extract DH key
  let sndKey: Uint8Array | null = null
  let rcvKey: Uint8Array | null = null
  let clientAuthPubKey: Uint8Array | null = null

  if (serverHs.authPubKey) {
    // Verify server identity if server supports web challenge (v19+)
    if (serverHs.webIdentityProof) {
      const ok = verifyIdentityProof({
        certChainDer: serverHs.authPubKey.certChainDer,
        signedKeyDer: serverHs.authPubKey.signedKeyDer,
        sigBytes: serverHs.webIdentityProof,
        challenge,
        sessionId: serverHs.sessionId,
        keyHash,
      })
      if (!ok) throw new Error("Server identity verification failed")
    }

    // DH key exchange for block encryption (v11+)
    const serverDhKey = extractSignedKey(serverHs.authPubKey.signedKeyDer).dhKey
    const clientKp = generateX25519KeyPair()
    clientAuthPubKey = encodePubKeyX25519(clientKp.publicKey)
    const dhSecret = dh(serverDhKey, clientKp.privateKey)
    // Client swaps snd/rcv vs server (Transport.hs:880)
    const keys = sbcInit(serverHs.sessionId, dhSecret)
    sndKey = keys.rcvKey
    rcvKey = keys.sndKey
  }

  // Send client handshake
  const clientHs = encodeSMPClientHandshake({
    smpVersion: version,
    keyHash,
    authPubKey: clientAuthPubKey,
    proxyServer: false,
    clientService: null
  })
  sendBlock(ws, blockPad(clientHs, SMP_BLOCK_SIZE))

  return {ws, sessionId: serverHs.sessionId, smpVersion: version, sndKey, rcvKey}
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

// Encrypted block send: pad to (blockSize - 16), encrypt (adds 16-byte tag)
export function sendEncryptedBlock(conn: SMPConnection, plaintext: Uint8Array): void {
  if (!conn.sndKey) throw new Error("no block encryption keys")
  const {encrypted, nextChainKey} = sbEncryptBlock(conn.sndKey, plaintext, SMP_BLOCK_SIZE - 16)
  conn.sndKey = nextChainKey
  ws_send(conn.ws, encrypted)
}

// Encrypted block receive: decrypt (removes 16-byte tag + unpad)
export async function receiveEncryptedBlock(conn: SMPConnection): Promise<Uint8Array> {
  if (!conn.rcvKey) throw new Error("no block encryption keys")
  const block = await receiveBlock(conn.ws)
  const {decrypted, nextChainKey} = sbDecryptBlock(conn.rcvKey, block)
  conn.rcvKey = nextChainKey
  return decrypted
}

function ws_send(ws: WebSocket, data: Uint8Array): void {
  if (data.length !== SMP_BLOCK_SIZE) throw new Error("Encrypted block must be " + SMP_BLOCK_SIZE + " bytes")
  ws.send(data)
}
