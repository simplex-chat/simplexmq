// Short link key derivation.
// Mirrors: Simplex.Messaging.Crypto.ShortLink

import {hkdf} from "../crypto.js"

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
