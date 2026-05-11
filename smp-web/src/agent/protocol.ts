// Agent protocol types and short link parsing.
// Mirrors: Simplex.Messaging.Agent.Protocol

import {base64urlDecode} from "@simplex-chat/xftp-web/dist/protocol/description.js"
import {
  Decoder, decodeBytes, decodeLarge, decodeWord16, decodeBool,
} from "@simplex-chat/xftp-web/dist/protocol/encoding.js"

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
