// SMP protocol commands and transmission format.
// Mirrors: Simplex.Messaging.Protocol

import {
  Decoder, concatBytes,
  encodeBytes, decodeBytes,
  encodeLarge, decodeLarge,
  encodeBool, decodeBool,
  encodeMaybe, decodeMaybe,
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
  | {type: "IDS", response: IDSResponse}
  | {type: "MSG", response: MSGResponse}
  | {type: "OK"}
  | {type: "PONG"}
  | {type: "END"}
  | {type: "DELD"}
  | {type: "ERR", message: string}

export function decodeResponse(d: Decoder): SMPResponse {
  const tag = readTag(d)
  switch (tag) {
    case "LNK": {
      readSpace(d)
      return {type: "LNK", response: decodeLNK(d)}
    }
    case "IDS": {
      readSpace(d)
      return {type: "IDS", response: decodeIDS(d)}
    }
    case "MSG": {
      readSpace(d)
      return {type: "MSG", response: decodeMSG(d)}
    }
    case "OK": return {type: "OK"}
    case "PONG": return {type: "PONG"}
    case "END": return {type: "END"}
    case "DELD": return {type: "DELD"}
    case "ERR": {
      readSpace(d)
      return {type: "ERR", message: readTag(d)}
    }
    default: throw new Error("unknown SMP response: " + tag)
  }
}

// -- SMP command encoders (Protocol.hs:1679-1715)

// MsgFlags (Protocol.hs:884-892)
// Single byte: Bool encoding of notification flag
export function encodeMsgFlags(notification: boolean): Uint8Array {
  return encodeBool(notification)
}

// SubscriptionMode (Protocol.hs:651-659)
// 'S' = SMSubscribe, 'C' = SMOnlyCreate
export function encodeSubMode(subscribe: boolean): Uint8Array {
  return ascii(subscribe ? "S" : "C")
}

// NEW (Protocol.hs:1682-1689)
// For v19: e(NEW_, ' ', rKey, dhKey) <> e(auth_, subMode, queueReqData, ntfCreds)
// auth_ = Maybe SndPublicAuthKey (DER-encoded)
// queueReqData = Maybe QueueReqData
// ntfCreds = Maybe NewNtfCreds (not needed for widget)
export function encodeNEW(
  rcvAuthKey: Uint8Array,   // DER-encoded Ed25519 or X25519 public key
  rcvDhKey: Uint8Array,     // DER-encoded X25519 public key
  sndAuthKey: Uint8Array | null,  // DER-encoded, for TOFU sender auth
  subscribe: boolean,
): Uint8Array {
  return concatBytes(
    ascii("NEW "),
    encodeBytes(rcvAuthKey),
    encodeBytes(rcvDhKey),
    encodeMaybe(encodeBytes, sndAuthKey),
    encodeSubMode(subscribe),
    encodeMaybe(() => new Uint8Array(0), null),  // queueReqData = Nothing (widget doesn't create links)
    encodeMaybe(() => new Uint8Array(0), null),  // ntfCreds = Nothing
  )
}

// KEY (Protocol.hs:1692)
// KEY k -> e(KEY_, ' ', k)
export function encodeKEY(senderKey: Uint8Array): Uint8Array {
  return concatBytes(ascii("KEY "), encodeBytes(senderKey))
}

// SKEY (Protocol.hs:1703)
// SKEY k -> e(SKEY_, ' ', k)
export function encodeSKEY(senderKey: Uint8Array): Uint8Array {
  return concatBytes(ascii("SKEY "), encodeBytes(senderKey))
}

// SUB (Protocol.hs:1690)
export function encodeSUB(): Uint8Array {
  return ascii("SUB")
}

// ACK (Protocol.hs:1699)
// ACK msgId -> e(ACK_, ' ', msgId)
export function encodeACK(msgId: Uint8Array): Uint8Array {
  return concatBytes(ascii("ACK "), encodeBytes(msgId))
}

// SEND (Protocol.hs:1704)
// SEND flags msg -> e(SEND_, ' ', flags, ' ', Tail msg)
export function encodeSEND(notification: boolean, msgBody: Uint8Array): Uint8Array {
  return concatBytes(
    ascii("SEND "),
    encodeMsgFlags(notification),
    ascii(" "),
    msgBody, // Tail - no length prefix
  )
}

// OFF (Protocol.hs:1700)
export function encodeOFF(): Uint8Array {
  return ascii("OFF")
}

// DEL (Protocol.hs:1701)
export function encodeDEL(): Uint8Array {
  return ascii("DEL")
}

// -- SMP response decoders

// IDS (Protocol.hs:1914-1921)
// For v19: e(IDS_, ' ', rcvId, sndId, srvDh) <> e(queueMode, linkId, serviceId, ntfCreds)
export interface IDSResponse {
  rcvId: Uint8Array
  sndId: Uint8Array
  srvDhKey: Uint8Array
  queueMode: Uint8Array | null
  linkId: Uint8Array | null
}

export function decodeIDS(d: Decoder): IDSResponse {
  const rcvId = decodeBytes(d)
  const sndId = decodeBytes(d)
  const srvDhKey = decodeBytes(d)
  const queueMode = d.remaining() > 0 ? decodeMaybe(decodeBytes, d) : null
  const linkId = d.remaining() > 0 ? decodeMaybe(decodeBytes, d) : null
  // serviceId and ntfCreds - skip remaining
  return {rcvId, sndId, srvDhKey, queueMode, linkId}
}

// MSG (Protocol.hs:1927-1928)
// MSG RcvMessage {msgId, msgBody = EncRcvMsgBody body} -> e(MSG_, ' ', msgId, Tail body)
export interface MSGResponse {
  msgId: Uint8Array
  msgBody: Uint8Array
}

export function decodeMSG(d: Decoder): MSGResponse {
  const msgId = decodeBytes(d)
  const msgBody = d.takeAll()
  return {msgId, msgBody}
}
