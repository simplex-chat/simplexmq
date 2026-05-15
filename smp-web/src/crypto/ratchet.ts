// Double ratchet with X3DH key agreement and PQ KEM.
// Faithful transpilation of Simplex.Messaging.Crypto.Ratchet
//
// Every type, field, and function mirrors the Haskell source.
// Line references are to src/Simplex/Messaging/Crypto/Ratchet.hs

import {x448} from "@noble/curves/ed448.js"
import {hkdf, encryptAEAD, decryptAEAD, AUTH_TAG_SIZE} from "../crypto.js"
import {sntrup761Keypair, sntrup761Enc, sntrup761Dec} from "./sntrup761.js"
import type {KEMKeyPair} from "./sntrup761.js"
import {
  Decoder, concatBytes,
  encodeBytes, decodeBytes, decodeWord16, decodeWord32,
  encodeLarge, decodeLarge,
  encodeMaybe,
} from "@simplex-chat/xftp-web/dist/protocol/encoding.js"

// -- Version constants (lines 134-155)

export const pqRatchetE2EEncryptVersion = 3
export const currentE2EEncryptVersion = 3

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
// SEQUENCE { SEQUENCE { OID 1.3.101.111 } BIT STRING { 0x00 <56 bytes> } }
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

// -- KEM types (lines 567-577)
// KEMKeyPair imported from ./sntrup761.js

export interface RatchetKEMAccepted {
  rcPQRr: Uint8Array      // KEMPublicKey - received key (1158 bytes)
  rcPQRss: Uint8Array     // KEMSharedKey - computed shared secret (32 bytes)
  rcPQRct: Uint8Array     // KEMCiphertext - sent encaps (1039 bytes)
}

export interface RatchetKEM {
  rcPQRs: KEMKeyPair
  rcKEMs: RatchetKEMAccepted | null
}

// -- RatchetInitParams (lines 457-464)

export interface RatchetInitParams {
  assocData: Uint8Array              // Str (raw bytes)
  ratchetKey: Uint8Array             // RatchetKey (32 bytes)
  sndHK: Uint8Array                  // HeaderKey (32 bytes)
  rcvNextHK: Uint8Array              // HeaderKey (32 bytes)
  kemAccepted: RatchetKEMAccepted | null  // Maybe RatchetKEMAccepted
}

// -- hkdf3 (lines 1174-1179)

function hkdf3(salt: Uint8Array, ikm: Uint8Array, info: string): [Uint8Array, Uint8Array, Uint8Array] {
  const out = hkdf(salt, ikm, info, 96)
  return [out.slice(0, 32), out.slice(32, 64), out.slice(64, 96)]
}

// -- pqX3dh (lines 499-508)

const X3DH_SALT = new Uint8Array(64)

function pqX3dh(
  sk1: Uint8Array, rk1: Uint8Array,
  dh1: Uint8Array, dh2: Uint8Array, dh3: Uint8Array,
  kemAccepted: RatchetKEMAccepted | null,
): RatchetInitParams {
  const assocData = concatBytes(sk1, rk1)
  const pq = kemAccepted ? kemAccepted.rcPQRss : new Uint8Array(0)
  const dhs = concatBytes(dh1, dh2, dh3, pq)
  const [hk, nhk, sk] = hkdf3(X3DH_SALT, dhs, "SimpleXX3DH")
  return {assocData, ratchetKey: sk, sndHK: hk, rcvNextHK: nhk, kemAccepted}
}

// -- pqX3dhSnd (lines 467-480)
// Used by joiner (Alice in PQDR spec, Bob in DR spec) to init SENDING ratchet.

export function pqX3dhSnd(
  spk1: Uint8Array, spk2: Uint8Array,   // our private keys
  rk1: Uint8Array, rk2: Uint8Array,     // their public keys (raw)
  kemAccepted: RatchetKEMAccepted | null = null,
): RatchetInitParams {
  const sk1Pub = x448.getPublicKey(spk1)
  const dh1 = x448DH(rk1, spk2)
  const dh2 = x448DH(rk2, spk1)
  const dh3 = x448DH(rk2, spk2)
  return pqX3dh(sk1Pub, rk1, dh1, dh2, dh3, kemAccepted)
}

