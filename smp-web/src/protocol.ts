// SMP protocol commands and transmission format.
// Mirrors: Simplex.Messaging.Protocol + Simplex.Messaging.Client (auth)

import {
  Decoder, concatBytes,
  encodeBytes, decodeBytes,
  encodeLarge, decodeLarge,
  encodeWord16, decodeWord16,
  encodeBool, decodeBool,
  encodeMaybe, decodeMaybe,
} from "@simplex-chat/xftp-web/dist/protocol/encoding.js"
import {cbEncrypt, cbDecrypt} from "@simplex-chat/xftp-web/dist/crypto/secretbox.js"
import {sign} from "@simplex-chat/xftp-web/dist/crypto/keys.js"
import {readTag, readSpace} from "@simplex-chat/xftp-web/dist/protocol/commands.js"
import {cbAuthenticator} from "./crypto.js"

// -- Auth key type for command authentication (Client.hs:1372-1391)

export type AuthKey =
  | {type: "x25519", key: Uint8Array}   // raw 32-byte private key → cbAuthenticator
  | {type: "ed25519", key: Uint8Array}  // raw 64-byte private key → sign

// -- Transmission encoding (Protocol.hs:2186-2198)

// encodeTransmission_ (Protocol.hs:2194-2198)
// smpEncode (corrId, entityId) <> encodeProtocol v command
// (command is pre-encoded bytes)
export function encodeTransmission(corrId: Uint8Array, entityId: Uint8Array, command: Uint8Array): Uint8Array {
  return concatBytes(encodeBytes(corrId), encodeBytes(entityId), command)
}

// encodeTransmissionForAuth (Protocol.hs:2186-2192)
// implySessId = true for v>=7 (always true for web client v19)
// tForAuth = sessionId <> encodeTransmission_(...)
// tToSend = encodeTransmission_(...)
export function encodeTransmissionForAuth(
  sessionId: Uint8Array, corrId: Uint8Array, entityId: Uint8Array, command: Uint8Array,
): {tForAuth: Uint8Array, tToSend: Uint8Array} {
  const tToSend = encodeTransmission(corrId, entityId, command)
  const tForAuth = concatBytes(encodeBytes(sessionId), tToSend)
  return {tForAuth, tToSend}
}

// -- Command authentication (Client.hs:1372-1391)

// authTransmission: produce auth bytes for a transmission
// Returns null for unauthenticated commands, Uint8Array of auth bytes otherwise
export function authTransmission(
  serverPubKey: Uint8Array,  // server's X25519 public key from handshake
  privKey: AuthKey | null,   // null for unauthenticated commands (LGET, SEND without key)
  nonce: Uint8Array,         // 24-byte CorrId/nonce (same bytes)
  tForAuth: Uint8Array,      // transmission bytes to authenticate
): Uint8Array | null {
  if (privKey === null) return null
  switch (privKey.type) {
    case "x25519":
      // TAAuthenticator: cbAuthenticate(serverPubKey, entityPrivKey, nonce, tForAuth)
      return cbAuthenticator(serverPubKey, privKey.key, nonce, tForAuth)
    case "ed25519":
      // TASignature: sign(entityPrivKey, tForAuth)
      return sign(privKey.key, tForAuth)
  }
}

// tEncodeAuth (Protocol.hs:507-516)
// For v16+ (serviceAuth=true): when auth is present, encode serviceSig as Nothing (0x30) after auth.
// When auth is absent: just empty ByteString.
export function tEncodeAuth(auth: Uint8Array | null): Uint8Array {
  if (auth === null) return encodeBytes(new Uint8Array(0))  // empty ByteString: [0x00]
  // serviceAuth=true for v16+: smpEncode (authBytes, serviceSig) where serviceSig = Nothing
  return concatBytes(encodeBytes(auth), new Uint8Array([0x30]))  // auth + Nothing
}

// tEncode (Protocol.hs:2171-2172)
export function tEncode(auth: Uint8Array | null, tToSend: Uint8Array): Uint8Array {
  return concatBytes(tEncodeAuth(auth), tToSend)
}

