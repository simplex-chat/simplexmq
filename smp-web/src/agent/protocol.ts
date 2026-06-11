// Agent protocol types and short link parsing.
// Mirrors: Simplex.Messaging.Agent.Protocol

import {base64urlDecode} from "@simplex-chat/xftp-web/dist/protocol/description.js"
import {
  Decoder, concatBytes,
  encodeBytes, decodeBytes,
  encodeLarge, decodeLarge,
  encodeWord16, decodeWord16,
  encodeBool, decodeBool,
  encodeMaybe, decodeMaybe,
  encodeNonEmpty, decodeNonEmpty,
} from "@simplex-chat/xftp-web/dist/protocol/encoding.js"
import {encodeProtocolServer} from "../protocol.js"

// -- Short link types (Agent/Protocol.hs:1462-1470)

export type ShortLinkScheme = "simplex" | "https"

export type ContactConnType = "contact" | "channel" | "group" | "relay"

export interface ProtocolServer {
  hosts: Uint8Array[] // NonEmpty, each is the strEncoded host bytes
  port: Uint8Array
  keyHash: Uint8Array
}

export type ConnShortLink =
  | {mode: "invitation", scheme: ShortLinkScheme, server: ProtocolServer, linkId: Uint8Array, linkKey: Uint8Array}
  | {mode: "contact", scheme: ShortLinkScheme, connType: ContactConnType, server: ProtocolServer, linkKey: Uint8Array}

// -- ProtocolServer binary encoding (Protocol.hs:1264-1269)
// smpEncode (host, port, keyHash)
// host: NonEmpty TransportHost = smpEncodeList (1-byte count + each as ByteString)
// port: String = ByteString (1-byte len + bytes)
// keyHash: KeyHash = ByteString (1-byte len + bytes)

export function decodeProtocolServer(d: Decoder): ProtocolServer {
  const hostCount = d.anyByte()
  if (hostCount === 0) throw new Error("empty server host list")
  const hosts: Uint8Array[] = []
  for (let i = 0; i < hostCount; i++) hosts.push(decodeBytes(d))
  const port = decodeBytes(d)
  const keyHash = decodeBytes(d)
  return {hosts, port, keyHash}
}

// -- ConnShortLink binary encoding (Agent/Protocol.hs:1631-1649)
// Contact: smpEncode (CMContact, ctTypeChar, srv, linkKey)
// Invitation: smpEncode (CMInvitation, srv, linkId, linkKey)

export interface ConnShortLinkBinary {
  mode: "contact" | "invitation"
  connType?: ContactConnType
  server: ProtocolServer
  linkId?: Uint8Array
  linkKey: Uint8Array
}

const ctTypeFromByte: Record<number, ContactConnType> = {
  0x41: "contact",  // 'A'
  0x43: "channel",  // 'C'
  0x47: "group",    // 'G'
  0x52: "relay",    // 'R'
}

export function decodeConnShortLink(d: Decoder): ConnShortLinkBinary {
  const mode = d.anyByte()
  if (mode === 0x49) {
    // Invitation: (srv, linkId, linkKey)
    const server = decodeProtocolServer(d)
    const linkId = decodeBytes(d)
    const linkKey = decodeBytes(d)
    return {mode: "invitation", server, linkId, linkKey}
  } else if (mode === 0x43) {
    // Contact: (ctTypeChar, srv, linkKey)
    const ctByte = d.anyByte()
    const connType = ctTypeFromByte[ctByte]
    if (!connType) throw new Error("unknown contact type: 0x" + ctByte.toString(16))
    const server = decodeProtocolServer(d)
    const linkKey = decodeBytes(d)
    return {mode: "contact", connType, server, linkKey}
  }
  throw new Error("unknown ConnShortLink mode: 0x" + mode.toString(16))
}

// -- OwnerAuth (Agent/Protocol.hs:1793-1800)
// Outer ByteString wrapping inner: (ownerId, ownerKey, authOwnerSig)