// -- pqX3dhRcv (lines 483-497)
// Used by initiator (Bob in PQDR spec, Alice in DR spec) to init RECEIVING ratchet.

export function pqX3dhRcv(
  rpk1: Uint8Array, rpk2: Uint8Array,   // our private keys
  sk1: Uint8Array, sk2: Uint8Array,     // their public keys (raw)
  kemAccepted: RatchetKEMAccepted | null = null,
): RatchetInitParams {
  const rk1Pub = x448.getPublicKey(rpk1)
  const dh1 = x448DH(sk2, rpk1)
  const dh2 = x448DH(sk1, rpk2)
  const dh3 = x448DH(sk2, rpk2)
  return pqX3dh(sk1, rk1Pub, dh1, dh2, dh3, kemAccepted)
}

// -- rootKdf (lines 1159-1166)

export function rootKdf(
  rk: Uint8Array,           // RatchetKey (32 bytes)
  peerPubKey: Uint8Array,   // PublicKey a (raw, 56 bytes for X448)
  ownPrivKey: Uint8Array,   // PrivateKey a (raw, 56 bytes for X448)
  kemSecret: Uint8Array | null,  // Maybe KEMSharedKey
): {rk: Uint8Array; ck: Uint8Array; nhk: Uint8Array} {
  const dhOut = x448DH(peerPubKey, ownPrivKey)
  const ss = kemSecret ? concatBytes(dhOut, kemSecret) : dhOut
  const [rk_, ck, nhk] = hkdf3(rk, ss, "SimpleXRootRatchet")
  return {rk: rk_, ck, nhk}
}

// -- chainKdf (lines 1168-1172)

export function chainKdf(ck: Uint8Array): {ck: Uint8Array; mk: Uint8Array; iv: Uint8Array; ehIV: Uint8Array} {
  const EMPTY = new Uint8Array(0)
  const [ck_, mk, ivs] = hkdf3(EMPTY, ck, "SimpleXChainRatchet")
  return {ck: ck_, mk, iv: ivs.slice(0, 16), ehIV: ivs.slice(16, 32)}
}

// -- Header padding (lines 716-719)

export function paddedHeaderLen(v: number, pqSupport: boolean): number {
  if (pqSupport && v >= pqRatchetE2EEncryptVersion) return 2310
  return 88
}

// -- SndRatchet (lines 554-559)

export interface SndRatchet {
  rcDHRr: Uint8Array   // peer's public key (raw, 56 bytes)
  rcCKs: Uint8Array    // sending chain key (32 bytes)
  rcHKs: Uint8Array    // sending header key (32 bytes)
}

// -- RcvRatchet (lines 561-565)

export interface RcvRatchet {
  rcCKr: Uint8Array    // receiving chain key (32 bytes)
  rcHKr: Uint8Array    // receiving header key (32 bytes)
}

// -- MessageKey (lines 608-609)

export interface MessageKey {
  mk: Uint8Array       // Key (32 bytes)
  iv: Uint8Array       // IV (16 bytes)
}

// -- RatchetVersions (lines 534-538)

export interface RatchetVersions {
  current: number
  maxSupported: number
}

// -- Ratchet (lines 512-532)

export interface Ratchet {
  rcVersion: RatchetVersions
  rcAD: Uint8Array             // Str (associated data, raw bytes)
  rcDHRs: Uint8Array           // PrivateKey a (raw, 56 bytes)
  rcKEM: RatchetKEM | null
  rcSupportKEM: boolean        // PQSupport
  rcEnableKEM: boolean         // PQEncryption
  rcSndKEM: boolean            // PQEncryption
  rcRcvKEM: boolean            // PQEncryption
  rcRK: Uint8Array             // RatchetKey (32 bytes)
  rcSnd: SndRatchet | null
  rcRcv: RcvRatchet | null
  rcNs: number                 // Word32
  rcNr: number                 // Word32
  rcPN: number                 // Word32
  rcNHKs: Uint8Array           // HeaderKey (32 bytes)
  rcNHKr: Uint8Array           // HeaderKey (32 bytes)
}

