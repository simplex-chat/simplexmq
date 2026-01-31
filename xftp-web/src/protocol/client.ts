// XFTP client protocol operations — Simplex.FileTransfer.Client + Crypto
//
// CbAuthenticator-based command authentication and transport-level
// chunk encryption/decryption for XFTP downloads.

import {concatBytes} from "./encoding.js"
import {dh} from "../crypto/keys.js"
import {sha512} from "../crypto/digest.js"
import {
  cbInit, sbEncryptChunk, sbDecryptChunk, sbAuth, cryptoBox
} from "../crypto/secretbox.js"

// ── Constants ───────────────────────────────────────────────────

export const cbAuthenticatorSize = 80 // SHA512 (64) + authTag (16)

// ── CbAuthenticator (Crypto.hs:cbAuthenticate) ─────────────────

// Create crypto_box authenticator for a message.
// Encrypts sha512(msg) with NaCl crypto_box using DH(peerPubKey, ownPrivKey).
// Returns 80 bytes (16-byte tag prepended + 64-byte encrypted hash).
export function cbAuthenticate(
  peerPubKey: Uint8Array,
  ownPrivKey: Uint8Array,
  nonce: Uint8Array,
  msg: Uint8Array
): Uint8Array {
  const dhSecret = dh(peerPubKey, ownPrivKey)
  const hash = sha512(msg)
  return cryptoBox(dhSecret, nonce, hash)
}

// Verify crypto_box authenticator for a message.
// Decrypts authenticator with DH(peerPubKey, ownPrivKey), checks against sha512(msg).
export function cbVerify(
  peerPubKey: Uint8Array,
  ownPrivKey: Uint8Array,
  nonce: Uint8Array,
  authenticator: Uint8Array,
  msg: Uint8Array
): boolean {
  if (authenticator.length !== cbAuthenticatorSize) return false
  const dhSecret = dh(peerPubKey, ownPrivKey)
  const tag = authenticator.subarray(0, 16)
  const cipher = authenticator.subarray(16)
  const state = cbInit(dhSecret, nonce)
  const plaintext = sbDecryptChunk(state, cipher)
  const computedTag = sbAuth(state)
  if (!constantTimeEqual(tag, computedTag)) return false
  const expectedHash = sha512(msg)
  return constantTimeEqual(plaintext, expectedHash)
}

// ── Transport-level chunk encryption/decryption ─────────────────

// Encrypt a chunk for transport (tag-appended format).
// Matches sendEncFile in FileTransfer.Transport:
//   ciphertext streamed via sbEncryptChunk, then 16-byte auth tag appended.
export function encryptTransportChunk(
  dhSecret: Uint8Array,
  cbNonce: Uint8Array,
  plainData: Uint8Array
): Uint8Array {
  const state = cbInit(dhSecret, cbNonce)
  const cipher = sbEncryptChunk(state, plainData)
  const tag = sbAuth(state)
  return concatBytes(cipher, tag)
}

// Decrypt a transport-encrypted chunk (tag-appended format).
// Matches receiveEncFile / receiveSbFile in FileTransfer.Transport:
//   ciphertext decrypted via sbDecryptChunk, then 16-byte auth tag verified.
export function decryptTransportChunk(
  dhSecret: Uint8Array,
  cbNonce: Uint8Array,
  encData: Uint8Array
): {valid: boolean, content: Uint8Array} {
  if (encData.length < 16) return {valid: false, content: new Uint8Array(0)}
  const cipher = encData.subarray(0, encData.length - 16)
  const providedTag = encData.subarray(encData.length - 16)
  const state = cbInit(dhSecret, cbNonce)
  const plaintext = sbDecryptChunk(state, cipher)
  const computedTag = sbAuth(state)
  const valid = constantTimeEqual(providedTag, computedTag)
  return {valid, content: plaintext}
}

// ── Internal ────────────────────────────────────────────────────

function constantTimeEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false
  let diff = 0
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i]
  return diff === 0
}
