// Protocol commands and responses -- Simplex.FileTransfer.Protocol
//
// Commands (client -> server): FNEW, FADD, FPUT, FDEL, FGET, FACK, PING
// Responses (server -> client): SIDS, RIDS, FILE, OK, ERR, PONG

import {
  Decoder, concatBytes,
  encodeBytes, decodeBytes,
  encodeWord32,
  encodeNonEmpty, decodeNonEmpty,
  encodeMaybe
} from "./encoding.js"
import {decodePubKeyX25519} from "../crypto/keys.js"

// -- Types

export interface FileInfo {
  sndKey: Uint8Array   // DER-encoded Ed25519 public key (44 bytes)
  size: number         // Word32
  digest: Uint8Array   // SHA-256 digest (32 bytes)
}

export type CommandError = "UNKNOWN" | "SYNTAX" | "PROHIBITED" | "NO_AUTH" | "HAS_AUTH" | "NO_ENTITY"

export type XFTPErrorType =
  | {type: "BLOCK"} | {type: "SESSION"} | {type: "HANDSHAKE"}
  | {type: "CMD", cmdErr: CommandError}
  | {type: "AUTH"}
  | {type: "BLOCKED", blockInfo: string}
  | {type: "SIZE"} | {type: "QUOTA"} | {type: "DIGEST"} | {type: "CRYPTO"}
  | {type: "NO_FILE"} | {type: "HAS_FILE"} | {type: "FILE_IO"}
  | {type: "TIMEOUT"} | {type: "INTERNAL"}

export type FileResponse =
  | {type: "FRSndIds", senderId: Uint8Array, recipientIds: Uint8Array[]}
  | {type: "FRRcvIds", recipientIds: Uint8Array[]}
  | {type: "FRFile", rcvDhKey: Uint8Array, nonce: Uint8Array}
  | {type: "FROk"}
  | {type: "FRErr", err: XFTPErrorType}
  | {type: "FRPong"}

// -- FileInfo encoding

// smpEncode FileInfo {sndKey, size, digest} = smpEncode (sndKey, size, digest)
export function encodeFileInfo(fi: FileInfo): Uint8Array {
  return concatBytes(encodeBytes(fi.sndKey), encodeWord32(fi.size), encodeBytes(fi.digest))
}

// -- Command encoding (encodeProtocol)

const SPACE = new Uint8Array([0x20])

function ascii(s: string): Uint8Array {
  const buf = new Uint8Array(s.length)
  for (let i = 0; i < s.length; i++) buf[i] = s.charCodeAt(i)
  return buf
}

export function encodeFNEW(file: FileInfo, rcvKeys: Uint8Array[], auth: Uint8Array | null): Uint8Array {
  return concatBytes(
    ascii("FNEW"), SPACE,
    encodeFileInfo(file),
    encodeNonEmpty(encodeBytes, rcvKeys),
    encodeMaybe(encodeBytes, auth)
  )
}

export function encodeFADD(rcvKeys: Uint8Array[]): Uint8Array {
  return concatBytes(ascii("FADD"), SPACE, encodeNonEmpty(encodeBytes, rcvKeys))
}

export function encodeFPUT(): Uint8Array { return ascii("FPUT") }

export function encodeFDEL(): Uint8Array { return ascii("FDEL") }

export function encodeFGET(rcvDhKey: Uint8Array): Uint8Array {
  return concatBytes(ascii("FGET"), SPACE, encodeBytes(rcvDhKey))
}

export function encodePING(): Uint8Array { return ascii("PING") }

// -- Response decoding

function readTag(d: Decoder): string {
  const start = d.offset()
  while (d.remaining() > 0) {
    if (d.buf[d.offset()] === 0x20 || d.buf[d.offset()] === 0x0a) break
    d.anyByte()
  }
  let s = ""
  for (let i = start; i < d.offset(); i++) s += String.fromCharCode(d.buf[i])
  return s
}

function readSpace(d: Decoder): void {
  if (d.anyByte() !== 0x20) throw new Error("expected space")
}

function decodeCommandError(s: string): CommandError {
  if (s === "UNKNOWN" || s === "SYNTAX" || s === "PROHIBITED" || s === "NO_AUTH" || s === "HAS_AUTH" || s === "NO_ENTITY") return s
  if (s === "NO_QUEUE") return "NO_ENTITY"
  throw new Error("bad CommandError: " + s)
}

export function decodeXFTPError(d: Decoder): XFTPErrorType {
  const s = readTag(d)
  switch (s) {
    case "BLOCK": return {type: "BLOCK"}
    case "SESSION": return {type: "SESSION"}
    case "HANDSHAKE": return {type: "HANDSHAKE"}
    case "CMD": { readSpace(d); return {type: "CMD", cmdErr: decodeCommandError(readTag(d))} }
    case "AUTH": return {type: "AUTH"}
    case "BLOCKED": {
      readSpace(d)
      const rest = d.takeAll()
      let info = ""
      for (let i = 0; i < rest.length; i++) info += String.fromCharCode(rest[i])
      return {type: "BLOCKED", blockInfo: info}
    }
    case "SIZE": return {type: "SIZE"}
    case "QUOTA": return {type: "QUOTA"}
    case "DIGEST": return {type: "DIGEST"}
    case "CRYPTO": return {type: "CRYPTO"}
    case "NO_FILE": return {type: "NO_FILE"}
    case "HAS_FILE": return {type: "HAS_FILE"}
    case "FILE_IO": return {type: "FILE_IO"}
    case "TIMEOUT": return {type: "TIMEOUT"}
    case "INTERNAL": return {type: "INTERNAL"}
    default: throw new Error("bad XFTPErrorType: " + s)
  }
}

export function decodeResponse(data: Uint8Array): FileResponse {
  const d = new Decoder(data)
  const tagStr = readTag(d)
  switch (tagStr) {
    case "SIDS": {
      readSpace(d)
      const senderId = decodeBytes(d)
      return {type: "FRSndIds", senderId, recipientIds: decodeNonEmpty(decodeBytes, d)}
    }
    case "RIDS": {
      readSpace(d)
      return {type: "FRRcvIds", recipientIds: decodeNonEmpty(decodeBytes, d)}
    }
    case "FILE": {
      readSpace(d)
      const rcvDhKey = decodePubKeyX25519(decodeBytes(d))
      const nonce = d.take(24)
      return {type: "FRFile", rcvDhKey, nonce}
    }
    case "OK": return {type: "FROk"}
    case "ERR": { readSpace(d); return {type: "FRErr", err: decodeXFTPError(d)} }
    case "PONG": return {type: "FRPong"}
    default: throw new Error("unknown response: " + tagStr)
  }
}