// -- SkippedMsgKeys (lines 580-582)

export type SkippedMsgKeys = Map<string, Map<number, MessageKey>>

const MAX_SKIP = 512

function hexKey(k: Uint8Array): string {
  return Array.from(k, b => b.toString(16).padStart(2, "0")).join("")
}

function hexToBytes(hex: string): Uint8Array {
  const bytes = new Uint8Array(hex.length / 2)
  for (let i = 0; i < hex.length; i += 2) bytes[i / 2] = parseInt(hex.substring(i, i + 2), 16)
  return bytes
}

// -- initSndRatchet (lines 643-666)

export function initSndRatchet(
  rcVersion: RatchetVersions,
  rcDHRr: Uint8Array,     // peer's public key (raw)
  rcDHRs: Uint8Array,     // our private key (raw)
  initParams: RatchetInitParams,
  rcPQRs_: KEMKeyPair | null,
): Ratchet {
  const {assocData, ratchetKey, sndHK, rcvNextHK, kemAccepted} = initParams
  // state.RK, state.CKs, state.NHKs = KDF_RK_HE(SK, DH(state.DHRs, state.DHRr) || state.PQRss)
  const kemSecret = kemAccepted ? kemAccepted.rcPQRss : null
  const {rk: rcRK, ck: rcCKs, nhk: rcNHKs} = rootKdf(ratchetKey, rcDHRr, rcDHRs, kemSecret)
  const pqOn = rcPQRs_ !== null
  return {
    rcVersion,
    rcAD: assocData,
    rcDHRs,
    rcKEM: rcPQRs_ ? {rcPQRs: rcPQRs_, rcKEMs: kemAccepted} : null,
    rcSupportKEM: pqOn,
    rcEnableKEM: pqOn,
    rcSndKEM: kemAccepted !== null,
    rcRcvKEM: false,
    rcRK,
    rcSnd: {rcDHRr, rcCKs, rcHKs: sndHK},
    rcRcv: null,
    rcPN: 0,
    rcNs: 0,
    rcNr: 0,
    rcNHKs,
    rcNHKr: rcvNextHK,
  }
}

// -- initRcvRatchet (lines 674-699)

export function initRcvRatchet(
  rcVersion: RatchetVersions,
  rcDHRs: Uint8Array,     // our private key (raw)
  initParams: RatchetInitParams,
  rcPQRs_: KEMKeyPair | null,
  pqSupport: boolean,
): Ratchet {
  const {assocData, ratchetKey, sndHK, rcvNextHK, kemAccepted} = initParams
  return {
    rcVersion,
    rcAD: assocData,
    rcDHRs,
    rcKEM: rcPQRs_ ? {rcPQRs: rcPQRs_, rcKEMs: kemAccepted} : null,
    rcSupportKEM: pqSupport,
    rcEnableKEM: pqSupport,
    rcSndKEM: false,
    rcRcvKEM: false,
    rcRK: ratchetKey,
    rcSnd: null,
    rcRcv: null,
    rcPN: 0,
    rcNs: 0,
    rcNr: 0,
    rcNHKs: rcvNextHK,
    rcNHKr: sndHK,
  }
}

// -- RKEMParams (lines 188-190) - parsed KEM params from message header

export type RKEMParams =
  | {type: "proposed", kemPk: Uint8Array}          // RKParamsProposed KEMPublicKey
  | {type: "accepted", kemCt: Uint8Array, kemPk: Uint8Array}  // RKParamsAccepted KEMCiphertext KEMPublicKey

// -- MsgHeader (lines 703-711)

interface MsgHeader {
  msgMaxVersion: number
  msgDHRs: Uint8Array    // PublicKey a (raw, 56 bytes)
  msgKEM: RKEMParams | null
  msgPN: number          // Word32
  msgNs: number          // Word32
}

