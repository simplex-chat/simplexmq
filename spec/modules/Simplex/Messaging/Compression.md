# Simplex.Messaging.Compression

> Zstd compression with passthrough for short messages.

**Source**: [`Compression.hs`](../../../../src/Simplex/Messaging/Compression.hs)

## compress1

Messages <= 180 bytes are wrapped as `Passthrough` (no compression). The threshold is empirically derived from real client data — messages above 180 bytes rapidly gain compression ratio.

## decompress1

**Security**: decompression bomb protection. Requires `decompressedSize` to be present in the zstd frame header AND within the caller-specified `limit`. If the compressed data doesn't declare its decompressed size (non-standard zstd frames), decompression is refused entirely. This prevents memory exhaustion from malicious compressed payloads.

## Wire format

Tag byte `'0'` (0x30) = passthrough (1-byte length prefix, raw data). Tag byte `'1'` (0x31) = compressed (2-byte `Large` length prefix, zstd data). The passthrough path uses the standard `ByteString` encoding (255-byte limit); the compressed path uses `Large` (65535-byte limit).
