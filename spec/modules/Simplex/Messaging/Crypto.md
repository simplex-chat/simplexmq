# Simplex.Messaging.Crypto

> Core cryptographic primitives: key types, NaCl crypto_box/secret_box, AEAD-GCM, signing, padding, X509, HKDF.

**Source**: [`Crypto.hs`](../../../../src/Simplex/Messaging/Crypto.hs)

## Overview

This is the largest crypto module (~1540 lines). It defines the type-level algorithm system (GADTs + type families), all key types, and the fundamental encrypt/decrypt/sign/verify operations used throughout the protocol stack. Higher-level modules ([Ratchet](./Crypto/Ratchet.md), [Lazy](./Crypto/Lazy.md), [File](./Crypto/File.md)) build on these primitives.

## Algorithm type system

Four algorithms (`Ed25519`, `Ed448`, `X25519`, `X448`) are encoded as a promoted data kind `Algorithm`. Type families constrain which algorithms support which operations:

- `SignatureAlgorithm`: only `Ed25519`, `Ed448`
- `DhAlgorithm`: only `X25519`, `X448`
- `AuthAlgorithm`: `Ed25519`, `Ed448`, `X25519` (but NOT `X448`)

Using the wrong algorithm produces a **compile-time error** via `TypeError`. The runtime bridge uses `Dict` from `Data.Constraint` — functions like `signatureAlgorithm :: SAlgorithm a -> Maybe (Dict (SignatureAlgorithm a))` allow dynamic dispatch while preserving type safety.

## PrivateKeyEd25519 StrEncoding deliberately omitted

The `StrEncoding` instance for `PrivateKey Ed25519` is commented out with the note "Do not enable, to avoid leaking key data." Only `PrivateKey X25519` has `StrEncoding`, used specifically for the notification store log. This is a deliberate security decision — Ed25519 signing keys should never appear in human-readable formats.

## Two AEAD initialization paths

- **`initAEAD`**: Takes 16-byte `IV`, transforms it internally via `cryptonite_aes_gcm_init`. Used by the double ratchet.
- **`initAEADGCM`**: Takes 12-byte `GCMIV`, does NOT transform. Used for WebRTC frame encryption.

These are **not interchangeable** — using the wrong IV size or init function produces silent corruption. The code comments note that WebCrypto compatibility requires `initAEADGCM`, and the ratchet may need to migrate away from `initAEAD` in the future.

## cbNonce — silent truncation/padding

`cbNonce` adjusts any ByteString to exactly 24 bytes:
- If longer: silently truncates to first 24 bytes
- If shorter: silently pads with zero bytes

No error is raised for incorrect input lengths. This means a programming error passing the wrong-length nonce will produce valid but wrong encryption, not a failure.

## pad / unPad — 2-byte length prefix

`pad` prepends a 2-byte big-endian `Word16` length, then the message, then `'#'` padding characters to fill `paddedLen`. Maximum message length is `2^16 - 3 = 65533` bytes. The `'#'` padding character is a convention, not verified on decode — `unPad` only reads the length prefix and extracts that many bytes.

Contrast with [Simplex.Messaging.Crypto.Lazy.pad](./Crypto/Lazy.md#padding-8-byte-length-prefix) which uses an 8-byte `Int64` prefix for file-sized data.

## crypto_box / secret_box

Both use the same underlying `xSalsa20` + `Poly1305.auth` implementation. The difference is only in the key:
- **crypto_box** (`cbEncrypt`/`cbDecrypt`): uses a DH shared secret (`DhSecret X25519`)
- **secret_box** (`sbEncrypt`/`sbDecrypt`): uses a symmetric key (`SbKey`, 32 bytes)

Both apply `pad`/`unPad` by default. The `NoPad` variants skip padding.

## xSalsa20

The XSalsa20 implementation splits the 24-byte nonce into two 8-byte halves. The first half initializes the cipher state (prepended with 16 zero bytes), the second derives a subkey. The first 32 bytes of output become the Poly1305 one-time key (`rs`), then the rest encrypts the message. This is the standard NaCl construction.

## Secret box chains (sbcInit / sbcHkdf)

HKDF-based key chains for deriving sequential key+nonce pairs:
- `sbcInit`: derives two 32-byte chain keys from a salt and shared secret using `HKDF(salt, secret, "SimpleXSbChainInit", 64)`
- `sbcHkdf`: advances a chain key, producing a new chain key (32 bytes), an SbKey (32 bytes), and a CbNonce (24 bytes) from `HKDF("", chainKey, "SimpleXSbChain", 88)`

## Key encoding

All keys are encoded as ASN.1 DER (X.509 SubjectPublicKeyInfo for public, PKCS#8 for private). The algorithm is determined by the encoded key length on decode — `decodePubKey` / `decodePrivKey` parse the ASN.1 structure, then dispatch on the X.509 key type.

## Signature algorithm detection

`decodeSignature` determines the algorithm by signature length: Ed25519 signatures are 64 bytes, Ed448 signatures are 114 bytes. Any other size is rejected.

## GCMIV constructor not exported

`GCMIV` constructor is not exported — only `gcmIV :: ByteString -> Either CryptoError GCMIV` is available, which validates that the input is exactly 12 bytes. This prevents construction of invalid IVs.

## verify silently returns False on algorithm mismatch

`verify :: APublicVerifyKey -> ASignature -> ByteString -> Bool` uses `testEquality` on the algorithm singletons. If the key is Ed25519 but the signature is Ed448 (or vice versa), `testEquality` fails and `verify` returns `False` — no error, no indication of a type mismatch. A correctly-formed signature can "fail" simply because the wrong algorithm key was passed.

## dh' returns raw DH output — no key derivation

`dh'` returns the raw X25519/X448 shared point with no hashing or HKDF. Callers must apply their own KDF: [SNTRUP761](./Crypto/SNTRUP761.md) hashes with SHA3-256, the [ratchet](./Crypto/Ratchet.md#kdf-functions) uses HKDF-SHA512. Not all DH libraries behave this way — some hash the output automatically.

## reverseNonce

`reverseNonce` creates a "reply" nonce by byte-reversing the original 24-byte nonce. Used for bidirectional communication where both sides need distinct nonces derived from the same starting value. The two nonces are guaranteed distinct unless the original is a byte palindrome, which is astronomically unlikely for random 24-byte values.

## CbAuthenticator

An authentication scheme that encrypts the SHA-512 hash of the message using crypto_box, rather than the message itself. The result is 80 bytes (64 hash + 16 auth tag). This is the djb-recommended authenticator scheme: it proves knowledge of the shared secret and the message content, without requiring the message to fit in a single crypto_box, and without revealing message content even to someone who compromises the shared key after verification.

## generateKeyPair is STM

Key generation uses `TVar ChaChaDRG` and runs in `STM`, not `IO`. This allows key generation inside `atomically` blocks, which is used extensively in handshake and ratchet initialization code.
