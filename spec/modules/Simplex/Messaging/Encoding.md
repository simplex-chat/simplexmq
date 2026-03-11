# Simplex.Messaging.Encoding

> Binary wire-format encoding for SMP protocol transmission.

**Source**: [`Encoding.hs`](../../../../src/Simplex/Messaging/Encoding.hs)

## Overview

`Encoding` is the binary wire format — fixed-size or length-prefixed, no delimiters between fields. Contrast with [Simplex.Messaging.Encoding.String](./Encoding/String.md) which is the human-readable, space-delimited, base64url format used in URIs and logs.

The two encoding classes share some instances (`Char`, `Bool`, `SystemTime`) but differ fundamentally: `Encoding` is self-delimiting via length prefixes, `StrEncoding` is delimiter-based (spaces, commas).

## ByteString instance

**Length prefix is 1 byte.** Maximum encodable length is 255 bytes. If a ByteString exceeds 255 bytes, the length silently wraps via `w2c . fromIntegral` — a 300-byte string encodes length as 44 (300 mod 256). Callers must ensure ByteStrings fit in 255 bytes, or use `Large` for longer values.

**Security**: silent truncation means a caller encoding untrusted input without length validation could produce a malformed message where the decoder reads fewer bytes than were intended, then misparses the remainder as the next field.

## Large

2-byte length prefix (`Word16`). Use for ByteStrings that may exceed 255 bytes. Maximum 65535 bytes.

## Maybe instance

Tags are ASCII characters `'0'` (0x30) and `'1'` (0x31), not bytes 0x00/0x01. `Nothing` encodes as the single byte 0x30; `Just x` encodes as 0x31 followed by `smpEncode x`.

## Tail

Consumes all remaining input. Must be the last field in any composite encoding — placing it elsewhere silently eats subsequent fields.

## Tuple instances

Sequential concatenation with no separators. Works because each element's encoding is self-delimiting (length-prefixed ByteString, fixed-size Word16/Word32/Int64/Char, etc.). If an element type isn't self-delimiting, the tuple won't round-trip.

## SystemTime

Only seconds are encoded (as Int64); nanoseconds are discarded on encode and set to 0 on decode.

## smpEncodeList / smpListP

1-byte length prefix for lists — same 255-item limit as ByteString's 255-byte limit.
