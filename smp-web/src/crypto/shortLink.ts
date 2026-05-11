// Short link key derivation and decryption.
// Mirrors: Simplex.Messaging.Crypto.ShortLink

import {hkdf} from "../crypto.js"
import {cbDecrypt} from "@simplex-chat/xftp-web/dist/crypto/secretbox.js"
import {Decoder, decodeBytes} from "@simplex-chat/xftp-web/dist/protocol/encoding.js"

const emptySalt = new Uint8Array(0)

// contactShortLinkKdf (Crypto/ShortLink.hs:47-50)
// hkdf("", linkKey, "SimpleXContactLink", 56) -> (linkId[24], sbKey[32])
export function contactShortLinkKdf(linkKey: Uint8Array): {linkId: Uint8Array; sbKey: Uint8Array} {
  const derived = hkdf(emptySalt, linkKey, "SimpleXContactLink", 56)
  return {
    linkId: derived.slice(0, 24),
    sbKey: derived.slice(24, 56),
  }
}

// invShortLinkKdf (Crypto/ShortLink.hs:52-53)
// hkdf("", linkKey, "SimpleXInvLink", 32) -> sbKey[32]
export function invShortLinkKdf(linkKey: Uint8Array): Uint8Array {
  return hkdf(emptySalt, linkKey, "SimpleXInvLink", 32)
}

// decryptLinkData (Crypto/ShortLink.hs:100-125)
// Decrypts both EncDataBytes blobs, strips signature prefix, returns raw data.
// Signature verification is skipped for spike.
export function decryptLinkData(
  sbKey: Uint8Array,
  encFixedData: Uint8Array,
  encUserData: Uint8Array
): {fixedData: Uint8Array; userData: Uint8Array} {
  return {
    fixedData: decryptSigned(sbKey, encFixedData),
    userData: decryptSigned(sbKey, encUserData),
  }
}

// EncDataBytes format: [nonce 24 bytes][ciphertext with prepended Poly1305 tag]
// After decrypt+unpad: [sig ByteString (1-byte len + 64 bytes)][data]
function decryptSigned(sbKey: Uint8Array, encData: Uint8Array): Uint8Array {
  const nonce = encData.subarray(0, 24)
  const ct = encData.subarray(24)
  const plaintext = cbDecrypt(sbKey, nonce, ct)
  // Skip signature: decodeBytes reads 1-byte length + that many bytes
  const d = new Decoder(plaintext)
  decodeBytes(d) // signature, discarded
  return d.takeAll()
}
