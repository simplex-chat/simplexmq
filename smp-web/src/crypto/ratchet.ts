// Double ratchet with X3DH key agreement.
// Mirrors: Simplex.Messaging.Crypto.Ratchet

import {x448} from "@noble/curves/ed448.js"
import {hkdf, encryptAEAD, decryptAEAD} from "../crypto.js"
import {
  Decoder, concatBytes,
  encodeBytes, decodeBytes, decodeWord16, decodeWord32,
  encodeLarge, decodeLarge,
} from "@simplex-chat/xftp-web/dist/protocol/encoding.js"

// -- X448 key operations

export interface X448KeyPair {
  publicKey: Uint8Array  // 56 bytes
  privateKey: Uint8Array // 56 bytes
}

export function generateX448KeyPair(): X448KeyPair {
  const privateKey = x448.utils.randomSecretKey()
  const publicKey = x448.getPublicKey(privateKey)
  return {publicKey, privateKey}
}

export function x448DH(publicKey: Uint8Array, privateKey: Uint8Array): Uint8Array {
  return x448.getSharedSecret(privateKey, publicKey)
}

// DER encoding for X448 public keys (RFC 8410, SubjectPublicKeyInfo)
// SEQUENCE { SEQUENCE { OID 1.3.101.110 } BIT STRING { 0x00 <56 bytes> } }
const X448_PUBKEY_DER_PREFIX = new Uint8Array([
  0x30, 0x42, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x6f, 0x03, 0x39, 0x00,
])

export function encodePubKeyX448(rawPubKey: Uint8Array): Uint8Array {
  return concatBytes(X448_PUBKEY_DER_PREFIX, rawPubKey)
}

export function decodePubKeyX448(der: Uint8Array): Uint8Array {
  if (der.length !== 68) throw new Error("decodePubKeyX448: invalid length " + der.length)
  for (let i = 0; i < X448_PUBKEY_DER_PREFIX.length; i++) {
    if (der[i] !== X448_PUBKEY_DER_PREFIX[i]) throw new Error("decodePubKeyX448: invalid DER prefix")
  }
  return der.subarray(12)
}

// -- X3DH key agreement (Ratchet.hs:499-508)

export interface RatchetInitParams {
  assocData: Uint8Array    // pubKeyBytes(sk1) || pubKeyBytes(rk1)
  ratchetKey: Uint8Array   // 32 bytes (root key)
  sndHK: Uint8Array        // 32 bytes (header key)
  rcvNextHK: Uint8Array    // 32 bytes (next header key)
}

// hkdf3 (Ratchet.hs:1174-1179)
// HKDF-SHA512, output 96 bytes, split 32+32+32
function hkdf3(salt: Uint8Array, ikm: Uint8Array, info: string): [Uint8Array, Uint8Array, Uint8Array] {
  const out = hkdf(salt, ikm, info, 96)
  return [out.slice(0, 32), out.slice(32, 64), out.slice(64, 96)]
}

const X3DH_SALT = new Uint8Array(64) // 64 zero bytes

// pqX3dh (Ratchet.hs:499-508)
// Core X3DH: three DH results + optional KEM shared secret → HKDF → init params
function pqX3dh(
  sk1: Uint8Array, rk1: Uint8Array, // public keys for assocData
  dh1: Uint8Array, dh2: Uint8Array, dh3: Uint8Array,
  kemSharedSecret: Uint8Array | null, // PQ KEM shared secret, 32 bytes
): RatchetInitParams {
  const assocData = concatBytes(sk1, rk1)
  const dhs = kemSharedSecret
    ? concatBytes(dh1, dh2, dh3, kemSharedSecret)
    : concatBytes(dh1, dh2, dh3)
  const [hk, nhk, sk] = hkdf3(X3DH_SALT, dhs, "SimpleXX3DH")
  return {assocData, ratchetKey: sk, sndHK: hk, rcvNextHK: nhk}
}

