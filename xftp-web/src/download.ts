// XFTP download pipeline -- integration of protocol + crypto layers.
//
// Ties together: DH key exchange (keys), transport decryption (client),
// file-level decryption (file), chunk sizing (chunks), digest verification.
//
// Usage:
//   1. Parse FileDescription from YAML (description.ts)
//   2. For each chunk replica:
//      a. generateX25519KeyPair() -> ephemeral DH keypair
//      b. encodeFGET(dhPub) -> FGET command
//      c. encodeAuthTransmission(...) -> padded block (send to server)
//      d. decodeTransmission(responseBlock) -> raw response
//      e. decodeResponse(raw) -> FRFile { rcvDhKey, nonce }
//      f. processFileResponse(rcvPrivKey, rcvDhKey, nonce) -> dhSecret
//      g. decryptReceivedChunk(dhSecret, nonce, encData, digest) -> plaintext
//   3. processDownloadedFile(fd, plaintextChunks) -> { header, content }

import {dh} from "./crypto/keys.js"
import {sha256} from "./crypto/digest.js"
import {decryptChunks, type FileHeader} from "./crypto/file.js"
import {decryptTransportChunk} from "./protocol/client.js"
import type {FileDescription} from "./protocol/description.js"

// -- Process FRFile response

// Derive transport decryption secret from FRFile response parameters.
// Uses DH(serverDhKey, recipientPrivKey) to produce shared secret.
export function processFileResponse(
  recipientPrivKey: Uint8Array,  // Ephemeral X25519 private key (32 bytes)
  serverDhKey: Uint8Array,       // rcvDhKey from FRFile response (32 bytes)
): Uint8Array {
  return dh(serverDhKey, recipientPrivKey)
}

// -- Decrypt a single received chunk

// Decrypt transport-encrypted chunk data and verify SHA-256 digest.
// Returns decrypted content or throws on auth tag / digest failure.
export function decryptReceivedChunk(
  dhSecret: Uint8Array,
  cbNonce: Uint8Array,
  encData: Uint8Array,
  expectedDigest: Uint8Array | null
): Uint8Array {
  const providedTag = encData.slice(encData.length - 16)
  const {valid, content} = decryptTransportChunk(dhSecret, cbNonce, encData)
  if (!valid) throw new Error("transport auth tag verification failed")
  if (expectedDigest !== null) {
    const actual = sha256(content)
    if (!digestEqual(actual, expectedDigest)) {
      throw new Error("chunk digest mismatch")
    }
  }
  return content
}

// -- Full download pipeline

// Process downloaded file: concatenate transport-decrypted chunks,
// then file-level decrypt using key/nonce from file description.
// Returns parsed FileHeader and file content.
export function processDownloadedFile(
  fd: FileDescription,
  plaintextChunks: Uint8Array[]
): {header: FileHeader, content: Uint8Array} {
  return decryptChunks(BigInt(fd.size), plaintextChunks, fd.key, fd.nonce)
}

// -- Internal

function digestEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false
  let diff = 0
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i]
  return diff === 0
}
