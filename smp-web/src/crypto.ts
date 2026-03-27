// Crypto primitives.
// Mirrors: Simplex.Messaging.Crypto

import {hkdf as nobleHkdf} from "@noble/hashes/hkdf"
import {sha512} from "@noble/hashes/sha512"

// C.hkdf (Crypto.hs:1461-1464)
// HKDF-SHA512 extract + expand
export function hkdf(salt: Uint8Array, ikm: Uint8Array, info: string, n: number): Uint8Array {
  return nobleHkdf(sha512, ikm, salt, info, n)
}