// pqX3dhSnd (Ratchet.hs:467-480)
// Used by joiner (Bob) to initialize SENDING ratchet.
// Our keys: spk1, spk2 (private). Their keys: rk1, rk2 (public, from invitation).
export function pqX3dhSnd(
  spk1: Uint8Array, spk2: Uint8Array,  // our private keys
  rk1: Uint8Array, rk2: Uint8Array,    // their public keys (raw, not DER)
  kemSharedSecret: Uint8Array | null = null,
): RatchetInitParams {
  const sk1Pub = x448.getPublicKey(spk1)
  const dh1 = x448DH(rk1, spk2)
  const dh2 = x448DH(rk2, spk1)
  const dh3 = x448DH(rk2, spk2)
  return pqX3dh(sk1Pub, rk1, dh1, dh2, dh3, kemSharedSecret)
}

// pqX3dhRcv (Ratchet.hs:483-497)
// Used by initiator (Alice) to initialize RECEIVING ratchet.
// Our keys: rpk1, rpk2 (private). Their keys: sk1, sk2 (public, from confirmation).
export function pqX3dhRcv(
  rpk1: Uint8Array, rpk2: Uint8Array,  // our private keys
  sk1: Uint8Array, sk2: Uint8Array,    // their public keys (raw, not DER)
  kemSharedSecret: Uint8Array | null = null,
): RatchetInitParams {
  const rk1Pub = x448.getPublicKey(rpk1)
  const dh1 = x448DH(sk2, rpk1)
  const dh2 = x448DH(sk1, rpk2)
  const dh3 = x448DH(sk2, rpk2)
  return pqX3dh(sk1, rk1Pub, dh1, dh2, dh3, kemSharedSecret)
}

// -- KDF functions (Ratchet.hs:1159-1179)

const EMPTY_SALT = new Uint8Array(0)

// rootKdf (Ratchet.hs:1159-1166)
// HKDF-SHA512 with DH result + optional KEM shared secret
export function rootKdf(
  ratchetKey: Uint8Array, // 32 bytes
  peerPubKey: Uint8Array, // raw X448 public key, 56 bytes
  ownPrivKey: Uint8Array, // raw X448 private key, 56 bytes
  kemSecret: Uint8Array | null, // optional KEM shared secret
): {rk: Uint8Array; ck: Uint8Array; nhk: Uint8Array} {
  const dhOut = x448DH(peerPubKey, ownPrivKey)
  const ss = kemSecret ? concatBytes(dhOut, kemSecret) : dhOut
  const [rk, ck, nhk] = hkdf3(ratchetKey, ss, "SimpleXRootRatchet")
  return {rk, ck, nhk}
}

// chainKdf (Ratchet.hs:1168-1172)
// HKDF-SHA512 with empty salt, produces chain key + message key + two 16-byte IVs
export function chainKdf(chainKey: Uint8Array): {ck: Uint8Array; mk: Uint8Array; iv: Uint8Array; ehIV: Uint8Array} {
  const [ck, mk, ivs] = hkdf3(EMPTY_SALT, chainKey, "SimpleXChainRatchet")
  return {ck, mk, iv: ivs.slice(0, 16), ehIV: ivs.slice(16, 32)}
}

// -- Header padding (Ratchet.hs:716-719)

const PADDED_HEADER_LEN_NO_PQ = 88
const PADDED_HEADER_LEN_PQ = 2310

export function paddedHeaderLen(pqSupport: boolean): number {
  return pqSupport ? PADDED_HEADER_LEN_PQ : PADDED_HEADER_LEN_NO_PQ
}

// -- Ratchet state (Ratchet.hs:512-565)

export interface SndRatchet {
  rcDHRr: Uint8Array   // peer's X448 public key (raw, 56 bytes)
  rcCKs: Uint8Array    // sending chain key (32 bytes)
  rcHKs: Uint8Array    // sending header key (32 bytes)
}

export interface RcvRatchet {
  rcCKr: Uint8Array    // receiving chain key (32 bytes)
  rcHKr: Uint8Array    // receiving header key (32 bytes)
}

export interface MessageKey {
  mk: Uint8Array       // 32 bytes
  iv: Uint8Array       // 16 bytes
}

