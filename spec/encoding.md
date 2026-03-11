# Encoding

> Binary and string encoding used across all SimpleX protocols.

**Source files**: [`Encoding.hs`](../src/Simplex/Messaging/Encoding.hs), [`Encoding/String.hs`](../src/Simplex/Messaging/Encoding/String.hs), [`Parsers.hs`](../src/Simplex/Messaging/Parsers.hs)

## Overview

Two encoding layers serve different purposes:

- **`Encoding`** — Binary wire format for SMP protocol transmissions. Compact, no delimiters between fields. Used in all on-the-wire protocol messages.
- **`StrEncoding`** — Human-readable string format for configuration, URIs, logs, and JSON serialization. Uses base64url for binary data, decimal for numbers, comma-separated lists, space-separated tuples.

Both are typeclasses with `MINIMAL` pragmas requiring `encode` + (`decode` | `parser`), with the missing one derived from the other.

## Binary Encoding (`Encoding` class)

**Source**: `Encoding.hs:38-52`

```haskell
class Encoding a where
  smpEncode :: a -> ByteString
  smpDecode :: ByteString -> Either String a  -- default: parseAll smpP
  smpP :: Parser a                            -- default: smpDecode <$?> smpP
```

### Length-prefix conventions

| Type | Prefix | Max size | Source |
|------|--------|----------|--------|
| `ByteString` | 1-byte length (Word8 as Char) | 255 bytes | `Encoding.hs:102-106` |
| `Large` (newtype) | 2-byte length (Word16 big-endian) | 65535 bytes | `Encoding.hs:135-143` |
| `Tail` (newtype) | None — consumes rest of input | Unlimited | `Encoding.hs:126-132` |
| Lists (`smpEncodeList`) | 1-byte count prefix, then concatenated items | 255 items | `Encoding.hs:155-159` |
| `NonEmpty` | Same as list (fails on count=0) | 255 items | `Encoding.hs:173-178` |

### Scalar types

| Type | Encoding | Bytes | Source |
|------|----------|-------|--------|
| `Char` | Raw byte | 1 | `Encoding.hs:54-58` |
| `Bool` | `'T'` / `'F'` (0x54 / 0x46) | 1 | `Encoding.hs:60-70` |
| `Word16` | Big-endian | 2 | `Encoding.hs:72-76` |
| `Word32` | Big-endian | 4 | `Encoding.hs:78-82` |
| `Int64` | Two big-endian Word32s (high then low) | 8 | `Encoding.hs:84-99` |
| `SystemTime` | `systemSeconds` as Int64 (nanoseconds dropped) | 8 | `Encoding.hs:145-149` |
| `Text` | UTF-8 then ByteString encoding (1-byte length prefix) | 1 + len | `Encoding.hs:161-165` |
| `String` | `B.pack` then ByteString encoding | 1 + len | `Encoding.hs:167-171` |

### `Maybe a`

**Source**: `Encoding.hs:116-124`

```
Nothing → '0' (0x30)
Just x  → '1' (0x31) ++ smpEncode x
```

Tags are ASCII characters `'0'`/`'1'`, not binary 0x00/0x01.

### Tuples

**Source**: `Encoding.hs:180-220`

Tuples (2 through 8) encode as simple concatenation — no length prefix, no separator. Fields are parsed sequentially using each component's `smpP`. This works because each component's parser knows how many bytes to consume (via its own length prefix or fixed size).

### Combinators

| Function | Signature | Purpose | Source |
|----------|-----------|---------|--------|
| `_smpP` | `Parser a` | Space-prefixed parser (`A.space *> smpP`) | `Encoding.hs:151-152` |
| `smpEncodeList` | `[a] -> ByteString` | 1-byte count + concatenated items | `Encoding.hs:155-156` |
| `smpListP` | `Parser [a]` | Parse count then that many items | `Encoding.hs:158-159` |
| `lenEncode` | `Int -> Char` | Int to single-byte length char | `Encoding.hs:108-110` |

## String Encoding (`StrEncoding` class)

**Source**: `Encoding/String.hs:56-67`

```haskell
class StrEncoding a where
  strEncode :: a -> ByteString
  strDecode :: ByteString -> Either String a  -- default: parseAll strP
  strP :: Parser a                            -- default: strDecode <$?> base64urlP
```

Key difference from `Encoding`: the default `strP` parses base64url input first, then applies `strDecode`. This means types that only implement `strDecode` will automatically accept base64url-encoded input.

### Instance conventions

