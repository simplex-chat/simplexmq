// XFTP transmission framing -- Simplex.Messaging.Transport + FileTransfer.Protocol
//
// Handles block-level pad/unpad, batch encoding, and Ed25519 auth signing.

import {
  Decoder, concatBytes,
  encodeBytes, decodeBytes,
  encodeLarge, decodeLarge
} from "./encoding.js"
import {sign} from "../crypto/keys.js"

// -- Constants

export const XFTP_BLOCK_SIZE = 16384

// Protocol versions (FileTransfer.Transport)
export const initialXFTPVersion = 1
export const authCmdsXFTPVersion = 2
export const blockedFilesXFTPVersion = 3
export const currentXFTPVersion = 3

// -- Block-level pad/unpad (Crypto.hs:pad/unPad, strict ByteString)

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

// -- Transmission encoding (client -> server)

// Encode an authenticated XFTP command as a padded block.
// Matches xftpEncodeAuthTransmission with implySessId = False:
// sessionId is included in both signed data AND wire data.
export function encodeAuthTransmission(
  sessionId: Uint8Array,
  corrId: Uint8Array,
  entityId: Uint8Array,
  cmdBytes: Uint8Array,
  privateKey: Uint8Array
): Uint8Array {
  // t' = encodeTransmission_ v t = smpEncode (corrId, entityId) <> cmdBytes
  const tInner = concatBytes(encodeBytes(corrId), encodeBytes(entityId), cmdBytes)
  // tForAuth = smpEncode sessionId <> t'
  const tForAuth = concatBytes(encodeBytes(sessionId), tInner)
  const signature = sign(privateKey, tForAuth)
  const authenticator = encodeBytes(signature)
  // implySessId = False: tToSend = tForAuth (sessionId on wire)
  const encoded = concatBytes(authenticator, tForAuth)
  const batch = concatBytes(new Uint8Array([1]), encodeLarge(encoded))
  return blockPad(batch)
}

// Encode an unsigned XFTP command (e.g. PING) as a padded block.
// Matches xftpEncodeTransmission with implySessId = False: sessionId on wire.
export function encodeTransmission(
  sessionId: Uint8Array,
  corrId: Uint8Array,
  entityId: Uint8Array,
  cmdBytes: Uint8Array
): Uint8Array {
  const tInner = concatBytes(encodeBytes(sessionId), encodeBytes(corrId), encodeBytes(entityId), cmdBytes)
  // No auth: tEncodeAuth False Nothing = smpEncode B.empty = \x00
  const authenticator = encodeBytes(new Uint8Array(0))
  const encoded = concatBytes(authenticator, tInner)
  const batch = concatBytes(new Uint8Array([1]), encodeLarge(encoded))
  return blockPad(batch)
}

// -- Transmission decoding (server -> client)

export interface DecodedTransmission {
  corrId: Uint8Array
  entityId: Uint8Array
  command: Uint8Array
}

// Decode a server response block into raw parts.
// Call decodeResponse(command) from commands.ts to parse the response.
// Matches xftpDecodeTClient with implySessId = False: reads and verifies sessionId from wire.
export function decodeTransmission(sessionId: Uint8Array, block: Uint8Array): DecodedTransmission {
  console.log('[DEBUG decodeTransmission] block.length=%d', block.length)
  const raw = blockUnpad(block)
  console.log('[DEBUG decodeTransmission] unpadded.length=%d first8=%s', raw.length, Array.from(raw.subarray(0, 8)).map(b => b.toString(16).padStart(2,'0')).join(' '))
  const d = new Decoder(raw)
  const count = d.anyByte()
  console.log('[DEBUG decodeTransmission] batch count=%d', count)
  if (count !== 1) throw new Error("decodeTransmission: expected batch count 1, got " + count)
  const transmission = decodeLarge(d)
  console.log('[DEBUG decodeTransmission] transmission.length=%d', transmission.length)
  const td = new Decoder(transmission)
  // Skip authenticator (server responses have empty auth)
  const auth = decodeBytes(td)
  console.log('[DEBUG decodeTransmission] auth.length=%d', auth.length)
  // implySessId = False: read sessionId from wire and verify
  const sessId = decodeBytes(td)
  console.log('[DEBUG decodeTransmission] sessId.length=%d', sessId.length)
  if (sessId.length !== sessionId.length || !sessId.every((b, i) => b === sessionId[i])) {
    console.log('[DEBUG decodeTransmission] SESSION MISMATCH expected=%s got=%s',
      Array.from(sessionId.subarray(0, 8)).map(b => b.toString(16).padStart(2,'0')).join(''),
      Array.from(sessId.subarray(0, 8)).map(b => b.toString(16).padStart(2,'0')).join(''))
    throw new Error("decodeTransmission: session ID mismatch")
  }
  const corrId = decodeBytes(td)
  const entityId = decodeBytes(td)
  const command = td.takeAll()
  console.log('[DEBUG decodeTransmission] corrId.len=%d entityId.len=%d command.len=%d cmd=%s',
    corrId.length, entityId.length, command.length, String.fromCharCode(...command.subarray(0, Math.min(10, command.length))))
  return {corrId, entityId, command}
}