// Skipped message keys: Map<headerKey, Map<msgNumber, MessageKey>>
// Using string keys for the outer map (hex-encoded header key)
export type SkippedMsgKeys = Map<string, Map<number, MessageKey>>

export interface RatchetState {
  // version
  rcVersion: number    // current e2e version
  rcMaxVersion: number // max supported e2e version
  // associated data
  rcAD: Uint8Array
  // DH ratchet key pair (our private key)
  rcDHRs: Uint8Array   // X448 private key (56 bytes)
  // PQ support
  rcSupportKEM: boolean
  // root key
  rcRK: Uint8Array     // 32 bytes
  // sending ratchet (null before first message sent after ratchet advance)
  rcSnd: SndRatchet | null
  // receiving ratchet (null before first message received)
  rcRcv: RcvRatchet | null
  // counters
  rcNs: number         // sending message number
  rcNr: number         // receiving message number
  rcPN: number         // previous sending chain length
  // next header keys
  rcNHKs: Uint8Array   // 32 bytes
  rcNHKr: Uint8Array   // 32 bytes
}

const MAX_SKIP = 512

function hexKey(k: Uint8Array): string {
  return Array.from(k, b => b.toString(16).padStart(2, "0")).join("")
}

// -- Ratchet initialization (Ratchet.hs:643-699)

// initSndRatchet (Ratchet.hs:643-666)
// Used by joiner (Bob) after X3DH
export function initSndRatchet(
  version: number,
  maxVersion: number,
  rcDHRr: Uint8Array,    // peer's X448 public key (raw, from invitation)
  rcDHRs: Uint8Array,    // our X448 private key (raw)
  initParams: RatchetInitParams,
  pqSupport: boolean,
  kemSharedSecret: Uint8Array | null = null,
): RatchetState {
  const {rk, ck, nhk} = rootKdf(initParams.ratchetKey, rcDHRr, rcDHRs, kemSharedSecret)
  return {
    rcVersion: version,
    rcMaxVersion: maxVersion,
    rcAD: initParams.assocData,
    rcDHRs,
    rcSupportKEM: pqSupport,
    rcRK: rk,
    rcSnd: {rcDHRr, rcCKs: ck, rcHKs: initParams.sndHK},
    rcRcv: null,
    rcNs: 0,
    rcNr: 0,
    rcPN: 0,
    rcNHKs: nhk,
    rcNHKr: initParams.rcvNextHK,
  }
}

// initRcvRatchet (Ratchet.hs:674-699)
// Used by initiator (Alice) after receiving confirmation
export function initRcvRatchet(
  version: number,
  maxVersion: number,
  rcDHRs: Uint8Array,    // our X448 private key (raw)
  initParams: RatchetInitParams,
  pqSupport: boolean,
): RatchetState {
  return {
    rcVersion: version,
    rcMaxVersion: maxVersion,
    rcAD: initParams.assocData,
    rcDHRs,
    rcSupportKEM: pqSupport,
    rcRK: initParams.ratchetKey,
    rcSnd: null,
    rcRcv: null,
    rcNs: 0,
    rcNr: 0,
    rcPN: 0,
    rcNHKs: initParams.rcvNextHK,
    rcNHKr: initParams.sndHK,
  }
}

// -- Message header (Ratchet.hs:703-787)

interface MsgHeader {
  msgMaxVersion: number
  msgDHRs: Uint8Array    // X448 public key (raw, 56 bytes)
  msgPN: number
  msgNs: number
}