export interface OwnerAuth {
  ownerId: Uint8Array
  ownerKey: Uint8Array
  authOwnerSig: Uint8Array
}

export function decodeOwnerAuth(d: Decoder): OwnerAuth {
  const inner = decodeBytes(d)
  const id = new Decoder(inner)
  const ownerId = decodeBytes(id)
  const ownerKey = decodeBytes(id)
  const authOwnerSig = decodeBytes(id)
  return {ownerId, ownerKey, authOwnerSig}
}

// -- UserLinkData (Agent/Protocol.hs:1891-1894)
// If first byte is 0xFF, read Large; otherwise it's a ByteString (1-byte length)

export function decodeUserLinkData(d: Decoder): Uint8Array {
  const firstByte = d.anyByte()
  if (firstByte === 0xFF) return decodeLarge(d)
  return d.take(firstByte)
}

// -- UserContactData (Agent/Protocol.hs:1881-1889)

export interface UserContactData {
  direct: boolean
  owners: OwnerAuth[]
  relays: ConnShortLinkBinary[]
  userData: Uint8Array
}

export function decodeUserContactData(d: Decoder): UserContactData {
  const direct = decodeBool(d)
  const ownerCount = d.anyByte()
  const owners: OwnerAuth[] = []
  for (let i = 0; i < ownerCount; i++) owners.push(decodeOwnerAuth(d))
  const relayCount = d.anyByte()
  const relays: ConnShortLinkBinary[] = []
  for (let i = 0; i < relayCount; i++) relays.push(decodeConnShortLink(d))
  const userData = decodeUserLinkData(d)
  return {direct, owners, relays, userData}
}

// -- ConnLinkData (Agent/Protocol.hs:1838-1855)
// Contact: 'C' + versionRange + UserContactData

export interface ConnLinkDataContact {
  mode: "contact"
  agentVRange: {min: number; max: number}
  userContactData: UserContactData
}

export function decodeConnLinkData(d: Decoder): ConnLinkDataContact {
  const modeChar = d.anyByte()
  if (modeChar !== 0x43) throw new Error("expected Contact mode 'C' (0x43), got 0x" + modeChar.toString(16))
  const min = decodeWord16(d)
  const max = decodeWord16(d)
  const userContactData = decodeUserContactData(d)
  return {mode: "contact", agentVRange: {min, max}, userContactData}
}

// -- FixedLinkData (Agent/Protocol.hs:1830-1836)
// Encoding: smpEncode (agentVRange, rootKey, linkConnReq) <> maybe "" smpEncode linkEntityId
// rootKey is DER-encoded Ed25519 public key (ByteString: 1-byte len + 44 bytes DER)
// linkConnReq is ConnectionRequestUri (variable length, not length-prefixed)
// For now, we parse agentVRange + rootKey and keep the rest as raw bytes.
// Full ConnectionRequestUri parsing is future work.

export interface FixedLinkData {
  agentVRange: {min: number; max: number}
  rootKey: Uint8Array // DER-encoded Ed25519 public key (44 bytes)
  rest: Uint8Array    // raw linkConnReq + linkEntityId bytes
}

export function decodeFixedLinkData(d: Decoder): FixedLinkData {
  const min = decodeWord16(d)
  const max = decodeWord16(d)
  const rootKey = decodeBytes(d)
  const rest = d.takeAll()
  return {agentVRange: {min, max}, rootKey, rest}
}

// -- SMPQueueAddress (Agent/Protocol.hs:1350-1356)

export interface SMPQueueAddress {
  smpServer: {hosts: string[], port: string, keyHash: Uint8Array}  // ProtocolServer
  senderId: Uint8Array     // EntityId (ByteString)
  dhPublicKey: Uint8Array  // PublicKeyX25519 (DER-encoded ByteString)
  queueMode: string | null // Maybe QueueMode: 'M' = Messaging, 'C' = Contact
}

// -- SMPQueueInfo (Agent/Protocol.hs:1310-1327)
// Version-dependent encoding

