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

Inherits from ByteString via `B.pack` / `B.unpack`. Only Char8 (Latin-1) characters round-trip; `B.pack` truncates unicode codepoints above 255. The source comment warns about this.

## strToJSON / strParseJSON

`strToJSON` uses `decodeLatin1`, not `decodeUtf8'`. This preserves arbitrary byte sequences (e.g., base64url-encoded binary data) as JSON strings without UTF-8 validation errors, but means the JSON representation is Latin-1, not UTF-8.

## Default strP fallback

If only `strDecode` is defined (no custom `strP`), the default parser runs `base64urlP` first, then passes the decoded bytes to `strDecode`. This means the type's own `strDecode` receives raw bytes, not the base64url text. Easy to confuse when implementing a new instance.

## listItem

Items are delimited by `,`, ` `, or `\n`. List items cannot contain these characters in their `strEncode` output. No escaping mechanism exists.

## Str newtype

Plain text (no base64). Delimited by spaces. `strP` consumes the trailing space — this is unusual and means `Str` parsing has a side effect on the input position that other `StrEncoding` parsers don't.
