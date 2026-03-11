# Simplex.Messaging.Crypto.Lazy

> Streaming NaCl secret_box (XSalsa20 + Poly1305) for lazy ByteStrings.

**Source**: [`Crypto/Lazy.hs`](../../../../../src/Simplex/Messaging/Crypto/Lazy.hs)

## Overview

Lazy counterpart to the strict NaCl operations in [Simplex.Messaging.Crypto](../Crypto.md). Processes data chunk-by-chunk via `SbState = (XSalsa.State, Poly1305.State)`, enabling streaming encryption of large files without loading everything into memory.

## Encrypt-then-MAC asymmetry

`sbEncryptChunk` and `sbDecryptChunk` both use XSalsa20 for the cipher operation, but feed different data to Poly1305:

- **Encrypt**: feeds the **ciphertext** to Poly1305 (`Poly1305.update authSt c`)
- **Decrypt**: feeds the **original ciphertext** (the input chunk) to Poly1305 (`Poly1305.update authSt chunk`), not the decrypted plaintext

This is the correct encrypt-then-MAC pattern: the MAC is always computed over ciphertext, so both sides compute the same tag.

## Padding: 8-byte length prefix

`pad` uses an 8-byte `Int64` length prefix (via `smpEncode`), unlike [Simplex.Messaging.Crypto.pad](../Crypto.md#pad) which uses a 2-byte `Word16` prefix. This is because lazy operations handle file-sized data that can exceed 65535 bytes.

`unPad` / `splitLen` does not validate that the remaining data is at least `len` bytes — it uses `LB.take len` which silently returns a shorter result. The comment notes this is intentional to avoid consuming all chunks for validation.

## Auth tag placement: prepend vs tail

Two families of functions:
- **`sbEncrypt` / `sbDecrypt`**: tag is **prepended** (first 16 bytes of output). Used for message-sized data.
- **`sbEncryptTailTag` / `sbDecryptTailTag`**: tag is **appended** (last 16 bytes). More efficient for large files because you don't need to buffer the tag before the content.

The tail-tag variants also support `KEMHybridSecret` via `kcbEncryptTailTag` / `kcbDecryptTailTag`.

## sbDecryptTailTag validity

`sbDecryptTailTag` returns `(Bool, LazyByteString)` — the `Bool` indicates whether the auth tag was valid, but the decrypted data is returned regardless. This allows the caller to decide how to handle invalid tags (e.g., [Simplex.Messaging.Crypto.File](./File.md) uses strict `unless` checks).

## fastReplicate

Optimizes large padding by building the lazy ByteString from 64KB chunks (minus GHC overhead for `Int` size) rather than one enormous strict ByteString. This avoids allocating a single contiguous buffer for multi-megabyte padding.