// SMP client version constants (Protocol.hs:281-294)
const initialSMPClientVersion = 1
const sndAuthKeySMPClientVersion = 3
const shortLinksSMPClientVersion = 4

export interface SMPQueueInfo {
  clientVersion: number    // VersionSMPC (Word16)
  queueAddress: SMPQueueAddress
}

// smpEncode (Agent/Protocol.hs:1313-1321)
export function encodeSMPQueueInfo(q: SMPQueueInfo): Uint8Array {
  const {clientVersion, queueAddress: {smpServer, senderId, dhPublicKey, queueMode}} = q
  const addrEnc = concatBytes(
    encodeWord16(clientVersion),
    encodeProtocolServer(smpServer.hosts, smpServer.port, smpServer.keyHash),
    encodeBytes(senderId),
    encodeBytes(dhPublicKey),
  )
  if (clientVersion >= shortLinksSMPClientVersion) {
    // encode queueMode directly (Maybe QueueMode as char or empty)
    const qmBytes = queueMode ? new Uint8Array([queueMode.charCodeAt(0)]) : new Uint8Array(0)
    return concatBytes(addrEnc, qmBytes)
  }
  if (clientVersion >= sndAuthKeySMPClientVersion && senderCanSecure(queueMode)) {
    return concatBytes(addrEnc, encodeBool(true))
  }
  if (clientVersion > initialSMPClientVersion) {
    return addrEnc
  }
  // v1 legacy — not supported by web widget
  throw new Error("encodeSMPQueueInfo: legacy v1 not supported")
}

// smpP (Agent/Protocol.hs:1322-1327)
export function decodeSMPQueueInfo(d: Decoder): SMPQueueInfo {
  const clientVersion = decodeWord16(d)
  // v1 legacy server encoding not supported
  if (clientVersion <= initialSMPClientVersion) throw new Error("decodeSMPQueueInfo: legacy v1 not supported")
  const smpServer = decodeProtocolServerTyped(d)
  const senderId = decodeBytes(d)
  const dhPublicKey = decodeBytes(d)
  const queueMode = decodeQueueMode(d)
  return {clientVersion, queueAddress: {smpServer, senderId, dhPublicKey, queueMode}}
}

// -- SMPQueueUri (Agent/Protocol.hs:1347-1431)

export interface SMPQueueUri {
  clientVRange: {min: number, max: number}  // VersionRangeSMPC
  queueAddress: SMPQueueAddress
}

// smpEncode (Agent/Protocol.hs:1417-1427)
export function encodeSMPQueueUri(q: SMPQueueUri): Uint8Array {
  const {clientVRange: {min: minV, max: maxV}, queueAddress: {smpServer, senderId, dhPublicKey, queueMode}} = q
  const addrEnc = concatBytes(
    encodeWord16(minV), encodeWord16(maxV),
    encodeProtocolServer(smpServer.hosts, smpServer.port, smpServer.keyHash),
    encodeBytes(senderId),
    encodeBytes(dhPublicKey),
  )
  if (minV >= shortLinksSMPClientVersion) {
    const qmBytes = queueMode ? new Uint8Array([queueMode.charCodeAt(0)]) : new Uint8Array(0)
    return concatBytes(addrEnc, qmBytes)
  }
  if (minV >= sndAuthKeySMPClientVersion || (maxV >= sndAuthKeySMPClientVersion && senderCanSecure(queueMode))) {
    return concatBytes(addrEnc, encodeBool(senderCanSecure(queueMode)))
  }
  return addrEnc
}

// smpP (Agent/Protocol.hs:1428-1431)
export function decodeSMPQueueUri(d: Decoder): SMPQueueUri {
  const min = decodeWord16(d)
  const max = decodeWord16(d)
  const smpServer = decodeProtocolServerTyped(d)
  const senderId = decodeBytes(d)
  const dhPublicKey = decodeBytes(d)
  const queueMode = decodeQueueMode(d)
  return {clientVRange: {min, max}, queueAddress: {smpServer, senderId, dhPublicKey, queueMode}}
}

