// Agent message encoding/decoding.
// Mirrors: Simplex.Messaging.Agent.Protocol (AgentMsgEnvelope, AgentMessage, APrivHeader, AMessage)

import {
  Decoder, concatBytes,
  encodeBytes, decodeBytes,
  encodeLarge, decodeLarge,
  encodeInt64, decodeInt64,
  encodeWord16, decodeWord16,
  encodeMaybe, decodeMaybe,
  encodeNonEmpty, decodeNonEmpty,
} from "@simplex-chat/xftp-web/dist/protocol/encoding.js"

// -- Constants (Agent/Protocol.hs:318-319)

export const currentSMPAgentVersion = 7

// -- AMessage (Agent/Protocol.hs:1001-1020)

export type AMessage =
  | {type: "HELLO"}
  | {type: "A_MSG", body: Uint8Array}
  | {type: "A_RCVD", receipts: AMessageReceipt[]}  // NonEmpty
  | {type: "EREADY", lastDecryptedMsgId: bigint}

// Agent/Protocol.hs:1040-1045
export interface AMessageReceipt {
  agentMsgId: bigint       // Int64
  msgHash: Uint8Array      // ByteString (32-byte SHA-256)
  rcptInfo: Uint8Array     // MsgReceiptInfo (ByteString, Large-encoded)
}

// Agent/Protocol.hs:1078-1100
export function encodeAMessage(msg: AMessage): Uint8Array {
  switch (msg.type) {
    case "HELLO": return new Uint8Array([0x48]) // "H"
    case "A_MSG": return concatBytes(new Uint8Array([0x4D]), msg.body) // "M" + Tail
    case "A_RCVD": return concatBytes(new Uint8Array([0x56]), encodeNonEmpty(encodeAMessageReceipt, msg.receipts)) // "V" + NonEmpty
    case "EREADY": return concatBytes(new Uint8Array([0x45]), encodeInt64(msg.lastDecryptedMsgId)) // "E" + Int64
  }
}

export function decodeAMessage(d: Decoder): AMessage {
  const tag = d.anyByte()
  switch (tag) {
    case 0x48: return {type: "HELLO"} // 'H'
    case 0x4D: return {type: "A_MSG", body: d.takeAll()} // 'M' + Tail
    case 0x56: return {type: "A_RCVD", receipts: decodeNonEmpty(decodeAMessageReceipt, d)} // 'V'
    case 0x45: return {type: "EREADY", lastDecryptedMsgId: decodeInt64(d)} // 'E'
    // Queue management tags (not needed for chat messages, but recognized for decoding)
    case 0x51: { // 'Q'
      const sub = d.anyByte()
      switch (sub) {
        case 0x43: // 'C' = A_QCONT
        case 0x41: // 'A' = QADD
        case 0x4B: // 'K' = QKEY
        case 0x55: // 'U' = QUSE
        case 0x54: // 'T' = QTEST
          throw new Error("decodeAMessage: queue management message (Q" + String.fromCharCode(sub) + ") not implemented")
        default:
          throw new Error("decodeAMessage: unknown Q-subtag " + sub)
      }
    }
    default:
      throw new Error("decodeAMessage: unknown tag " + tag)
  }
}

// Agent/Protocol.hs:1106-1111
function encodeAMessageReceipt(r: AMessageReceipt): Uint8Array {
  return concatBytes(encodeInt64(r.agentMsgId), encodeBytes(r.msgHash), encodeLarge(r.rcptInfo))
}

function decodeAMessageReceipt(d: Decoder): AMessageReceipt {
  return {agentMsgId: decodeInt64(d), msgHash: decodeBytes(d), rcptInfo: decodeLarge(d)}
}

// -- APrivHeader (Agent/Protocol.hs:946-957)

export interface APrivHeader {
  sndMsgId: bigint         // AgentMsgId = Int64
  prevMsgHash: Uint8Array  // MsgHash = ByteString
}

export function encodeAPrivHeader(h: APrivHeader): Uint8Array {
  return concatBytes(encodeInt64(h.sndMsgId), encodeBytes(h.prevMsgHash))
}

export function decodeAPrivHeader(d: Decoder): APrivHeader {
  return {sndMsgId: decodeInt64(d), prevMsgHash: decodeBytes(d)}
}

// -- AgentMessage (Agent/Protocol.hs:866-888)

export type AgentMessage =
  | {type: "connInfo", cInfo: Uint8Array}
  | {type: "connInfoReply", smpQueues: Uint8Array[], cInfo: Uint8Array}  // NonEmpty raw-encoded SMPQueueInfo
  | {type: "ratchetInfo", info: Uint8Array}
  | {type: "message", header: APrivHeader, msg: AMessage}