// -- encodeMsgHeader (lines 727-730)

function encodeMsgHeader(v: number, hdr: MsgHeader): Uint8Array {
  const vBytes = new Uint8Array(2)
  vBytes[0] = (hdr.msgMaxVersion >> 8) & 0xff
  vBytes[1] = hdr.msgMaxVersion & 0xff
  const dhDer = encodePubKeyX448(hdr.msgDHRs)
  const pn = encodeWord32(hdr.msgPN)
  const ns = encodeWord32(hdr.msgNs)
  if (v >= pqRatchetE2EEncryptVersion) {
    // smpEncode (msgMaxVersion, msgDHRs, msgKEM, msgPN, msgNs)
    // msgKEM :: Maybe ARKEMParams
    const kemBytes = hdr.msgKEM ? encodeRKEMParams(hdr.msgKEM) : new Uint8Array([0x30])  // Nothing
    return concatBytes(vBytes, encodeBytes(dhDer), kemBytes, pn, ns)
  }
  // smpEncode (msgMaxVersion, msgDHRs, msgPN, msgNs)
  return concatBytes(vBytes, encodeBytes(dhDer), pn, ns)
}

// Encode Maybe ARKEMParams: '1' + encoded params, or nothing (handled at call site with '0')
function encodeRKEMParams(params: RKEMParams): Uint8Array {
  if (params.type === "proposed") {
    // Just ('P', kemPk) - smpEncode ('P', k) where k is KEMPublicKey (Large)
    return concatBytes(new Uint8Array([0x31, 0x50]), encodeLarge(params.kemPk))
  }
  // Just ('A', ct, kemPk) - smpEncode ('A', ct, k)
  return concatBytes(new Uint8Array([0x31, 0x41]), encodeLarge(params.kemCt), encodeLarge(params.kemPk))
}

function encodeWord32(n: number): Uint8Array {
  const buf = new Uint8Array(4)
  buf[0] = (n >> 24) & 0xff; buf[1] = (n >> 16) & 0xff
  buf[2] = (n >> 8) & 0xff; buf[3] = n & 0xff
  return buf
}

// -- msgHeaderP (lines 733-740)

function decodeMsgHeader(v: number, data: Uint8Array): MsgHeader {
  const d = new Decoder(data)
  const msgMaxVersion = decodeWord16(d)
  const dhDer = decodeBytes(d)
  const msgDHRs = decodePubKeyX448(dhDer)
  let msgKEM: RKEMParams | null = null
  if (v >= pqRatchetE2EEncryptVersion) {
    // Maybe ARKEMParams
    const maybeByte = d.anyByte()
    if (maybeByte === 0x31) {
      // Just - parse ARKEMParams
      const tag = d.anyByte()
      if (tag === 0x50) { // 'P' - Proposed: KEMPublicKey (Large)
        msgKEM = {type: "proposed", kemPk: decodeLarge(d)}
      } else if (tag === 0x41) { // 'A' - Accepted: KEMCiphertext (Large) + KEMPublicKey (Large)
        const kemCt = decodeLarge(d)
        const kemPk = decodeLarge(d)
        msgKEM = {type: "accepted", kemCt, kemPk}
      } else {
        throw new Error("decodeMsgHeader: unknown KEM tag " + tag)
      }
    }
    // else '0' = Nothing, msgKEM stays null
  }
  const msgPN = decodeWord32(d)
  const msgNs = decodeWord32(d)
  return {msgMaxVersion, msgDHRs, msgKEM, msgPN, msgNs}
}

// -- EncMessageHeader (lines 742-756)

interface EncMessageHeader {
  ehVersion: number     // current ratchet version
  ehIV: Uint8Array      // IV (raw 16 bytes)
  ehAuthTag: Uint8Array // AuthTag (raw 16 bytes)
  ehBody: Uint8Array    // encrypted header body
}