// -- ConnReqUriData (Agent/Protocol.hs:1728-1734, 1145-1158)

export interface ConnReqUriData {
  crAgentVRange: {min: number, max: number}  // VersionRangeSMPA
  crSmpQueues: SMPQueueUri[]                 // NonEmpty SMPQueueUri
  crClientData: string | null                // Maybe CRClientData (Text)
}

// smpEncode (Agent/Protocol.hs:1145-1147)
export function encodeConnReqUriData(d: ConnReqUriData): Uint8Array {
  const vr = concatBytes(encodeWord16(d.crAgentVRange.min), encodeWord16(d.crAgentVRange.max))
  const queues = encodeNonEmpty(encodeSMPQueueUri, d.crSmpQueues)
  const clientData = d.crClientData !== null
    ? concatBytes(new Uint8Array([0x31]), encodeLarge(new TextEncoder().encode(d.crClientData)))
    : new Uint8Array([0x30])
  return concatBytes(vr, queues, clientData)
}

// smpP (Agent/Protocol.hs:1148-1158)
export function decodeConnReqUriData(d: Decoder): ConnReqUriData {
  const min = decodeWord16(d)
  const max = decodeWord16(d)
  const crSmpQueues = decodeNonEmpty(decodeSMPQueueUri, d)
  // Patch queueMode: if Nothing, set to QMContact (Agent/Protocol.hs:1156-1158)
  for (const q of crSmpQueues) {
    if (q.queueAddress.queueMode === null) q.queueAddress.queueMode = "C"
  }
  const clientData = decodeMaybe((dd) => {
    const large = decodeLarge(dd)
    return new TextDecoder().decode(large)
  }, d)
  return {crAgentVRange: {min, max}, crSmpQueues, crClientData: clientData}
}

// -- ConnectionRequestUri (Agent/Protocol.hs:1130-1143, 1436-1441)

export type ConnectionRequestUri =
  | {mode: "invitation", crData: ConnReqUriData, e2eParams: Uint8Array}  // raw smpEncoded E2ERatchetParams
  | {mode: "contact", crData: ConnReqUriData}

// smpEncode (Agent/Protocol.hs:1130-1133)
export function encodeConnectionRequestUri(cr: ConnectionRequestUri): Uint8Array {
  switch (cr.mode) {
    case "invitation":
      return concatBytes(new Uint8Array([0x49]), encodeConnReqUriData(cr.crData), cr.e2eParams) // 'I' + crData + e2eParams
    case "contact":
      return concatBytes(new Uint8Array([0x43]), encodeConnReqUriData(cr.crData)) // 'C' + crData
  }
}

// smpP (Agent/Protocol.hs:1140-1143)
export function decodeConnectionRequestUri(d: Decoder): ConnectionRequestUri {
  const mode = d.anyByte()
  if (mode === 0x49) { // 'I' Invitation
    const crData = decodeConnReqUriData(d)
    const e2eParams = d.takeAll() // E2ERatchetParams consumes rest
    return {mode: "invitation", crData, e2eParams}
  }
  if (mode === 0x43) { // 'C' Contact
    const crData = decodeConnReqUriData(d)
    return {mode: "contact", crData}
  }
  throw new Error("decodeConnectionRequestUri: unknown mode 0x" + mode.toString(16))
}

// -- Helpers

function senderCanSecure(queueMode: string | null): boolean {
  return queueMode === "M"
}

// queueModeP (Agent/Protocol.hs:1433-1434)
// Just <$> smpP <|> optional ((\case True -> QMMessaging; _ -> QMContact) <$> smpP)
function decodeQueueMode(d: Decoder): string | null {
  if (d.remaining() === 0) return null
  const b = d.anyByte()
  if (b === 0x4D) return "M" // QMMessaging
  if (b === 0x43) return "C" // QMContact
  // Could be a Bool (sndSecure) for older versions — True='T'(0x54) → QMMessaging, False='F'(0x46) → QMContact
  if (b === 0x54) return "M" // True → QMMessaging
  if (b === 0x46) return null // False → no queueMode (not secured)
  return null
}