export function encodeAgentMessage(msg: AgentMessage): Uint8Array {
  switch (msg.type) {
    case "connInfo":
      return concatBytes(new Uint8Array([0x49]), msg.cInfo) // 'I' + Tail
    case "connInfoReply":
      // 'D' + NonEmpty SMPQueueInfo + Tail cInfo
      // SMPQueueInfo encoding is complex; for now encode the raw bytes
      return concatBytes(
        new Uint8Array([0x44]),
        encodeNonEmpty(b => b, msg.smpQueues),
        msg.cInfo,
      )
    case "ratchetInfo":
      return concatBytes(new Uint8Array([0x52]), msg.info) // 'R' + Tail
    case "message":
      return concatBytes(new Uint8Array([0x4D]), encodeAPrivHeader(msg.header), encodeAMessage(msg.msg)) // 'M' + header + msg
  }
}

export function decodeAgentMessage(d: Decoder): AgentMessage {
  const tag = d.anyByte()
  switch (tag) {
    case 0x49: return {type: "connInfo", cInfo: d.takeAll()} // 'I' + Tail
    case 0x44: { // 'D'
      // NonEmpty SMPQueueInfo is complex to decode; skip for now, just capture raw
      throw new Error("decodeAgentMessage: connInfoReply ('D') not implemented")
    }
    case 0x52: return {type: "ratchetInfo", info: d.takeAll()} // 'R' + Tail
    case 0x4D: return {type: "message", header: decodeAPrivHeader(d), msg: decodeAMessage(d)} // 'M'
    default:
      throw new Error("decodeAgentMessage: unknown tag " + tag)
  }
}

// -- AgentMsgEnvelope (Agent/Protocol.hs:812-861)

export type AgentMsgEnvelope =
  | {type: "confirmation", agentVersion: number, e2eEncryption: Uint8Array | null, encConnInfo: Uint8Array}
  | {type: "envelope", agentVersion: number, encAgentMessage: Uint8Array}
  | {type: "invitation", agentVersion: number, connReqBytes: Uint8Array, connInfo: Uint8Array}
  | {type: "ratchetKey", agentVersion: number, e2eEncryption: Uint8Array, info: Uint8Array}

// Agent/Protocol.hs:835-843
export function encodeAgentMsgEnvelope(env: AgentMsgEnvelope): Uint8Array {
  switch (env.type) {
    case "confirmation":
      // (agentVersion, 'C', Maybe SndE2ERatchetParams, Tail encConnInfo)
      return concatBytes(
        encodeWord16(env.agentVersion),
        new Uint8Array([0x43]), // 'C'
        encodeMaybe(b => b, env.e2eEncryption), // e2eEncryption is already smpEncoded bytes or null
        env.encConnInfo, // Tail
      )
    case "envelope":
      // (agentVersion, 'M', Tail encAgentMessage)
      return concatBytes(
        encodeWord16(env.agentVersion),
        new Uint8Array([0x4D]), // 'M'
        env.encAgentMessage, // Tail
      )
    case "invitation":
      // (agentVersion, 'I', Large connReqBytes, Tail connInfo)
      return concatBytes(
        encodeWord16(env.agentVersion),
        new Uint8Array([0x49]), // 'I'
        encodeLarge(env.connReqBytes),
        env.connInfo, // Tail
      )
    case "ratchetKey":
      // (agentVersion, 'R', e2eEncryption, Tail info)
      return concatBytes(
        encodeWord16(env.agentVersion),
        new Uint8Array([0x52]), // 'R'
        env.e2eEncryption, // already smpEncoded
        env.info, // Tail
      )
  }
}

// Agent/Protocol.hs:844-861
export function decodeAgentMsgEnvelope(d: Decoder): AgentMsgEnvelope {
  const agentVersion = decodeWord16(d)
  const tag = d.anyByte()
  switch (tag) {
    case 0x43: // 'C' Confirmation
      // e2eEncryption_ is Maybe (SndE2ERatchetParams 'X448), encConnInfo is Tail
      // Full parsing of E2ERatchetParams needed to split the boundary — not implemented in spike
      throw new Error("decodeAgentMsgEnvelope: confirmation ('C') not fully implemented")
    case 0x4D: // 'M' Message envelope
      return {type: "envelope", agentVersion, encAgentMessage: d.takeAll()} // Tail
    case 0x49: { // 'I' Invitation
      const connReqBytes = decodeLarge(d)
      const connInfo = d.takeAll() // Tail
      return {type: "invitation", agentVersion, connReqBytes, connInfo}
    }
    case 0x52: { // 'R' RatchetKey
      // e2eEncryption is an E2ERatchetParams — variable-length, not Tail
      // For now, capture remaining minus nothing (since info is Tail and comes last)
      // This is tricky: e2eEncryption is smpEncoded E2ERatchetParams, info is Tail
      // We can't easily split without knowing the E2ERatchetParams length
      // For the spike, just capture all remaining as raw
      throw new Error("decodeAgentMsgEnvelope: ratchetKey ('R') not fully implemented")
    }
    default:
      throw new Error("decodeAgentMsgEnvelope: unknown tag " + tag)
  }
}
