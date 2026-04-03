# Simplex.Messaging.Crypto.File

> Streaming encrypted file I/O using NaCl secret_box with tail auth tag.

**Source**: [`Crypto/File.hs`](../../../../../src/Simplex/Messaging/Crypto/File.hs)

## Overview

`CryptoFileHandle` wraps a file `Handle` with an optional `TVar SbState` for streaming encryption/decryption. When `cryptoArgs` is `Nothing`, the file is plaintext and all operations pass through directly.

## Auth tag position

The auth tag is written/read **at the end of the file** (tail tag pattern), not prepended. This is important for streaming: `hPut` encrypts chunks as they arrive, accumulating the Poly1305 state in the TVar, and `hPutTag` finalizes and writes the 16-byte tag only after all data is written.

## hGetTag

**Security**: Uses `BA.constEq` for constant-time tag comparison, preventing timing side-channels. Must be called after reading all content bytes — it reads exactly `authTagSize` (16) remaining bytes and compares against the finalized Poly1305 state. Caller must know the file size and read only the content portion before calling this.

## getFileContentsSize

Subtracts `authTagSize` from the file size when crypto args are present. This gives the content size without the tag, which is needed to know how many bytes to read before calling `hGetTag`.

## readFile / writeFile

Whole-file variants that read/write everything at once. `readFile` uses `sbDecryptChunk` (encrypt-then-MAC verification — feeds ciphertext to Poly1305), while `writeFile` uses `sbEncryptChunk`. Both use the tail tag layout via [Simplex.Messaging.Crypto.Lazy](./Lazy.md) functions.