function encodeMsgHeader(v: number, hdr: MsgHeader): Uint8Array {
  const versionBytes = new Uint8Array(2)
  versionBytes[0] = (hdr.msgMaxVersion >> 8) & 0xff
  versionBytes[1] = hdr.msgMaxVersion & 0xff
  const dhDer = encodePubKeyX448(hdr.msgDHRs)
  const pn = new Uint8Array(4)
  pn[0] = (hdr.msgPN >> 24) & 0xff; pn[1] = (hdr.msgPN >> 16) & 0xff
  pn[2] = (hdr.msgPN >> 8) & 0xff; pn[3] = hdr.msgPN & 0xff
  const ns = new Uint8Array(4)
  ns[0] = (hdr.msgNs >> 24) & 0xff; ns[1] = (hdr.msgNs >> 16) & 0xff
  ns[2] = (hdr.msgNs >> 8) & 0xff; ns[3] = hdr.msgNs & 0xff
  // v >= pqRatchetE2EEncryptVersion (v3): includes KEM params (Maybe, encoded as Nothing for now)
  if (v >= 3) {
    return concatBytes(versionBytes, encodeBytes(dhDer), new Uint8Array([0x30]), pn, ns) // '0' = Nothing for KEM
  }
  return concatBytes(versionBytes, encodeBytes(dhDer), pn, ns)
}

function decodeMsgHeader(v: number, data: Uint8Array): MsgHeader {
  const d = new Decoder(data)
  const msgMaxVersion = decodeWord16(d)
  const dhDer = decodeBytes(d)
  const msgDHRs = decodePubKeyX448(dhDer)
  // skip KEM params for v3+
  if (v >= 3) {
    const kemByte = d.anyByte()
    if (kemByte === 0x31) {
      // Just - skip KEM params (we don't process them in this simplified version)
      decodeBytes(d) // KEM params
    }
    // else '0' = Nothing, already consumed
  }
  const msgPN = decodeWord32(d)
  const msgNs = decodeWord32(d)
  return {msgMaxVersion, msgDHRs, msgPN, msgNs}
}

// -- Encrypt (Ratchet.hs:902-975)

export interface EncryptResult {
  ciphertext: Uint8Array
  state: RatchetState
}

export function rcEncrypt(
  state: RatchetState,
  plaintext: Uint8Array,
  paddedMsgLen: number,
): EncryptResult {
  if (!state.rcSnd) throw new Error("rcEncrypt: no sending ratchet")
  const snd = state.rcSnd
  const v = state.rcVersion

  // Advance chain: state.CKs, mk = KDF_CK(state.CKs)
  const {ck: rcCKs, mk, iv, ehIV} = chainKdf(snd.rcCKs)

  // Build and encrypt header
  const headerPlain = encodeMsgHeader(v, {
    msgMaxVersion: state.rcMaxVersion,
    msgDHRs: x448.getPublicKey(state.rcDHRs),
    msgPN: state.rcPN,
    msgNs: state.rcNs,
  })

  const phl = paddedHeaderLen(state.rcSupportKEM)
  const {authTag: ehAuthTag, ciphertext: ehBody} = encryptAEAD(snd.rcHKs, ehIV, phl, state.rcAD, headerPlain)

  // Encode EncMessageHeader
  const ehVersionBytes = new Uint8Array(2)
  ehVersionBytes[0] = (v >> 8) & 0xff; ehVersionBytes[1] = v & 0xff
  // IV and AuthTag are raw bytes (no length prefix). Body is Large for v3+, ByteString for older.
  const encHeader = concatBytes(ehVersionBytes, ehIV, ehAuthTag, v >= 3 ? encodeLarge(ehBody) : encodeBytes(ehBody))

  // Encrypt body: ENCRYPT(mk, plaintext, CONCAT(AD, enc_header))
  const bodyAD = concatBytes(state.rcAD, encHeader)
  const {authTag: emAuthTag, ciphertext: emBody} = encryptAEAD(mk, iv, paddedMsgLen, bodyAD, plaintext)

  // Encode EncRatchetMessage
  // AuthTag is raw 16 bytes (no length prefix), body is Tail (raw bytes)
  const msgBytes = concatBytes(v >= 3 ? encodeLarge(encHeader) : encodeBytes(encHeader), emAuthTag, emBody)

  // Update state
  const newState: RatchetState = {
    ...state,
    rcSnd: {...snd, rcCKs},
    rcNs: state.rcNs + 1,
  }

  return {ciphertext: msgBytes, state: newState}
}

// -- Decrypt (Ratchet.hs:990-1157)

export interface DecryptResult {
  plaintext: Uint8Array
  state: RatchetState
  skippedKeys: SkippedMsgKeys
}

