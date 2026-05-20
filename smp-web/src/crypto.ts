// Crypto primitives.
// Mirrors: Simplex.Messaging.Crypto

import {hkdf as nobleHkdf} from "@noble/hashes/hkdf"
import {sha512} from "@noble/hashes/sha512"
import {gcm} from "@noble/ciphers/aes.js"
import {cbEncrypt, cbDecrypt} from "@simplex-chat/xftp-web/dist/crypto/secretbox.js"
import {concatBytes} from "@simplex-chat/xftp-web/dist/protocol/encoding.js"
import {pad, unPad} from "@simplex-chat/xftp-web/dist/crypto/padding.js"

// C.hkdf (Crypto.hs:1461-1464)
// HKDF-SHA512 extract + expand
export function hkdf(salt: Uint8Array, ikm: Uint8Array, info: string, n: number): Uint8Array {
  return nobleHkdf(sha512, ikm, salt, info, n)
}

// -- SbChainKey block encryption (Crypto.hs:1449-1464)

export interface SbKeyNonce {
  sbKey: Uint8Array   // 32 bytes
  nonce: Uint8Array   // 24 bytes
}

// sbcInit (Crypto.hs:1452-1455)
// hkdf(sessionId, dhSecret, "SimpleXSbChainInit", 64) -> (sndChainKey, rcvChainKey)
export function sbcInit(sessionId: Uint8Array, dhSecret: Uint8Array): {sndKey: Uint8Array; rcvKey: Uint8Array} {
  const derived = hkdf(sessionId, dhSecret, "SimpleXSbChainInit", 64)
  return {sndKey: derived.slice(0, 32), rcvKey: derived.slice(32, 64)}
}

// sbcHkdf (Crypto.hs:1459-1464)
// hkdf("", chainKey, "SimpleXSbChain", 88) -> ((sbKey, nonce), nextChainKey)
export function sbcHkdf(chainKey: Uint8Array): {keyNonce: SbKeyNonce; nextChainKey: Uint8Array} {
  const out = hkdf(new Uint8Array(0), chainKey, "SimpleXSbChain", 88)
  return {
    keyNonce: {sbKey: out.slice(32, 64), nonce: out.slice(64, 88)},
    nextChainKey: out.slice(0, 32),
  }
}

// sbEncrypt (Crypto.hs:1296-1301)
// pad + cryptoBox (tag prepended to ciphertext)
export function sbEncryptBlock(chainKey: Uint8Array, block: Uint8Array, paddedLen: number): {encrypted: Uint8Array; nextChainKey: Uint8Array} {
  const {keyNonce: {sbKey, nonce}, nextChainKey} = sbcHkdf(chainKey)
  return {encrypted: cbEncrypt(sbKey, nonce, block, paddedLen), nextChainKey}
}

// sbDecrypt (Crypto.hs:1330-1336)
// cryptoBoxOpen + unpad
export function sbDecryptBlock(chainKey: Uint8Array, block: Uint8Array): {decrypted: Uint8Array; nextChainKey: Uint8Array} {
  const {keyNonce: {sbKey, nonce}, nextChainKey} = sbcHkdf(chainKey)
  return {decrypted: cbDecrypt(sbKey, nonce, block), nextChainKey}
}

// -- AES-256-GCM authenticated encryption (Crypto.hs:1035-1061)
// Uses 16-byte IVs (GCM with GHASH path per NIST SP 800-38D for IVs != 96 bits)

export const AUTH_TAG_SIZE = 16

// encryptAEAD (Crypto.hs:1035-1039)
export function encryptAEAD(
  key: Uint8Array,     // 32 bytes
  iv: Uint8Array,      // 16 bytes
  paddedLen: number,
  ad: Uint8Array,
  plaintext: Uint8Array,
): {authTag: Uint8Array; ciphertext: Uint8Array} {
  const padded = pad(plaintext, paddedLen)
  const cipher = gcm(key, iv, ad)
  const encrypted = cipher.encrypt(padded)
  return {
    ciphertext: encrypted.subarray(0, encrypted.length - AUTH_TAG_SIZE),
    authTag: encrypted.subarray(encrypted.length - AUTH_TAG_SIZE),
  }
}

// decryptAEAD (Crypto.hs:1058-1061)
export function decryptAEAD(
  key: Uint8Array,
  iv: Uint8Array,
  ad: Uint8Array,
  ciphertext: Uint8Array,
  authTag: Uint8Array,
): Uint8Array {
  const cipher = gcm(key, iv, ad)
  const encrypted = concatBytes(ciphertext, authTag)
  const padded = cipher.decrypt(encrypted)
  return unPad(padded)
}
