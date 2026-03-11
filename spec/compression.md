# Compression

> Zstd compression for SimpleX protocol messages.

**Source file**: [`Compression.hs`](../src/Simplex/Messaging/Compression.hs)

## Overview

Optional Zstd compression for SMP message bodies. Short messages bypass compression entirely to avoid overhead. The `Compressed` type carries a tag byte indicating whether the payload is compressed or passthrough, making it self-describing on the wire.

## Types

### `Compressed`

**Source**: `Compression.hs:17-22`

```haskell
data Compressed
  = Passthrough ByteString   -- short messages, left intact
  | Compressed Large          -- Zstd-compressed, 2-byte length prefix
```

Wire encoding (`Compression.hs:30-38`):

```
Passthrough → '0' ++ smpEncode ByteString  (1-byte tag + 1-byte length + data)
Compressed  → '1' ++ smpEncode Large       (1-byte tag + 2-byte length + data)
```

Tags are `'0'` (0x30) and `'1'` (0x31) — same ASCII convention as `Maybe` encoding.

`Passthrough` uses standard `ByteString` encoding (max 255 bytes, 1-byte length prefix). `Compressed` uses `Large` encoding (max 65535 bytes, 2-byte Word16 length prefix), since compressed output can exceed 255 bytes for larger inputs.

## Constants

| Constant | Value | Purpose | Source |
|----------|-------|---------|--------|
| `maxLengthPassthrough` | 180 | Messages at or below this length are not compressed | `Compression.hs:24-25` |
| `compressionLevel` | 3 | Zstd compression level | `Compression.hs:27-28` |

The 180-byte threshold was "sampled from real client data" — messages above this length show rapidly increasing compression ratio. Below 180 bytes, compression overhead (FFI call, dictionary-less Zstd startup) outweighs savings.

## Functions

### `compress1`

**Source**: `Compression.hs:40-43`

```haskell
compress1 :: ByteString -> Compressed
```

Compress a message body:
- If `B.length bs <= 180` → `Passthrough bs`
- Otherwise → `Compressed (Large (Z1.compress 3 bs))`

No context or dictionary — each message is independently compressed ("1" in `compress1` refers to single-shot compression).

### `decompress1`

**Source**: `Compression.hs:45-53`

```haskell
decompress1 :: Int -> Compressed -> Either String ByteString
```

Decompress with size limit:
- `Passthrough bs` → `Right bs` (no check needed — already bounded by encoding)
- `Compressed (Large bs)` → check `Z1.decompressedSize bs`:
  - If size is known and within `limit` → decompress
  - If size unknown or exceeds `limit` → `Left` error

The size limit check happens **before** decompression, using Zstd's frame header (which includes the decompressed size when the compressor wrote it). This prevents decompression bombs — an attacker cannot cause unbounded memory allocation by sending a small compressed payload that expands to gigabytes.

The `Z1.decompress` result is pattern-matched for three cases:
- `Z1.Error e` → `Left e`
- `Z1.Skip` → `Right mempty` (zero-length output)
- `Z1.Decompress bs'` → `Right bs'`

## Security notes

- **Decompression bomb protection**: `decompress1` requires an explicit size limit and checks `decompressedSize` before allocating. Callers must pass an appropriate limit (typically the SMP block size).
- **No dictionary/context**: Each message is independently compressed. No shared state between messages that could leak information across compression boundaries.
- **Passthrough for short messages**: Messages ≤ 180 bytes are never compressed, avoiding timing side channels from compression ratio differences on short, potentially-predictable messages.