interface EncRatchetMessage {
  emHeader: Uint8Array
  emAuthTag: Uint8Array
  emBody: Uint8Array
}

interface EncMessageHeader {
  ehVersion: number
  ehIV: Uint8Array
  ehAuthTag: Uint8Array
  ehBody: Uint8Array
}

function parseEncRatchetMessage(data: Uint8Array): EncRatchetMessage {
  const d = new Decoder(data)
  // header is length-prefixed (Large for v3+, ByteString for older)
  const firstByte = data[d.offset()]
  const emHeader = firstByte < 32 ? decodeLarge(d) : decodeBytes(d)
  // AuthTag is raw 16 bytes (no length prefix)
  const emAuthTag = d.take(16)
  const emBody = d.takeAll()
  return {emHeader, emAuthTag, emBody}
}

function parseEncMessageHeader(data: Uint8Array): EncMessageHeader {
  const d = new Decoder(data)
  const ehVersion = decodeWord16(d)
  // IV is raw 16 bytes, AuthTag is raw 16 bytes
  const ehIV = d.take(16)
  const ehAuthTag = d.take(16)
  // body: Large for v3+ (first byte < 32), ByteString for older
  const firstByte = data[d.offset()]
  const ehBody = firstByte < 32 ? decodeLarge(d) : decodeBytes(d)
  return {ehVersion, ehIV, ehAuthTag, ehBody}
}

function tryDecryptHeader(headerKey: Uint8Array, ad: Uint8Array, encHdr: EncMessageHeader): MsgHeader | null {
  try {
    const plainHeader = decryptAEAD(headerKey, encHdr.ehIV, ad, encHdr.ehBody, encHdr.ehAuthTag)
    return decodeMsgHeader(encHdr.ehVersion, plainHeader)
  } catch {
    return null
  }
}

function decryptMessage(mk: Uint8Array, iv: Uint8Array, ad: Uint8Array, encHeader: Uint8Array, encMsg: EncRatchetMessage): Uint8Array {
  const bodyAD = concatBytes(ad, encHeader)
  return decryptAEAD(mk, iv, bodyAD, encMsg.emBody, encMsg.emAuthTag)
}