// tEncodeBatch1 (Protocol.hs:2179-2180)
// Single-command batch: count=1 + Large(tEncode(...))
export function tEncodeBatch1(auth: Uint8Array | null, tToSend: Uint8Array): Uint8Array {
  return concatBytes(new Uint8Array([1]), encodeLarge(tEncode(auth, tToSend)))
}

// tEncodeForBatch (Protocol.hs:2175-2176)
// Large(tEncode(...)) — for multi-command batches
export function tEncodeForBatch(auth: Uint8Array | null, tToSend: Uint8Array): Uint8Array {
  return encodeLarge(tEncode(auth, tToSend))
}

// batchTransmissions (Protocol.hs:2151-2168)
// Pack multiple encoded transmissions into ≤blockSize blocks.
// Each input is an already-encoded Large-wrapped transmission.
// Returns array of blocks, each prefixed with count byte.
export function batchTransmissions(blockSize: number, transmissions: Uint8Array[]): Uint8Array[] {
  const maxPayload = blockSize - 19 // 2 pad + 1 count + 16 auth tag
  const blocks: Uint8Array[] = []
  let currentParts: Uint8Array[] = []
  let currentLen = 0
  let count = 0
  for (const t of transmissions) {
    const tLen = t.length
    if (tLen > maxPayload) throw new Error("batchTransmissions: transmission too large")
    if (currentLen + tLen > maxPayload || count >= 255) {
      if (count > 0) blocks.push(concatBytes(new Uint8Array([count]), ...currentParts))
      currentParts = [t]
      currentLen = tLen
      count = 1
    } else {
      currentParts.push(t)
      currentLen += tLen
      count++
    }
  }
  if (count > 0) blocks.push(concatBytes(new Uint8Array([count]), ...currentParts))
  return blocks
}

// -- Transmission parsing (Protocol.hs:1629-1643, 2211-2267)

export interface RawTransmission {
  corrId: Uint8Array
  entityId: Uint8Array
  command: Uint8Array
}

// transmissionP (Protocol.hs:1629-1642)
// Parse a single transmission from block bytes.
// implySessId=true, serviceAuth=false for web client.
export function transmissionP(data: Uint8Array): RawTransmission {
  const d = new Decoder(data)
  const auth = decodeBytes(d)  // authenticator
  // serviceAuth=true for v16+: if auth is non-empty, skip serviceSig (Maybe Signature)
  if (auth.length > 0) {
    decodeMaybe(decodeBytes, d)  // skip serviceSig
  }
  const rest = d.takeAll()      // authorized bytes
  // re-parse authorized: corrId + entityId + command
  const d2 = new Decoder(rest)
  // implySessId=true: no sessionId in wire format
  const corrId = decodeBytes(d2)
  const entityId = decodeBytes(d2)
  const command = d2.takeAll()
  return {corrId, entityId, command}
}

// tParse (Protocol.hs:2211-2217)
// Parse a received block into individual transmissions.
// batch=true: count byte + N Large-wrapped transmissions
export function tParse(block: Uint8Array): RawTransmission[] {
  const d = new Decoder(block)
  const count = d.anyByte()
  const transmissions: RawTransmission[] = []
  for (let i = 0; i < count; i++) {
    const data = decodeLarge(d)
    transmissions.push(transmissionP(data))
  }
  return transmissions
}

