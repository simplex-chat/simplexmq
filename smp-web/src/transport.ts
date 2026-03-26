// SMP transport: handshake, block framing.
// Mirrors: Simplex.Messaging.Transport

import {
  Decoder, concatBytes,
  encodeWord16, decodeWord16,
  encodeBytes, decodeBytes,
  encodeLarge, decodeLarge,
  encodeBool,
  encodeMaybe,
  decodeNonEmpty
} from "@simplex-chat/xftp-web/dist/protocol/encoding.js"

// -- Version constants (Transport.hs:186-213)

export const SMP_BLOCK_SIZE = 16384
export const currentSMPVersion = 18

// -- SMPServerHandshake (Transport.hs:631-640)

export interface SMPServerHandshake {
  smpVersionRange: {min: number; max: number}
  sessionId: Uint8Array
  authPubKey: SMPAuthPubKey | null
}

export interface SMPAuthPubKey {
  certChainDer: Uint8Array[] // DER-encoded certificate chain
  signedKeyDer: Uint8Array  // DER-encoded SignedExact PubKey
}

export function decodeSMPServerHandshake(d: Decoder): SMPServerHandshake {
  const min = decodeWord16(d)
  const max = decodeWord16(d)
  const sessionId = decodeBytes(d)
  // authPubKey: encodeAuthEncryptCmds — present if bytes remain (v7+, always for current version)
  let authPubKey: SMPAuthPubKey | null = null
  if (d.remaining() > 0) {
    const certChainDer = decodeNonEmpty(decodeLarge, d)
    const signedKeyDer = decodeLarge(d)
    authPubKey = {certChainDer, signedKeyDer}
  }
  return {smpVersionRange: {min, max}, sessionId, authPubKey}
}

// -- SMPClientHandshake (Transport.hs:592-604)

export interface SMPClientHandshake {
  smpVersion: number
  keyHash: Uint8Array
  authPubKey: Uint8Array | null // X25519 public key, or null for no block encryption
  proxyServer: boolean
  clientService: null // not used in web client
}

export function encodeSMPClientHandshake(h: SMPClientHandshake): Uint8Array {
  const parts: Uint8Array[] = [
    encodeWord16(h.smpVersion),
    encodeBytes(h.keyHash),
  ]
  // authPubKey: encodeAuthEncryptCmds — empty for Nothing, encodeBytes for Just (v7+)
  if (h.authPubKey !== null) {
    parts.push(encodeBytes(h.authPubKey))
  }
  // proxyServer: Bool (v14+)
  parts.push(encodeBool(h.proxyServer))
  // clientService: Maybe (v16+) — Nothing = '0' (0x30)
  parts.push(encodeMaybe(() => new Uint8Array(0), null))
  return concatBytes(...parts)
}