export function rcDecrypt(
  state: RatchetState,
  skippedKeys: SkippedMsgKeys,
  ciphertext: Uint8Array,
): DecryptResult {
  const encMsg = parseEncRatchetMessage(ciphertext)
  const encHdr = parseEncMessageHeader(encMsg.emHeader)

  // Try skipped message keys
  for (const [hkHex, msgKeys] of skippedKeys) {
    const hk = hexToBytes(hkHex)
    const hdr = tryDecryptHeader(hk, state.rcAD, encHdr)
    if (hdr) {
      const mk = msgKeys.get(hdr.msgNs)
      if (mk) {
        // Found in skipped keys - decrypt and remove
        const plaintext = decryptMessage(mk.mk, mk.iv, state.rcAD, encMsg.emHeader, encMsg)
        const newMsgKeys = new Map(msgKeys)
        newMsgKeys.delete(hdr.msgNs)
        const newSkipped = new Map(skippedKeys)
        if (newMsgKeys.size === 0) newSkipped.delete(hkHex)
        else newSkipped.set(hkHex, newMsgKeys)
        return {plaintext, state, skippedKeys: newSkipped}
      }
    }
  }

  // Try current receiving ratchet header key
  let ratchetStep: "same" | "advance" = "advance"
  let hdr: MsgHeader | null = null

  if (state.rcRcv) {
    hdr = tryDecryptHeader(state.rcRcv.rcHKr, state.rcAD, encHdr)
    if (hdr) ratchetStep = "same"
  }

  // Try next header key (advance ratchet)
  if (!hdr) {
    hdr = tryDecryptHeader(state.rcNHKr, state.rcAD, encHdr)
    if (!hdr) throw new Error("rcDecrypt: header decryption failed")
    ratchetStep = "advance"
  }

  // Upgrade version
  let rc = state
  if (hdr.msgMaxVersion > rc.rcVersion) {
    rc = {...rc, rcVersion: Math.max(rc.rcVersion, Math.min(hdr.msgMaxVersion, rc.rcMaxVersion))}
  }

  let newSkipped = new Map(skippedKeys)

  if (ratchetStep === "advance") {
    // Skip message keys for previous ratchet
    const skipResult = skipMessageKeys(rc, newSkipped, hdr.msgPN)
    rc = skipResult.state
    newSkipped = skipResult.skippedKeys

    // DH ratchet step
    const rcDHRs_new = generateX448KeyPair()
    // state.RK, state.CKr, state.NHKr = KDF_RK_HE(state.RK, DH(state.DHRs, header.dh))
    const {rk: rcRK1, ck: rcCKr, nhk: rcNHKr} = rootKdf(rc.rcRK, hdr.msgDHRs, rc.rcDHRs, null)
    // state.RK, state.CKs, state.NHKs = KDF_RK_HE(state.RK, DH(state.DHRs', header.dh))
    const {rk: rcRK2, ck: rcCKs, nhk: rcNHKs} = rootKdf(rcRK1, hdr.msgDHRs, rcDHRs_new.privateKey, null)

    rc = {
      ...rc,
      rcDHRs: rcDHRs_new.privateKey,
      rcRK: rcRK2,
      rcSnd: {rcDHRr: hdr.msgDHRs, rcCKs, rcHKs: rc.rcNHKs},
      rcRcv: {rcCKr, rcHKr: rc.rcNHKr},
      rcPN: rc.rcNs,
      rcNs: 0,
      rcNr: 0,
      rcNHKs,
      rcNHKr,
    }
  }

  // Skip message keys for current ratchet
  const skipResult2 = skipMessageKeys(rc, newSkipped, hdr.msgNs)
  rc = skipResult2.state
  newSkipped = skipResult2.skippedKeys

  if (!rc.rcRcv) throw new Error("rcDecrypt: no receiving ratchet after skip")

  // Decrypt message
  const {ck: rcCKr, mk, iv} = chainKdf(rc.rcRcv.rcCKr)
  const plaintext = decryptMessage(mk, iv, rc.rcAD, encMsg.emHeader, encMsg)

  rc = {
    ...rc,
    rcRcv: {...rc.rcRcv, rcCKr},
    rcNr: rc.rcNr + 1,
  }

  return {plaintext, state: rc, skippedKeys: newSkipped}
}

function skipMessageKeys(
  state: RatchetState,
  skippedKeys: SkippedMsgKeys,
  untilN: number,
): {state: RatchetState; skippedKeys: SkippedMsgKeys} {
  if (!state.rcRcv) return {state, skippedKeys}
  const rcv = state.rcRcv
  const rcNr = state.rcNr

  if (rcNr > untilN + 1) throw new Error("rcDecrypt: earlier message")
  if (rcNr === untilN + 1) throw new Error("rcDecrypt: duplicate message")
  if (rcNr + MAX_SKIP < untilN) throw new Error("rcDecrypt: too many skipped")
  if (rcNr === untilN) return {state, skippedKeys}

  // Advance receiving ratchet, storing skipped keys
  let ck = rcv.rcCKr
  let nr = rcNr
  const hkHex = hexKey(rcv.rcHKr)
  const msgKeys = new Map(skippedKeys.get(hkHex) || new Map())

  while (nr < untilN) {
    const chain = chainKdf(ck)
    msgKeys.set(nr, {mk: chain.mk, iv: chain.iv})
    ck = chain.ck
    nr++
  }

  const newSkipped = new Map(skippedKeys)
  newSkipped.set(hkHex, msgKeys)

  return {
    state: {...state, rcRcv: {...rcv, rcCKr: ck}, rcNr: nr},
    skippedKeys: newSkipped,
  }
}

function hexToBytes(hex: string): Uint8Array {
  const bytes = new Uint8Array(hex.length / 2)
  for (let i = 0; i < hex.length; i += 2) {
    bytes[i / 2] = parseInt(hex.substring(i, i + 2), 16)
  }
  return bytes
}