// Decode ProtocolServer into typed format with string hosts
function decodeProtocolServerTyped(d: Decoder): {hosts: string[], port: string, keyHash: Uint8Array} {
  const hostCount = d.anyByte()
  if (hostCount === 0) throw new Error("empty server host list")
  const hosts: string[] = []
  for (let i = 0; i < hostCount; i++) hosts.push(new TextDecoder().decode(decodeBytes(d)))
  const port = new TextDecoder().decode(decodeBytes(d))
  const keyHash = decodeBytes(d)
  return {hosts, port, keyHash}
}

// -- Profile extraction

export function parseProfile(userData: Uint8Array): unknown {
  if (userData.length > 0 && userData[0] === 0x58) {
    throw new Error("zstd-compressed profile not yet supported")
  }
  return JSON.parse(new TextDecoder().decode(userData))
}

// -- Short link URI parsing (below) --

export interface ShortLinkServer {
  hosts: string[]
  port: string
  keyHash: Uint8Array
}

export type ConnShortLinkURI =
  | {mode: "invitation", scheme: ShortLinkScheme, server: ShortLinkServer, linkId: Uint8Array, linkKey: Uint8Array}
  | {mode: "contact", scheme: ShortLinkScheme, connType: ContactConnType, server: ShortLinkServer, linkKey: Uint8Array}

const ctTypeFromChar: Record<string, ContactConnType> = {
  a: "contact",
  c: "channel",
  g: "group",
  r: "relay",
}

// Mirrors strP for AConnShortLink (Agent/Protocol.hs:1596-1629)
export function connShortLinkStrP(uri: string): ConnShortLinkURI {
  let scheme: ShortLinkScheme
  let firstHost: string | null = null
  let rest: string

  if (uri.startsWith("simplex:")) {
    scheme = "simplex"
    rest = uri.slice("simplex:".length)
  } else if (uri.startsWith("https://")) {
    scheme = "https"
    const afterScheme = uri.slice("https://".length)
    const slashIdx = afterScheme.indexOf("/")
    if (slashIdx < 0) throw new Error("bad short link: no path")
    firstHost = afterScheme.slice(0, slashIdx)
    rest = afterScheme.slice(slashIdx)
  } else {
    throw new Error("bad short link scheme")
  }

  if (rest[0] !== "/") throw new Error("bad short link: expected /")
  const typeChar = rest[1]
  const hashIdx = rest.indexOf("#")
  if (hashIdx < 0) throw new Error("bad short link: no #")
  const afterHash = rest.slice(hashIdx + 1)

  const qIdx = afterHash.indexOf("?")
  const fragment = qIdx >= 0 ? afterHash.slice(0, qIdx) : afterHash
  const queryStr = qIdx >= 0 ? afterHash.slice(qIdx + 1) : ""
  const params = new URLSearchParams(queryStr)

  const hParam = params.get("h")
  const additionalHosts = hParam ? hParam.split(",") : []
  const allHosts = firstHost ? [firstHost, ...additionalHosts] : additionalHosts
  if (allHosts.length === 0) throw new Error("short link without server")

  const port = params.get("p") ?? ""
  const keyHash = params.has("c") ? base64urlDecode(params.get("c")!) : new Uint8Array(0)
  const server: ShortLinkServer = {hosts: allHosts, port, keyHash}

  if (typeChar === "i") {
    const slashIdx = fragment.indexOf("/")
    if (slashIdx < 0) throw new Error("invitation link must have linkId/linkKey")
    const linkId = base64urlDecode(fragment.slice(0, slashIdx))
    const linkKey = base64urlDecode(fragment.slice(slashIdx + 1))
    return {mode: "invitation", scheme, server, linkId, linkKey}
  } else {
    const connType = ctTypeFromChar[typeChar]
    if (!connType) throw new Error("unknown contact type: " + typeChar)
    const linkKey = base64urlDecode(fragment)
    return {mode: "contact", scheme, connType, server, linkKey}
  }
}