| Type | Encoding | Source |
|------|----------|--------|
| `ByteString` | base64url (non-empty required) | `String.hs:70-76` |
| `Word16`, `Word32` | Decimal string | `String.hs:114-124` |
| `Int`, `Int64` | Signed decimal | `String.hs:138-148` |
| `Char`, `Bool` | Delegates to `Encoding` (`smpEncode`/`smpP`) | `String.hs:126-136` |
| `Maybe a` | Empty string = `Nothing`, otherwise `strEncode a` | `String.hs:108-112` |
| `Text` | UTF-8 bytes, parsed until space/newline | `String.hs:97-99` |
| `SystemTime` | `systemSeconds` as Int64 (decimal) | `String.hs:150-152` |
| `UTCTime` | ISO 8601 string | `String.hs:154-156` |
| `CertificateChain` | Comma-separated base64url blobs | `String.hs:158-162` |
| `Fingerprint` | base64url of fingerprint bytes | `String.hs:164-168` |

### Collection encoding

| Type | Separator | Source |
|------|-----------|--------|
| Lists (`strEncodeList`) | Comma `,` | `String.hs:171-175` |
| `NonEmpty` | Comma (fails on empty) | `String.hs:178-180` |
| `Set a` | Comma | `String.hs:182-184` |
| `IntSet` | Comma | `String.hs:186-188` |
| Tuples (2-6) | Space (` `) | `String.hs:193-221` |

### `Str` newtype

**Source**: `String.hs:84-89`

Raw string (not base64url-encoded). Parses until space, consumes trailing space. Used for string-valued protocol fields that should not be base64-encoded.

### `TextEncoding` class

**Source**: `String.hs:51-53`

```haskell
class TextEncoding a where
  textEncode :: a -> Text
  textDecode :: Text -> Maybe a
```

Separate from `StrEncoding` — operates on `Text` rather than `ByteString`. Used for types that need Text representation (e.g., enum display names).

### JSON bridge functions

| Function | Purpose | Source |
|----------|---------|--------|
| `strToJSON` | `StrEncoding a => a -> J.Value` via `decodeLatin1 . strEncode` | `String.hs:229-231` |
| `strToJEncoding` | Same, for Aeson encoding | `String.hs:233-235` |
| `strParseJSON` | `StrEncoding a => String -> J.Value -> JT.Parser a` — parse JSON string via `strP` | `String.hs:237-238` |
| `textToJSON` | `TextEncoding a => a -> J.Value` | `String.hs:240-242` |
| `textToEncoding` | Same, for Aeson encoding | `String.hs:244-246` |
| `textParseJSON` | `TextEncoding a => String -> J.Value -> JT.Parser a` | `String.hs:248-249` |

## Parsers

**Source**: [`Parsers.hs`](../src/Simplex/Messaging/Parsers.hs)

### Core parsing functions

| Function | Signature | Purpose | Source |
|----------|-----------|---------|--------|
| `parseAll` | `Parser a -> ByteString -> Either String a` | Parse consuming all input (fails if bytes remain) | `Parsers.hs:64-65` |
| `parse` | `Parser a -> e -> ByteString -> Either e a` | `parseAll` with custom error type (discards error string) | `Parsers.hs:61-62` |
| `parseE` | `(String -> e) -> Parser a -> ByteString -> ExceptT e IO a` | `parseAll` lifted into `ExceptT` | `Parsers.hs:67-68` |
| `parseE'` | `(String -> e) -> Parser a -> ByteString -> ExceptT e IO a` | Like `parseE` but allows trailing input | `Parsers.hs:70-71` |
| `parseRead1` | `Read a => Parser a` | Parse a word then `readMaybe` it | `Parsers.hs:76-77` |
| `parseString` | `(ByteString -> Either String a) -> String -> a` | Parse from `String` (errors with `error`) | `Parsers.hs:89-90` |

### `base64P`

**Source**: `Parsers.hs:44-53`

Standard base64 parser (not base64url — uses `+`/`/` alphabet). Takes alphanumeric + `+`/`/` characters, optional `=` padding, then decodes. Contrast with `base64urlP` in `Encoding/String.hs` which uses `-`/`_` alphabet.

### JSON options helpers

Platform-conditional JSON encoding for cross-platform compatibility (Haskell ↔ Swift).

| Function | Purpose | Source |
|----------|---------|--------|
| `enumJSON` | All-nullary constructors as strings, with tag modifier | `Parsers.hs:101-106` |
| `sumTypeJSON` | Platform-conditional: `taggedObjectJSON` on non-Darwin, `singleFieldJSON` on Darwin | `Parsers.hs:109-114` |
| `taggedObjectJSON` | `{"type": "Tag", "data": {...}}` format | `Parsers.hs:119-128` |
| `singleFieldJSON` | `{"Tag": value}` format | `Parsers.hs:137-149` |
| `defaultJSON` | Default options with `omitNothingFields = True` | `Parsers.hs:151-152` |

Pattern synonyms for JSON field names:
- `TaggedObjectJSONTag = "type"` (`Parsers.hs:131`)
- `TaggedObjectJSONData = "data"` (`Parsers.hs:134`)
- `SingleFieldJSONTag = "_owsf"` (`Parsers.hs:117`)

