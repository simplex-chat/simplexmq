# Simplex.Messaging.Encoding.String

> Human-readable, URI-friendly string encoding for SMP and agent protocols.

**Source**: [`Encoding/String.hs`](../../../../../src/Simplex/Messaging/Encoding/String.hs)

## Overview

`StrEncoding` is the human-readable counterpart to [Simplex.Messaging.Encoding](../Encoding.md)'s binary `Encoding`. Key differences:

| Aspect | `Encoding` (binary) | `StrEncoding` (string) |
|--------|---------------------|------------------------|
| ByteString | 1-byte length prefix, raw bytes | base64url encoded |
| Tuple separator | none (self-delimiting) | space-delimited |
| List separator | 1-byte count prefix | comma-separated |
| Default parser fallback | `smpP` via `parseAll` | `strP` via `base64urlP` |

## ByteString instance

Encodes as base64url. The parser (`strP`) only accepts non-empty strings — empty base64url input fails.

## String instance

Inherits from ByteString via `B.pack` / `B.unpack`. Only Char8 (Latin-1) characters round-trip.

## strToJSON / strParseJSON

`strToJSON` uses `decodeLatin1`, not `decodeUtf8'`. This preserves arbitrary byte sequences (e.g., base64url-encoded binary data) as JSON strings without UTF-8 validation errors, but means the JSON representation is Latin-1, not UTF-8.

## Class default: strP assumes base64url for all types

The `MINIMAL` pragma allows defining only `strDecode` without `strP`. But the default `strP = strDecode <$?> base64urlP` then assumes input is base64url-encoded — for *any* type, not just ByteString. Two consequences:

1. The type's `strDecode` receives raw decoded bytes, not the base64url text. Easy to confuse when implementing a new instance.
2. `base64urlP` requires non-empty input (`takeWhile1`), so the default `strP` cannot parse empty values — even if `strDecode ""` would succeed. Types that can encode to empty output must define `strP` explicitly.

## listItem

Items are delimited by `,`, ` `, or `\n`. List items cannot contain these characters in their `strEncode` output. No escaping mechanism exists.

## Str newtype

Plain text (no base64). Delimited by spaces. `strP` consumes the trailing space — this is unusual and means `Str` parsing has a side effect on the input position that other `StrEncoding` parsers don't.
