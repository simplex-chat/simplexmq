# Simplex.Messaging.Parsers

> Attoparsec helpers and Aeson JSON encoding options.

**Source**: [`Parsers.hs`](../../../../src/Simplex/Messaging/Parsers.hs)

## sumTypeJSON (platform-dependent JSON encoding)

On Darwin with the `swiftJSON` CPP flag, `sumTypeJSON` uses `ObjectWithSingleField` encoding with tag `"_owsf"`. On all other platforms, it uses `TaggedObject` encoding with `"type"` / `"data"` keys.

This means the same Haskell type produces **different JSON** on macOS/iOS vs Linux. Cross-platform JSON interchange must use `taggedObjectJSON` or `singleFieldJSON` directly, not `sumTypeJSON`.

The `_owsf` tag enables Swift clients to convert between the two encodings — it's a marker that the value was encoded as ObjectWithSingleField rather than TaggedObject.

## parseE vs parseE'

`parseE` requires full input consumption (`endOfInput`). `parseE'` does not — it succeeds if the parser matches a prefix. Using `parseE'` where `parseE` is needed silently ignores trailing input.

## base64P

Parses standard base64 (`+` and `/`), not base64url (`-` and `_`). Contrast with `base64urlP` in [Simplex.Messaging.Encoding.String](./Encoding/String.md) which parses URL-safe base64.