### String helpers

| Function | Purpose | Source |
|----------|---------|--------|
| `fstToLower` | Lowercase first character | `Parsers.hs:92-94` |
| `dropPrefix` | Remove prefix string, lowercase remainder | `Parsers.hs:96-99` |
| `textP` | Parse rest of input as UTF-8 `String` | `Parsers.hs:154-155` |

## Auxiliary Types and Utilities

### TMap

**Source**: [`TMap.hs`](../src/Simplex/Messaging/TMap.hs)

```haskell
type TMap k a = TVar (Map k a)
```

STM-based concurrent map. Wraps `Data.Map.Strict` in a `TVar`. All mutations use `modifyTVar'` (strict) to prevent thunk accumulation.

| Function | Notes | Source |
|----------|-------|--------|
| `emptyIO` | IO allocation (`newTVarIO`) | `TMap.hs:32-34` |
| `singleton` | STM allocation | `TMap.hs:36-38` |
| `clear` | Reset to empty | `TMap.hs:40-42` |
| `lookup` / `lookupIO` | STM / non-transactional IO read | `TMap.hs:48-54` |
| `member` / `memberIO` | STM / non-transactional IO membership | `TMap.hs:56-62` |
| `insert` / `insertM` | Insert value / insert from STM action | `TMap.hs:64-70` |
| `delete` | Remove key | `TMap.hs:72-74` |
| `lookupInsert` | Atomic lookup-then-insert (returns old value) | `TMap.hs:76-78` |
| `lookupDelete` | Atomic lookup-then-delete | `TMap.hs:80-82` |
| `adjust` / `update` / `alter` / `alterF` | Standard Map operations lifted to STM | `TMap.hs:84-100` |
| `union` | Merge `Map` into `TMap` | `TMap.hs:102-104` |

`lookupIO`/`memberIO` use `readTVarIO` — single-read outside STM transaction, useful when you need a snapshot without composing with other STM operations.

### SessionVar

**Source**: [`Session.hs`](../src/Simplex/Messaging/Session.hs)

Race-safe session management using TMVar + monotonic ID.

```haskell
data SessionVar a = SessionVar
  { sessionVar   :: TMVar a    -- result slot
  , sessionVarId :: Int        -- monotonic ID from TVar counter
  , sessionVarTs :: UTCTime    -- creation timestamp
  }
```

| Function | Purpose | Source |
|----------|---------|--------|
| `getSessVar` | Lookup or create session. Returns `Left new` or `Right existing` | `Session.hs:24-33` |
| `removeSessVar` | Delete session only if ID matches (prevents removing a replacement) | `Session.hs:35-39` |
| `tryReadSessVar` | Non-blocking read of session result | `Session.hs:41-42` |

The ID-match check in `removeSessVar` (`sessionVarId v == sessionVarId v'`) prevents a race where:
1. Thread A creates session #5, starts work
2. Thread B creates session #6 (replacing #5 in TMap)
3. Thread A finishes, tries to remove — ID mismatch, removal blocked

### ServiceScheme

**Source**: [`ServiceScheme.hs`](../src/Simplex/Messaging/ServiceScheme.hs)

```haskell
data ServiceScheme = SSSimplex | SSAppServer SrvLoc
data SrvLoc = SrvLoc HostName ServiceName
```

URI scheme for SimpleX service addresses. `SSSimplex` encodes as `"simplex:"`, `SSAppServer` as `"https://host:port"`.

`simplexChat :: ServiceScheme` is the constant `SSAppServer (SrvLoc "simplex.chat" "")` (`ServiceScheme.hs:38-39`).

### SystemTime

**Source**: [`SystemTime.hs`](../src/Simplex/Messaging/SystemTime.hs)

```haskell
newtype RoundedSystemTime (t :: Nat) = RoundedSystemTime { roundedSeconds :: Int64 }
type SystemDate = RoundedSystemTime 86400    -- day precision
type SystemSeconds = RoundedSystemTime 1     -- second precision
```

Phantom-typed time rounding. The `Nat` type parameter specifies rounding granularity in seconds.

| Function | Purpose | Source |
|----------|---------|--------|
| `getRoundedSystemTime` | Get current time rounded to `t` seconds | `SystemTime.hs:40-43` |
| `getSystemDate` | Alias for day-rounded time | `SystemTime.hs:45-47` |
| `getSystemSeconds` | Second-precision (no rounding needed, just drops nanoseconds) | `SystemTime.hs:49-51` |
| `roundedToUTCTime` | Convert back to `UTCTime` | `SystemTime.hs:53-55` |

`RoundedSystemTime` derives `FromField`/`ToField` for SQLite storage and `FromJSON`/`ToJSON` for API serialization.