// smpEncode (lines 751-752)
function encodeEncMessageHeader(emh: EncMessageHeader): Uint8Array {
  const vBytes = new Uint8Array(2)
  vBytes[0] = (emh.ehVersion >> 8) & 0xff
  vBytes[1] = emh.ehVersion & 0xff
  // smpEncode (ehVersion, ehIV, ehAuthTag) <> encodeLarge ehVersion ehBody
  const bodyEnc = emh.ehVersion >= pqRatchetE2EEncryptVersion
    ? encodeLarge(emh.ehBody)
    : encodeBytes(emh.ehBody)
  return concatBytes(vBytes, emh.ehIV, emh.ehAuthTag, bodyEnc)
}

// smpP (lines 753-756)
function decodeEncMessageHeader(data: Uint8Array): EncMessageHeader {
  const d = new Decoder(data)
  const ehVersion = decodeWord16(d)
  const ehIV = d.take(16)      // IV is raw 16 bytes
  const ehAuthTag = d.take(16) // AuthTag is raw 16 bytes
  // largeP: peek first byte, if < 32 then Large (2-byte len), else ByteString (1-byte len)
  const firstByte = data[d.offset()]
  const ehBody = firstByte < 32 ? decodeLarge(d) : decodeBytes(d)
  return {ehVersion, ehIV, ehAuthTag, ehBody}
}

// -- EncRatchetMessage (lines 772-787)

interface EncRatchetMessage {
  emHeader: Uint8Array   // smpEncoded EncMessageHeader
  emAuthTag: Uint8Array  // AuthTag (raw 16 bytes)
  emBody: Uint8Array     // encrypted message body
}

// encodeEncRatchetMessage (lines 779-781)
function encodeEncRatchetMessage(v: number, msg: EncRatchetMessage): Uint8Array {
  // encodeLarge v emHeader <> smpEncode (emAuthTag, Tail emBody)
  const headerEnc = v >= pqRatchetE2EEncryptVersion
    ? encodeLarge(msg.emHeader)
    : encodeBytes(msg.emHeader)
  return concatBytes(headerEnc, msg.emAuthTag, msg.emBody)
}

// encRatchetMessageP (lines 783-787)
function decodeEncRatchetMessage(data: Uint8Array): EncRatchetMessage {
  const d = new Decoder(data)
  // largeP
  const firstByte = data[d.offset()]
  const emHeader = firstByte < 32 ? decodeLarge(d) : decodeBytes(d)
  // smpEncode (emAuthTag, Tail emBody) → raw 16 bytes + rest
  const emAuthTag = d.take(16)
  const emBody = d.takeAll()
  return {emHeader, emAuthTag, emBody}
}

// -- MsgEncryptKey (lines 962-968)

interface MsgEncryptKey {
  msgRcVersion: number
  msgKey: MessageKey
  msgRcAD: Uint8Array
  msgEncHeader: Uint8Array
}

// -- msgKEMParams (lines 956-958) - build KEM params from ratchet state for message header

function msgKEMParams(kem: RatchetKEM): RKEMParams {
  const {rcPQRs, rcKEMs} = kem
  if (!rcKEMs) {
    return {type: "proposed", kemPk: rcPQRs.publicKey}
  }
  return {type: "accepted", kemCt: rcKEMs.rcPQRct, kemPk: rcPQRs.publicKey}
}

// -- pqEnableSupport (line 836-837)

function pqEnableSupport(v: number, sup: boolean, enc: boolean): boolean {
  return sup || (v >= pqRatchetE2EEncryptVersion && enc)
}

// -- rcEncryptHeader + rcEncryptMsg (lines 902-975)

export interface EncryptResult {
  ciphertext: Uint8Array
  state: Ratchet
}

