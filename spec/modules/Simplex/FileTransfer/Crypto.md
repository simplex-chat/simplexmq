# Simplex.FileTransfer.Crypto

> File encryption and decryption with streaming, padding, and auth tag verification.

**Source**: [`FileTransfer/Crypto.hs`](../../../../src/Simplex/FileTransfer/Crypto.hs)

## Non-obvious behavior

### 1. Embedded file header in encrypted stream

`encryptFile` prepends the `FileHeader` (containing filename and optional `fileExtra`) to the plaintext before encryption. A total data size field (8 bytes, `fileSizeLen`) is prepended before the header, encoding the combined size of header + file content. The decryptor uses this to distinguish real data from padding. The recipient must parse the header after decryption to recover the original filename — the header is not transmitted separately.

### 2. Fixed-size padding hides actual file size

The encrypted output is padded to `encSize` (the sum of chunk sizes). Since chunk sizes are fixed powers of 2 (64KB, 256KB, 1MB, 4MB), the encrypted file size reveals only which chunk size bucket the file falls into, not the actual size. The encryption streams data with `LC.sbEncryptChunk` in a loop, pads the remaining space, then manually appends the auth tag via `LC.sbAuth`. This manual streaming approach (rather than using the all-at-once `LC.sbEncryptTailTag`) is necessary because encryption is interleaved with file I/O.

### 3. Dual decrypt paths: single-chunk vs multi-chunk

`decryptChunks` takes different paths based on chunk count:
- **Single chunk**: reads the entire file into memory via `LB.readFile`, decrypts in-memory with `LC.sbDecryptTailTag`
- **Multiple chunks**: opens the destination file for writing and streams through each chunk file with `LC.sbDecryptChunkLazy` (lazy bytestring variant), verifying the auth tag from the final chunk

The single-chunk path avoids file handle management overhead for small files.

### 4. Auth tag failure deletes output file

In the multi-chunk streaming path, if `BA.constEq` detects an auth tag mismatch after decrypting all chunks, the partially-written output file is deleted before returning `FTCEInvalidAuthTag`. This prevents consumers from using a file whose integrity is unverified.

### 5. Streaming encryption uses 64KB blocks

`encryptFile` reads plaintext in 65536-byte blocks (`LC.sbEncryptChunk`), regardless of the XFTP chunk size. These are encryption blocks within a single continuous stream — not to be confused with XFTP protocol chunks which are much larger (64KB–4MB).
