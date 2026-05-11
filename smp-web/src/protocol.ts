// SMP protocol commands and transmission format.
// Mirrors: Simplex.Messaging.Protocol

import {
  Decoder, concatBytes,
  encodeBytes, decodeBytes,
  encodeLarge, decodeLarge
} from "@simplex-chat/xftp-web/dist/protocol/encoding.js"
import {readTag, readSpace} from "@simplex-chat/xftp-web/dist/protocol/commands.js"

// -- Transmission encoding (Protocol.hs:2201-2203)
// encodeTransmission_ v (CorrId corrId, queueId, command) =
//   smpEncode (corrId, queueId) <> encodeProtocol v command

export function encodeTransmission(corrId: Uint8Array, entityId: Uint8Array, command: Uint8Array): Uint8Array {
  return concatBytes(
    encodeBytes(new Uint8Array(0)), // empty auth
    encodeBytes(corrId),
    encodeBytes(entityId),
    command
  )
}

// Batch encoding (Protocol.hs:2175-2180)
// Each transmission is Large-wrapped, then prefixed with 1-byte count.
export function encodeBatch(...transmissions: Uint8Array[]): Uint8Array {
  if (transmissions.length === 0 || transmissions.length > 255) throw new Error("encodeBatch: invalid count")
  return concatBytes(new Uint8Array([transmissions.length]), ...transmissions.map(t => encodeLarge(t)))
}

// -- Transmission parsing (Protocol.hs:1629-1642)
// For implySessId = True (v7+): no sessId on wire

export interface RawTransmission {
  corrId: Uint8Array
  entityId: Uint8Array
  command: Uint8Array
}

export function decodeTransmission(d: Decoder): RawTransmission {
  const _auth = decodeBytes(d) // authenticator (empty for unsigned)
  const corrId = decodeBytes(d)
  const entityId = decodeBytes(d)
  const command = d.takeAll()
  return {corrId, entityId, command}
}

// -- SMP command tags

const SPACE = 0x20

function ascii(s: string): Uint8Array {
  const buf = new Uint8Array(s.length)
  for (let i = 0; i < s.length; i++) buf[i] = s.charCodeAt(i)
  return buf
}

// -- LGET command (Protocol.hs:1709)
// No parameters. EntityId carries LinkId in transmission.

export function encodeLGET(): Uint8Array {
  return ascii("LGET")
}

// -- LNK response (Protocol.hs:1834)
// LNK sId d -> e (LNK_, ' ', sId, d)
// where d = (EncFixedDataBytes, EncUserDataBytes), both Large-encoded

export interface LNKResponse {
  senderId: Uint8Array
  encFixedData: Uint8Array
  encUserData: Uint8Array
}

export function decodeLNK(d: Decoder): LNKResponse {
  const senderId = decodeBytes(d)
  const encFixedData = decodeLarge(d)
  const encUserData = decodeLarge(d)
  return {senderId, encFixedData, encUserData}
}

// -- Response dispatch (same pattern as xftp-web decodeResponse)

export type SMPResponse =
  | {type: "LNK", response: LNKResponse}
  | {type: "OK"}
  | {type: "ERR", message: string}

export function decodeResponse(d: Decoder): SMPResponse {
  const tag = readTag(d)
  switch (tag) {
    case "LNK": {
      readSpace(d)
      return {type: "LNK", response: decodeLNK(d)}
    }
    case "OK": return {type: "OK"}
    case "ERR": {
      readSpace(d)
      return {type: "ERR", message: readTag(d)}
    }
    default: throw new Error("unknown SMP response: " + tag)
  }
}