// tDecodeClient (Protocol.hs:2256-2266)
// Parse command bytes into typed response.
export function tDecodeClient(raw: RawTransmission): {corrId: Uint8Array, entityId: Uint8Array, response: SMPResponse} {
  const response = decodeResponse(new Decoder(raw.command))
  return {corrId: raw.corrId, entityId: raw.entityId, response}
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

export interface PKEYResponse {
  sessionId: Uint8Array
  versionRange: {min: number, max: number}
  certChainDer: Uint8Array   // Large-encoded DER certificate chain
  signedKeyDer: Uint8Array   // Large-encoded DER signed public key
}

export type SMPResponse =
  | {type: "LNK", response: LNKResponse}
  | {type: "IDS", response: IDSResponse}
  | {type: "MSG", response: MSGResponse}
  | {type: "OK"}
  | {type: "SOK", serviceId: Uint8Array | null}
  | {type: "PKEY", response: PKEYResponse}
  | {type: "PRES", encResponse: Uint8Array}
  | {type: "PONG"}
  | {type: "END"}
  | {type: "DELD"}
  | {type: "ERR", error: string}

// protocolError check (Client.hs:710-712)
// Returns the error string if this is an ERR response, null otherwise
export function protocolError(resp: SMPResponse): string | null {
  return resp.type === "ERR" ? resp.error : null
}

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
    case "SOK": {
      // SOK serviceId_ → e(SOK_, ' ', serviceId_)
      readSpace(d)
      const serviceId = d.remaining() > 0 ? decodeMaybe(decodeBytes, d) : null
      return {type: "SOK", serviceId}
    }
    case "PKEY": {
      // PKEY sessionId versionRange certChainPubKey (Protocol.hs:1894)
      // PKEY_ -> PKEY <$> _smpP <*> smpP <*> smpP
      // sessionId: ByteString, versionRange: (Word16, Word16)
      // certChainPubKey: (NonEmpty Large, SignedObject) (Transport.hs:663-664)
      //   certChain = NonEmpty Large = 1-byte count + N × Large(2-byte len + DER)
      //   signedKey = Large(2-byte len + DER)
      readSpace(d)
      const sessionId = decodeBytes(d)
      const min = decodeWord16(d)
      const max = decodeWord16(d)
      // certChain: NonEmpty Large (1-byte count + N × Large-encoded DER certs)
      const certCount = d.anyByte()
      const certChainDers: Uint8Array[] = []
      for (let i = 0; i < certCount; i++) certChainDers.push(decodeLarge(d))
      // signedKey: Large-encoded DER
      const signedKeyDer = decodeLarge(d)
      return {type: "PKEY", response: {sessionId, versionRange: {min, max}, certChainDer: certChainDers[0] ?? new Uint8Array(0), signedKeyDer}}
    }
    case "PRES": {
      // PRES (EncResponse encBlock) (Protocol.hs:1896)
      // PRES_ -> PRES <$> (EncResponse . unTail <$> _smpP)
      readSpace(d)
      return {type: "PRES", encResponse: d.takeAll()}
    }
    case "PONG": return {type: "PONG"}
    case "END": return {type: "END"}
    case "DELD": return {type: "DELD"}
    case "ERR": {
      readSpace(d)
      // Read the full error string (may be multi-word like "AUTH" or "QUOTA")
      const errBytes = d.takeAll()
      return {type: "ERR", error: new TextDecoder().decode(errBytes)}
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
// QueueReqData: QRMessaging Nothing = 'M' + Nothing(0x30)
export function encodeNEW(
  rcvAuthKey: Uint8Array,   // DER-encoded Ed25519 or X25519 public key
  rcvDhKey: Uint8Array,     // DER-encoded X25519 public key
  basicAuth: Uint8Array | null,  // Maybe BasicAuth (server auth, not a crypto key)
  subscribe: boolean,
): Uint8Array {
  // QRMessaging Nothing: Just('M', Nothing) = 0x31 0x4D 0x30
  const queueReqData = new Uint8Array([0x31, 0x4D, 0x30])
  return concatBytes(
    ascii("NEW "),
    encodeBytes(rcvAuthKey),
    encodeBytes(rcvDhKey),
    encodeMaybe(encodeBytes, basicAuth),
    encodeSubMode(subscribe),
    queueReqData,
    new Uint8Array([0x30]),  // ntfCreds = Nothing
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

// GET (Protocol.hs:1698)
export function encodeGET(): Uint8Array {
  return ascii("GET")
}

// QUE (Protocol.hs:1702)
export function encodeQUE(): Uint8Array {
  return ascii("QUE")
}

// PING (Protocol.hs:1705)
export function encodePING(): Uint8Array {
  return ascii("PING")
}

// -- Proxy commands (Protocol.hs:1710-1711)

// encodeProtocolServer (Protocol.hs:1264-1266)
// smpEncode ProtocolServer {host, port, keyHash} = smpEncode (host, port, keyHash)
// host :: NonEmpty TransportHost → smpEncodeList (1-byte count + encodeBytes(strEncode(host)) for each)
// port :: ServiceName = ByteString → encodeBytes
// keyHash :: KeyHash = ByteString → encodeBytes
export function encodeProtocolServer(hosts: string[], port: string, keyHash: Uint8Array): Uint8Array {
  const encodedHosts = hosts.map(h => encodeBytes(ascii(h)))
  const hostList = concatBytes(new Uint8Array([hosts.length]), ...encodedHosts)
  return concatBytes(hostList, encodeBytes(ascii(port)), encodeBytes(keyHash))
}

// PRXY (Protocol.hs:1710)
// PRXY host auth_ -> e(PRXY_, ' ', host, auth_)
export function encodePRXY(hosts: string[], port: string, keyHash: Uint8Array, basicAuth: Uint8Array | null): Uint8Array {
  return concatBytes(
    ascii("PRXY "),
    encodeProtocolServer(hosts, port, keyHash),
    encodeMaybe(encodeBytes, basicAuth),
  )
}

// PFWD (Protocol.hs:1711)
// PFWD fwdV pubKey (EncTransmission s) -> e(PFWD_, ' ', fwdV, pubKey, Tail s)
export function encodePFWD(version: number, pubKeyDer: Uint8Array, encTransmission: Uint8Array): Uint8Array {
  return concatBytes(
    ascii("PFWD "),
    encodeWord16(version),
    encodeBytes(pubKeyDer),
    encTransmission, // Tail — no length prefix
  )
}

// paddedProxiedTLength (Protocol.hs:306-307)
export const paddedProxiedTLength = 16226

// -- SMP response decoders

// IDS (Protocol.hs:1914-1921)
// For v19: e(IDS_, ' ', rcvId, sndId, srvDh) <> e(queueMode, linkId, serviceId, ntfCreds)
export interface IDSResponse {
  rcvId: Uint8Array
  sndId: Uint8Array
  srvDhKey: Uint8Array
  queueMode: string | null  // 'M' = Messaging, 'C' = Contact
  linkId: Uint8Array | null
}

export function decodeIDS(d: Decoder): IDSResponse {
  const rcvId = decodeBytes(d)
  const sndId = decodeBytes(d)
  const srvDhKey = decodeBytes(d)
  // v19: queueMode (Maybe QueueMode), linkId (Maybe ByteString), serviceId, ntfCreds
  // QueueMode is encoded as Maybe Char ('M'/'C'), not Maybe ByteString
  let queueMode: string | null = null
  if (d.remaining() > 0) {
    const qmByte = d.anyByte()
    if (qmByte === 0x31) { // '1' = Just
      queueMode = String.fromCharCode(d.anyByte())
    }
    // '0' = Nothing, queueMode stays null
  }
  let linkId: Uint8Array | null = null
  if (d.remaining() > 0) {
    linkId = decodeMaybe(decodeBytes, d)
  }
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

// -- Per-queue E2E encryption (Protocol.hs:1071-1114)

// Protocol.hs:316-320
export const e2eEncMessageLength = 16000
export const e2eEncConfirmationLength = 15904

// Protocol.hs:1078-1086
export interface PubHeader {
  phVersion: number                    // VersionSMPC (Word16)
  phE2ePubDhKey: Uint8Array | null     // Maybe PublicKeyX25519 (DER-encoded ByteString)
}

export function encodePubHeader(h: PubHeader): Uint8Array {
  return concatBytes(encodeWord16(h.phVersion), encodeMaybe(encodeBytes, h.phE2ePubDhKey))
}

export function decodePubHeader(d: Decoder): PubHeader {
  return {phVersion: decodeWord16(d), phE2ePubDhKey: decodeMaybe(decodeBytes, d)}
}

// Protocol.hs:1097-1110
export type PrivHeader =
  | {type: "PHConfirmation", key: Uint8Array}  // 'K' + DER-encoded APublicAuthKey
  | {type: "PHEmpty"}                           // '_'

export function encodePrivHeader(h: PrivHeader): Uint8Array {
  switch (h.type) {
    case "PHConfirmation": return concatBytes(new Uint8Array([0x4B]), encodeBytes(h.key)) // 'K' + encodeBytes
    case "PHEmpty": return new Uint8Array([0x5F]) // '_'
  }
}

export function decodePrivHeader(d: Decoder): PrivHeader {
  const tag = d.anyByte()
  switch (tag) {
    case 0x4B: return {type: "PHConfirmation", key: decodeBytes(d)} // 'K'
    case 0x5F: return {type: "PHEmpty"} // '_'
    default: throw new Error("decodePrivHeader: unknown tag " + tag)
  }
}

// Protocol.hs:1095, 1112-1114
export interface ClientMessage {
  privHeader: PrivHeader
  body: Uint8Array
}

// smpEncode (ClientMessage h msg) = smpEncode h <> msg
export function encodeClientMessage(msg: ClientMessage): Uint8Array {
  return concatBytes(encodePrivHeader(msg.privHeader), msg.body)
}

export function decodeClientMessage(d: Decoder): ClientMessage {
  const privHeader = decodePrivHeader(d)
  const body = d.takeAll()
  return {privHeader, body}
}

// Protocol.hs:1071-1093
export interface ClientMsgEnvelope {
  cmHeader: PubHeader
  cmNonce: Uint8Array       // CbNonce: raw 24 bytes
  cmEncBody: Uint8Array     // encrypted body (Tail)
}

// smpEncode (cmHeader, cmNonce, Tail cmEncBody)
export function encodeClientMsgEnvelope(env: ClientMsgEnvelope): Uint8Array {
  return concatBytes(encodePubHeader(env.cmHeader), env.cmNonce, env.cmEncBody)
}

export function decodeClientMsgEnvelope(d: Decoder): ClientMsgEnvelope {
  const cmHeader = decodePubHeader(d)
  const cmNonce = d.take(24)  // CbNonce is raw 24 bytes
  const cmEncBody = d.takeAll()
  return {cmHeader, cmNonce, cmEncBody}
}

// -- Per-queue E2E encrypt/decrypt (Agent/Client.hs:2074-2102)

// agentCbEncrypt: encrypt a ClientMessage and wrap in ClientMsgEnvelope
export function agentCbEncrypt(
  e2eDhSecret: Uint8Array,     // X25519 DH shared secret (32 bytes)
  smpClientVersion: number,    // Word16
  e2ePubKey: Uint8Array | null, // DER-encoded X25519 public key, null for normal messages
  msg: Uint8Array,             // smpEncode(ClientMessage)
): Uint8Array {
  const cmNonce = crypto.getRandomValues(new Uint8Array(24))
  const paddedLen = e2ePubKey !== null ? e2eEncConfirmationLength : e2eEncMessageLength
  const cmEncBody = cbEncrypt(e2eDhSecret, cmNonce, msg, paddedLen)
  const cmHeader: PubHeader = {phVersion: smpClientVersion, phE2ePubDhKey: e2ePubKey}
  return encodeClientMsgEnvelope({cmHeader, cmNonce, cmEncBody})
}

// agentCbDecrypt: decrypt a ClientMsgEnvelope
export function agentCbDecrypt(
  dhSecret: Uint8Array,        // X25519 DH shared secret (32 bytes)
  data: Uint8Array,            // raw ClientMsgEnvelope bytes
): {pubHeader: PubHeader, clientMessage: ClientMessage} {
  const env = decodeClientMsgEnvelope(new Decoder(data))
  const plaintext = cbDecrypt(dhSecret, env.cmNonce, env.cmEncBody)
  const clientMessage = decodeClientMessage(new Decoder(plaintext))
  return {pubHeader: env.cmHeader, clientMessage}
}