export function rcEncrypt(
  rc: Ratchet,
  plaintext: Uint8Array,
  paddedMsgLen: number,
): EncryptResult {
  if (!rc.rcSnd) throw new Error("rcEncrypt: no sending ratchet (CERatchetState)")
  const snd = rc.rcSnd
  const v = rc.rcVersion.current

  // state.CKs, mk = KDF_CK(state.CKs)
  const chain = chainKdf(snd.rcCKs)

  // header
  const headerPlain = encodeMsgHeader(v, {
    msgMaxVersion: rc.rcVersion.maxSupported,
    msgDHRs: x448.getPublicKey(rc.rcDHRs),
    msgKEM: rc.rcKEM ? msgKEMParams(rc.rcKEM) : null,
    msgPN: rc.rcPN,
    msgNs: rc.rcNs,
  })

  // enc_header = HENCRYPT(state.HKs, header)
  const phl = paddedHeaderLen(v, rc.rcSupportKEM)
  const {authTag: ehAuthTag, ciphertext: ehBody} = encryptAEAD(snd.rcHKs, chain.ehIV, phl, rc.rcAD, headerPlain)

  // smpEncode EncMessageHeader
  const emHeader = encodeEncMessageHeader({ehVersion: v, ehBody, ehAuthTag, ehIV: chain.ehIV})

  // ENCRYPT(mk, plaintext, CONCAT(AD, enc_header))
  const bodyAD = concatBytes(rc.rcAD, emHeader)
  const {authTag: emAuthTag, ciphertext: emBody} = encryptAEAD(chain.mk, chain.iv, paddedMsgLen, bodyAD, plaintext)

  // encodeEncRatchetMessage
  const ciphertext = encodeEncRatchetMessage(v, {emHeader, emBody, emAuthTag})

  // Update state
  const newState: Ratchet = {
    ...rc,
    rcSnd: {...snd, rcCKs: chain.ck},
    rcNs: rc.rcNs + 1,
  }

  return {ciphertext, state: newState}
}

// -- rcDecrypt (lines 990-1157)

export interface DecryptResult {
  plaintext: Uint8Array
  state: Ratchet
  skippedKeys: SkippedMsgKeys
}

