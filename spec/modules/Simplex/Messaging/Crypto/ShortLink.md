# Simplex.Messaging.Crypto.ShortLink

> Short link key derivation, encryption, and signature verification for contact/invitation links.

**Source**: [`Crypto/ShortLink.hs`](../../../../../src/Simplex/Messaging/Crypto/ShortLink.hs)

## Overview

Short links encode connection data in two encrypted blobs: fixed data (2048 bytes padded) and user data (13824 bytes padded). Both are encrypted with `sbEncrypt` using a key derived from the link key via HKDF.

## KDF schemes

Two distinct HKDF derivations with different info strings:

- **contactShortLinkKdf**: `HKDF("", linkKey, "SimpleXContactLink", 56)` → splits into 24-byte LinkId + 32-byte SbKey. The LinkId is used as the server-side identifier.
- **invShortLinkKdf**: `HKDF("", linkKey, "SimpleXInvLink", 32)` → 32-byte SbKey only. No LinkId because invitation links don't use server-side lookup.

## Fixed padding lengths

- `fixedDataPaddedLength = 2008` (2048 - 24 nonce - 16 auth tag)
- `userDataPaddedLength = 13784` (13824 - 24 - 16)

These are chosen so the encrypted output (with prepended nonce and appended auth tag) fits exactly in round sizes.

## decryptLinkData

**Security**: Performs three-layer verification in order:
1. Hash check: `SHA3_256(fixedData) == linkKey` — ensures data integrity
2. Root key signature: `verify(rootKey, sig1, fixedData)` — ensures authenticity
3. User data signature: `verify(rootKey, sig2, userData)` for invitations, or verify against any owner key for contact links

For contact links, also calls `validateLinkOwners` to verify the owner chain of trust (each owner is signed by the root key).

## encodeSign

Prepends the Ed25519 signature to the data: `smpEncode(sign(pk, data)) <> data`. This is the format expected by `decryptLinkData`'s parser.
