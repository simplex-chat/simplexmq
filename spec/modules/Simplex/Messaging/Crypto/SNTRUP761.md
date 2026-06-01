# Simplex.Messaging.Crypto.SNTRUP761

> Hybrid KEM+DH shared secret combining SNTRUP761 and X25519.

**Source**: [`Crypto/SNTRUP761.hs`](../../../../../src/Simplex/Messaging/Crypto/SNTRUP761.hs)

## kemHybridSecret

The hybrid secret is `SHA3_256(DHSecret || KEMSharedKey)` — not a simple concatenation, not HKDF. This follows the approach in draft-josefsson-ntruprime-hybrid. The result is a `ScrubbedBytes` value used as a symmetric key for NaCl crypto_box operations via `sbEncrypt_`/`sbDecrypt_`.

## kcbEncrypt / kcbDecrypt

These delegate directly to `sbEncrypt_` / `sbDecrypt_` from [Simplex.Messaging.Crypto](../Crypto.md), using the hybrid secret as the symmetric key. The hybrid secret is 32 bytes (SHA3-256 output), matching the expected key size for XSalsa20.
