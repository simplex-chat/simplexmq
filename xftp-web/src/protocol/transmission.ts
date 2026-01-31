// XFTP transmission framing — Simplex.Messaging.Transport + FileTransfer.Protocol
//
// Handles block-level pad/unpad, batch encoding, and Ed25519 auth signing.

import {
  Decoder, concatBytes,
  encodeBytes, decodeBytes,
  encodeLarge, decodeLarge
} from "./encoding.js"
import {sign} from "../crypto/keys.js"

// ── Constants ─────────────────────────────────────────────────────

export const XFTP_BLOCK_SIZE = 16384

// Protocol versions (FileTransfer.Transport)
export const initialXFTPVersion = 1
export const authCmdsXFTPVersion = 2
export const blockedFilesXFTPVersion = 3
export const currentXFTPVersion = 3

// ── Block-level pad/unpad (Crypto.hs:pad/unPad, strict ByteString) ──

export function blockPad(msg: Uint8Array, blockSize: number = XFTP_BLOCK_SIZE): Uint8Array {
  const len = msg.length
  const padLen = blockSize - len - 2
  if (padLen < 0) throw new Error("blockPad: message too large for block")
  const result = new Uint8Array(blockSize)
  result[0] = (len >>> 8) & 0xff
  result[1] = len & 0xff
  result.set(msg, 2)
  result.fill(0x23, 2 + len) // '#' padding
  return result
}

export function blockUnpad(block: Uint8Array): Uint8Array {
  if (block.length < 2) throw new Error("blockUnpad: too short")
  const len = (block[0] << 8) | block[1]
  if (2 + len > block.length) throw new Error("blockUnpad: invalid length")
  return block.subarray(2, 2 + len)
}

// ── Transmission encoding (client -> server) ──────────────────────

// Encode an authenticated XFTP command as a padded block.
// Matches xftpEncodeAuthTransmission (implySessId = True).
//
//   sessionId:  TLS session ID (typically 32 bytes)
//   corrId:     correlation ID (ByteString)
//   entityId:   file entity ID (ByteString, empty for FNEW/PING)
//   cmdBytes:   encoded command (from encodeFNEW, encodeFGET, etc.)
//   privateKey: Ed25519 private key (64-byte libsodium format)
export function encodeAuthTransmission(
  sessionId: Uint8Array,
  corrId: Uint8Array,
  entityId: Uint8Array,
  cmdBytes: Uint8Array,
  privateKey: Uint8Array
): Uint8Array {
  // t' = encodeTransmission_ v t = smpEncode (corrId, entityId) <> cmdBytes
  const tInner = concatBytes(encodeBytes(corrId), encodeBytes(entityId), cmdBytes)
  // tForAuth = smpEncode sessionId <> t' (implySessId = True)
  const tForAuth = concatBytes(encodeBytes(sessionId), tInner)
  // Ed25519 sign (nonce ignored for Ed25519 in Haskell sign')
  const signature = sign(privateKey, tForAuth)
  // tEncodeAuth False (Just (TASignature sig, Nothing)) = smpEncode (signatureBytes sig)
  const authenticator = encodeBytes(signature)
  // tEncode False (auth, tToSend) = authenticator <> tToSend
  // tToSend = t' (since implySessId = True, no sessionId in wire)
  const encoded = concatBytes(authenticator, tInner)
  // tEncodeBatch1 False = \x01 + encodeLarge(encoded)
  const batch = concatBytes(new Uint8Array([1]), encodeLarge(encoded))
  // pad to blockSize
  return blockPad(batch)
}

// Encode an unsigned XFTP command (e.g. PING) as a padded block.
// Matches xftpEncodeTransmission (implySessId = True).
export function encodeTransmission(
  corrId: Uint8Array,
  entityId: Uint8Array,
  cmdBytes: Uint8Array
): Uint8Array {
  const tInner = concatBytes(encodeBytes(corrId), encodeBytes(entityId), cmdBytes)
  // No auth: tEncodeAuth False Nothing = smpEncode B.empty = \x00
  const authenticator = encodeBytes(new Uint8Array(0))
  const encoded = concatBytes(authenticator, tInner)
  const batch = concatBytes(new Uint8Array([1]), encodeLarge(encoded))
  return blockPad(batch)
}

// ── Transmission decoding (server -> client) ──────────────────────

export interface DecodedTransmission {
  corrId: Uint8Array
  entityId: Uint8Array
  command: Uint8Array
}

// Decode a server response block into raw parts.
// Call decodeResponse(command) from commands.ts to parse the response.
// Matches xftpDecodeTClient (implySessId = True).
export function decodeTransmission(block: Uint8Array): DecodedTransmission {
  // unPad
  const raw = blockUnpad(block)
  const d = new Decoder(raw)
  // Read batch count (must be 1)
  const count = d.anyByte()
  if (count !== 1) throw new Error("decodeTransmission: expected batch count 1, got " + count)
  // Read Large-encoded transmission
  const transmission = decodeLarge(d)
  const td = new Decoder(transmission)
  // Skip authenticator (server responses have empty auth)
  decodeBytes(td)
  // Read corrId and entityId
  const corrId = decodeBytes(td)
  const entityId = decodeBytes(td)
  // Remaining bytes are the response command
  const command = td.takeAll()
  return {corrId, entityId, command}
}