export function rcDecrypt(
  rc: Ratchet,
  skippedKeys: SkippedMsgKeys,
  ciphertext: Uint8Array,
): DecryptResult {
  const encMsg = decodeEncRatchetMessage(ciphertext)
  const encHdr = decodeEncMessageHeader(encMsg.emHeader)

  // TrySkippedMessageKeysHE
  const skipped = tryDecryptSkipped(rc, skippedKeys, encHdr, encMsg)
  if (skipped) return skipped

  // DecryptHeader
  let ratchetStep: "same" | "advance" = "advance"
  let hdr: MsgHeader | null = null

  if (rc.rcRcv) {
    hdr = tryDecryptHeader(rc.rcRcv.rcHKr, rc.rcAD, encHdr)
    if (hdr) ratchetStep = "same"
  }
  if (!hdr) {
    hdr = tryDecryptHeader(rc.rcNHKr, rc.rcAD, encHdr)
    if (!hdr) throw new Error("rcDecrypt: header decryption failed (CERatchetHeader)")
    ratchetStep = "advance"
  }

  // Version upgrade
  let state = rc
  const {current, maxSupported} = rc.rcVersion
  if (hdr.msgMaxVersion > current) {
    state = {...state, rcVersion: {...state.rcVersion, current: Math.max(current, Math.min(hdr.msgMaxVersion, maxSupported))}}
  }

  let newSkipped = new Map(skippedKeys)

  if (ratchetStep === "advance") {
    // SkipMessageKeysHE(state, header.pn)
    const skip1 = skipMessageKeys(state, newSkipped, hdr.msgPN)
    state = skip1.state; newSkipped = skip1.skippedKeys

    // DHRatchetPQ2HE(state, header) - ratchet step (lines 1043-1071)
    const {kemSS, kemSS2, rcKEM: rcKEM_} = pqRatchetStep(state, hdr.msgKEM)
    const newDHRs = generateX448KeyPair()
    // state.RK, state.CKr, state.NHKr = KDF_RK_HE(state.RK, DH(state.DHRs, state.DHRr) || ss)
    const kdf1 = rootKdf(state.rcRK, hdr.msgDHRs, state.rcDHRs, kemSS)
    // state.RK, state.CKs, state.NHKs = KDF_RK_HE(state.RK, DH(state.DHRs', state.DHRr) || state.PQRss)
    const kdf2 = rootKdf(kdf1.rk, hdr.msgDHRs, newDHRs.privateKey, kemSS2)
    const sndKEM = kemSS2 !== null
    const rcvKEM = kemSS !== null
    const rcEnableKEM_ = sndKEM || rcvKEM || rcKEM_ !== null

    state = {
      ...state,
      rcDHRs: newDHRs.privateKey,
      rcKEM: rcKEM_,
      rcSupportKEM: pqEnableSupport(state.rcVersion.current, state.rcSupportKEM, rcEnableKEM_),
      rcEnableKEM: rcEnableKEM_,
      rcSndKEM: sndKEM,
      rcRcvKEM: rcvKEM,
      rcRK: kdf2.rk,
      rcSnd: {rcDHRr: hdr.msgDHRs, rcCKs: kdf2.ck, rcHKs: state.rcNHKs},
      rcRcv: {rcCKr: kdf1.ck, rcHKr: state.rcNHKr},
      rcPN: rc.rcNs,
      rcNs: 0,
      rcNr: 0,
      rcNHKs: kdf2.nhk,
      rcNHKr: kdf1.nhk,
    }
  }

  // SkipMessageKeysHE(state, header.n)
  const skip2 = skipMessageKeys(state, newSkipped, hdr.msgNs)
  state = skip2.state; newSkipped = skip2.skippedKeys

  if (!state.rcRcv) throw new Error("rcDecrypt: no receiving ratchet after skip")

  // state.CKr, mk = KDF_CK(state.CKr)
  const chain = chainKdf(state.rcRcv.rcCKr)

  // DECRYPT(mk, cipher-text, CONCAT(AD, enc_header))
  const bodyAD = concatBytes(state.rcAD, encMsg.emHeader)
  const plaintext = decryptAEAD(chain.mk, chain.iv, bodyAD, encMsg.emBody, encMsg.emAuthTag)

  // state.Nr += 1
  state = {
    ...state,
    rcRcv: {...state.rcRcv, rcCKr: chain.ck},
    rcNr: state.rcNr + 1,
  }

  return {plaintext, state, skippedKeys: newSkipped}
}

// -- skipMessageKeys (lines 1105-1121)

function skipMessageKeys(
  rc: Ratchet,
  skippedKeys: SkippedMsgKeys,
  untilN: number,
): {state: Ratchet; skippedKeys: SkippedMsgKeys} {
  if (!rc.rcRcv) return {state: rc, skippedKeys}
  const rcv = rc.rcRcv
  const rcNr = rc.rcNr

  if (rcNr > untilN + 1) throw new Error("rcDecrypt: earlier message (CERatchetEarlierMessage)")
  if (rcNr === untilN + 1) throw new Error("rcDecrypt: duplicate message (CERatchetDuplicateMessage)")
  if (rcNr + MAX_SKIP < untilN) throw new Error("rcDecrypt: too many skipped (CERatchetTooManySkipped)")
  if (rcNr === untilN) return {state: rc, skippedKeys}

  // advanceRcvRatchet
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
    state: {...rc, rcRcv: {...rcv, rcCKr: ck}, rcNr: nr},
    skippedKeys: newSkipped,
  }
}

// -- tryDecryptSkipped (lines 1122-1141)

