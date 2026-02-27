// Cryptographic hash functions matching Simplex.Messaging.Crypto (sha256Hash, sha512Hash).

import sodium from "libsodium-wrappers-sumo"

// SHA-256 digest (32 bytes) -- Crypto.hs:1006
export function sha256(data: Uint8Array): Uint8Array {
  return sodium.crypto_hash_sha256(data)
}

// SHA-512 digest (64 bytes) -- Crypto.hs:1011
export function sha512(data: Uint8Array): Uint8Array {
  return sodium.crypto_hash_sha512(data)
}

// Streaming SHA-512 over multiple chunks -- avoids copying large data into WASM memory at once.
// Internally segments chunks larger than 4MB to limit peak WASM memory usage.
export function sha512Streaming(chunks: Iterable<Uint8Array>): Uint8Array {
  const SEG = 4 * 1024 * 1024
  const state = sodium.crypto_hash_sha512_init() as unknown as sodium.StateAddress
  for (const chunk of chunks) {
    for (let off = 0; off < chunk.length; off += SEG) {
      sodium.crypto_hash_sha512_update(state, chunk.subarray(off, Math.min(off + SEG, chunk.length)))
    }
  }
  return sodium.crypto_hash_sha512_final(state)
}
