// Double ratchet with X3DH key agreement.
// Mirrors: Simplex.Messaging.Crypto.Ratchet

import {x448} from "@noble/curves/ed448.js"
import {hkdf, encryptAEAD, decryptAEAD} from "../crypto.js"
import {concatBytes} from "@simplex-chat/xftp-web/dist/protocol/encoding.js"

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
