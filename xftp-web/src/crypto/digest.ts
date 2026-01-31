// Cryptographic hash functions matching Simplex.Messaging.Crypto (sha256Hash, sha512Hash).

import sodium from "libsodium-wrappers-sumo"

// SHA-256 digest (32 bytes) — Crypto.hs:1006
export function sha256(data: Uint8Array): Uint8Array {
  return sodium.crypto_hash_sha256(data)
}

// SHA-512 digest (64 bytes) — Crypto.hs:1011
export function sha512(data: Uint8Array): Uint8Array {
  return sodium.crypto_hash_sha512(data)
}
