// Short link key derivation.
// Mirrors: Simplex.Messaging.Crypto.ShortLink

import {hkdf} from "@noble/hashes/hkdf"
import {sha512} from "@noble/hashes/sha512"

// contactShortLinkKdf (Agent/Protocol.hs:47-50)
// hkdf("", linkKey, "SimpleXContactLink", 56) -> (linkId[24], sbKey[32])
export function contactShortLinkKdf(linkKey: Uint8Array): {linkId: Uint8Array; sbKey: Uint8Array} {
  const derived = hkdf(sha512, linkKey, new Uint8Array(0), "SimpleXContactLink", 56)
  return {
    linkId: derived.slice(0, 24),
    sbKey: derived.slice(24, 56),
  }
}

// invShortLinkKdf (Agent/Protocol.hs:52-53)
// hkdf("", linkKey, "SimpleXInvLink", 32) -> sbKey[32]
export function invShortLinkKdf(linkKey: Uint8Array): Uint8Array {
  return hkdf(sha512, linkKey, new Uint8Array(0), "SimpleXInvLink", 32)
}