### Util

**Source**: [`Util.hs`](../src/Simplex/Messaging/Util.hs)

Selected utilities used across the codebase:

**Monadic combinators**:

| Function | Signature | Purpose | Source |
|----------|-----------|---------|--------|
| `<$?>` | `MonadFail m => (a -> Either String b) -> m a -> m b` | Lift fallible function into parser | `Util.hs:119-121` |
| `$>>=` | `(Monad m, Monad f, Traversable f) => m (f a) -> (a -> m (f b)) -> m (f b)` | Monadic bind through nested monad | `Util.hs:165-167` |
| `ifM` / `whenM` / `unlessM` | Monadic conditionals | `Util.hs:147-157` |
| `anyM` | Short-circuit `any` for monadic predicates (strict) | `Util.hs:159-161` |

**Error handling**:

| Function | Purpose | Source |
|----------|---------|--------|
| `tryAllErrors` | Catch all exceptions (including async) into `ExceptT` | `Util.hs:273-275` |
| `catchAllErrors` | Same with handler | `Util.hs:281-283` |
| `tryAllOwnErrors` | Catch only "own" exceptions (re-throws async cancellation) | `Util.hs:322-324` |
| `catchAllOwnErrors` | Same with handler | `Util.hs:330-332` |
| `isOwnException` | `StackOverflow`, `HeapOverflow`, `AllocationLimitExceeded` | `Util.hs:297-304` |
| `isAsyncCancellation` | Any `SomeAsyncException` except own exceptions | `Util.hs:306-310` |
| `catchThrow` | Catch exceptions, wrap in Left | `Util.hs:289-291` |
| `allFinally` | `tryAllErrors` + `final` + `except` (like `finally` for ExceptT) | `Util.hs:293-295` |

The own-vs-async distinction is critical: `catchOwn`/`tryAllOwnErrors` never swallow async cancellation (`ThreadKilled`, `UserInterrupt`, etc.), only synchronous exceptions and resource exhaustion (`StackOverflow`, `HeapOverflow`, `AllocationLimitExceeded`).

**STM**:

| Function | Purpose | Source |
|----------|---------|--------|
| `tryWriteTBQueue` | Non-blocking bounded queue write, returns success | `Util.hs:256-261` |

**Database result helpers**:

| Function | Purpose | Source |
|----------|---------|--------|
| `firstRow` | Extract first row with transform, or Left error | `Util.hs:346-347` |
| `maybeFirstRow` | Extract first row as Maybe | `Util.hs:349-350` |
| `firstRow'` | Like `firstRow` but transform can also fail | `Util.hs:355-356` |

**Collection utilities**:

| Function | Purpose | Source |
|----------|---------|--------|
| `groupOn` | `groupBy` using equality on projected key | `Util.hs:358-359` |
| `groupAllOn` | `groupOn` after `sortOn` (groups non-adjacent elements) | `Util.hs:372-373` |
| `toChunks` | Split list into `NonEmpty` chunks of size n | `Util.hs:376-380` |
| `packZipWith` | Optimized ByteString zipWith (direct memory access) | `Util.hs:236-254` |

**Miscellaneous**:

| Function | Purpose | Source |
|----------|---------|--------|
| `safeDecodeUtf8` | Decode UTF-8 replacing errors with `'?'` | `Util.hs:382-386` |
| `bshow` / `tshow` | `show` to `ByteString` / `Text` | `Util.hs:123-129` |
| `threadDelay'` | `Int64` delay (handles overflow by looping) | `Util.hs:391-399` |
| `diffToMicroseconds` / `diffToMilliseconds` | `NominalDiffTime` conversion | `Util.hs:401-407` |
| `labelMyThread` | Label current thread for debugging | `Util.hs:409-410` |
| `encodeJSON` / `decodeJSON` | `ToJSON a => a -> Text` / `FromJSON a => Text -> Maybe a` | `Util.hs:415-421` |
| `traverseWithKey_` | `Map` traversal discarding results | `Util.hs:423-425` |

## Security notes

- **Length prefix overflow**: `ByteString` encoding uses 1-byte length — silently truncates strings > 255 bytes. Callers must ensure size bounds before encoding. `Large` extends to 65535 bytes via Word16 prefix.
- **`Tail` unbounded**: `Tail` consumes all remaining input with no size check. Only safe when total message size is already bounded (e.g., within a padded SMP block).
- **base64 vs base64url**: `Parsers.base64P` uses standard alphabet (`+`/`/`), while `String.base64urlP` uses URL-safe alphabet (`-`/`_`). Mixing them causes silent decode failures.
- **`safeDecodeUtf8`**: Replaces invalid UTF-8 with `'?'` rather than failing. Suitable for logging/display, not for security-critical string comparison.