function tryDecryptSkipped(
  rc: Ratchet,
  skippedKeys: SkippedMsgKeys,
  encHdr: EncMessageHeader,
  encMsg: EncRatchetMessage,
): DecryptResult | null {
  for (const [hkHex, msgKeys] of skippedKeys) {
    const hk = hexToBytes(hkHex)
    const hdr = tryDecryptHeader(hk, rc.rcAD, encHdr)
    if (hdr) {
      const mk = msgKeys.get(hdr.msgNs)
      if (mk) {
        const bodyAD = concatBytes(rc.rcAD, encMsg.emHeader)
        const plaintext = decryptAEAD(mk.mk, mk.iv, bodyAD, encMsg.emBody, encMsg.emAuthTag)
        const newMsgKeys = new Map(msgKeys)
        newMsgKeys.delete(hdr.msgNs)
        const newSkipped = new Map(skippedKeys)
        if (newMsgKeys.size === 0) newSkipped.delete(hkHex)
        else newSkipped.set(hkHex, newMsgKeys)
        return {plaintext, state: rc, skippedKeys: newSkipped}
      }
      // Header decrypted but msgNs not in skipped keys - check if same/advance ratchet
      // For now, fall through to normal decrypt
    }
  }
  return null
}

// -- pqRatchetStep (lines 1072-1104)
// Returns (kemSS for receive rootKdf, kemSS' for send rootKdf, new RatchetKEM state)

function pqRatchetStep(
  rc: Ratchet,
  msgKEM: RKEMParams | null,
): {kemSS: Uint8Array | null; kemSS2: Uint8Array | null; rcKEM: RatchetKEM | null} {
  const pqEnc = rc.rcEnableKEM
  const v = rc.rcVersion.current

  if (!msgKEM) {
    // Received message does not have KEM in header
    if (!rc.rcKEM && pqEnc && v >= pqRatchetE2EEncryptVersion) {
      // User enabled KEM but no KEM state yet - generate new keypair
      const rcPQRs = sntrup761Keypair()
      return {kemSS: null, kemSS2: null, rcKEM: {rcPQRs, rcKEMs: null}}
    }
    return {kemSS: null, kemSS2: null, rcKEM: null}
  }

  // Received message has KEM in header
  if (pqEnc && v >= pqRatchetE2EEncryptVersion) {
    // Get shared secret from received KEM params
    const {ss, rcPQRr} = kemSharedSecret(rc.rcKEM, msgKEM)
    // state.PQRct = PQKEM-ENC(state.PQRr, state.PQRss)
    const kemEncResult = sntrup761Enc(rcPQRr)
    // state.PQRs = GENERATE_PQKEM()
    const rcPQRs = sntrup761Keypair()
    const kem: RatchetKEM = {
      rcPQRs,
      rcKEMs: {rcPQRr, rcPQRss: kemEncResult.sharedSecret, rcPQRct: kemEncResult.ciphertext},
    }
    return {kemSS: ss, kemSS2: kemEncResult.sharedSecret, rcKEM: kem}
  }

  // PQ not enabled but message has KEM - extract shared secret only (no new KEM state)
  const {ss} = kemSharedSecret(rc.rcKEM, msgKEM)
  return {kemSS: ss, kemSS2: null, rcKEM: null}
}

// Extract shared secret from received KEM params (lines 1097-1104)
function kemSharedSecret(
  rcKEM: RatchetKEM | null,
  params: RKEMParams,
): {ss: Uint8Array | null; rcPQRr: Uint8Array} {
  if (params.type === "proposed") {
    // RKParamsProposed k -> no shared secret yet, just received the public key
    return {ss: null, rcPQRr: params.kemPk}
  }
  // RKParamsAccepted ct k -> decapsulate ct with our private KEM key
  if (!rcKEM) throw new Error("pqRatchetStep: CERatchetKEMState - no KEM state for accepted params")
  const ss = sntrup761Dec(params.kemCt, rcKEM.rcPQRs.secretKey)
  return {ss, rcPQRr: params.kemPk}
}

// -- decryptHeader helper (lines 1151-1153)

function tryDecryptHeader(headerKey: Uint8Array, ad: Uint8Array, encHdr: EncMessageHeader): MsgHeader | null {
  try {
    const plainHeader = decryptAEAD(headerKey, encHdr.ehIV, ad, encHdr.ehBody, encHdr.ehAuthTag)
    return decodeMsgHeader(encHdr.ehVersion, plainHeader)
  } catch {
    return null
  }
}
