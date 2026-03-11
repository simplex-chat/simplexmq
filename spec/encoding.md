# Encoding

> Binary and string encoding used across all SimpleX protocols.

**Source files**: [`Encoding.hs`](../src/Simplex/Messaging/Encoding.hs), [`Encoding/String.hs`](../src/Simplex/Messaging/Encoding/String.hs), [`Parsers.hs`](../src/Simplex/Messaging/Parsers.hs)

## Overview

Two encoding layers serve different purposes:

- **`Encoding`** — Binary wire format for SMP protocol transmissions. Compact, no delimiters between fields. Used in all on-the-wire protocol messages.
- **`StrEncoding`** — Human-readable string format for configuration, URIs, logs, and JSON serialization. Uses base64url for binary data, decimal for numbers, comma-separated lists, space-separated tuples.

Both are typeclasses with `MINIMAL` pragmas requiring `encode` + (`decode` | `parser`), with the missing one derived from the other.

## Binary Encoding (`Encoding` class)

```haskell
class Encoding a where
  smpEncode :: a -> ByteString
  smpDecode :: ByteString -> Either String a  -- default: parseAll smpP
  smpP :: Parser a                            -- default: smpDecode <$?> smpP
```

### Length-prefix conventions

| Type | Prefix | Max size |
|------|--------|----------|
| `ByteString` | 1-byte length (Word8 as Char) | 255 bytes |
| `Large` (newtype) | 2-byte length (Word16 big-endian) | 65535 bytes |
| `Tail` (newtype) | None — consumes rest of input | Unlimited |
| Lists (`smpEncodeList`) | 1-byte count prefix, then concatenated items | 255 items |
| `NonEmpty` | Same as list (fails on count=0) | 255 items |

### Scalar types

| Type | Encoding | Bytes |
|------|----------|-------|
| `Char` | Raw byte | 1 |
| `Bool` | `'T'` / `'F'` (0x54 / 0x46) | 1 |
| `Word16` | Big-endian | 2 |
| `Word32` | Big-endian | 4 |
| `Int64` | Two big-endian Word32s (high then low) | 8 |
| `SystemTime` | `systemSeconds` as Int64 (nanoseconds dropped) | 8 |
| `Text` | UTF-8 then ByteString encoding (1-byte length prefix) | 1 + len |
| `String` | `B.pack` then ByteString encoding | 1 + len |

### `Maybe a`

```
Nothing → '0' (0x30)
Just x  → '1' (0x31) ++ smpEncode x
```

Tags are ASCII characters `'0'`/`'1'`, not binary 0x00/0x01.

### Tuples

Tuples (2 through 8) encode as simple concatenation — no length prefix, no separator. Fields are parsed sequentially using each component's `smpP`. This works because each component's parser knows how many bytes to consume (via its own length prefix or fixed size).

### Combinators

| Function | Signature | Purpose |
|----------|-----------|---------|
| `_smpP` | `Parser a` | Space-prefixed parser (`A.space *> smpP`) |
| `smpEncodeList` | `[a] -> ByteString` | 1-byte count + concatenated items |
| `smpListP` | `Parser [a]` | Parse count then that many items |
| `lenEncode` | `Int -> Char` | Int to single-byte length char |

## String Encoding (`StrEncoding` class)

```haskell
class StrEncoding a where
  strEncode :: a -> ByteString
  strDecode :: ByteString -> Either String a  -- default: parseAll strP
  strP :: Parser a                            -- default: strDecode <$?> base64urlP
```

Key difference from `Encoding`: the default `strP` parses base64url input first, then applies `strDecode`. This means types that only implement `strDecode` will automatically accept base64url-encoded input.

### Instance conventions

| Type | Encoding |
|------|----------|
| `ByteString` | base64url (non-empty required) |
| `Word16`, `Word32` | Decimal string |
| `Int`, `Int64` | Signed decimal |
| `Char`, `Bool` | Delegates to `Encoding` (`smpEncode`/`smpP`) |
| `Maybe a` | Empty string = `Nothing`, otherwise `strEncode a` |
| `Text` | UTF-8 bytes, parsed until space/newline |
| `SystemTime` | `systemSeconds` as Int64 (decimal) |
| `UTCTime` | ISO 8601 string |
| `CertificateChain` | Comma-separated base64url blobs |
| `Fingerprint` | base64url of fingerprint bytes |

### Collection encoding

| Type | Separator |
|------|-----------|
| Lists (`strEncodeList`) | Comma `,` |
| `NonEmpty` | Comma (fails on empty) |
| `Set a` | Comma |
| `IntSet` | Comma |
| Tuples (2-6) | Space (` `) |

### `Str` newtype

Raw string (not base64url-encoded). Parses until space, consumes trailing space. Used for string-valued protocol fields that should not be base64-encoded.

### `TextEncoding` class

```haskell
class TextEncoding a where
  textEncode :: a -> Text
  textDecode :: Text -> Maybe a
```

Separate from `StrEncoding` — operates on `Text` rather than `ByteString`. Used for types that need Text representation (e.g., enum display names).

### JSON bridge functions

| Function | Purpose |
|----------|---------|
| `strToJSON` | `StrEncoding a => a -> J.Value` via `decodeLatin1 . strEncode` |
| `strToJEncoding` | Same, for Aeson encoding |
| `strParseJSON` | `StrEncoding a => String -> J.Value -> JT.Parser a` — parse JSON string via `strP` |
| `textToJSON` | `TextEncoding a => a -> J.Value` |
| `textToEncoding` | Same, for Aeson encoding |
| `textParseJSON` | `TextEncoding a => String -> J.Value -> JT.Parser a` |

## Parsers

**Source**: [`Parsers.hs`](../src/Simplex/Messaging/Parsers.hs)

### Core parsing functions

| Function | Signature | Purpose |
|----------|-----------|---------|
| `parseAll` | `Parser a -> ByteString -> Either String a` | Parse consuming all input (fails if bytes remain) |
| `parse` | `Parser a -> e -> ByteString -> Either e a` | `parseAll` with custom error type (discards error string) |
| `parseE` | `(String -> e) -> Parser a -> ByteString -> ExceptT e IO a` | `parseAll` lifted into `ExceptT` |
| `parseE'` | `(String -> e) -> Parser a -> ByteString -> ExceptT e IO a` | Like `parseE` but allows trailing input |
| `parseRead1` | `Read a => Parser a` | Parse a word then `readMaybe` it |
| `parseString` | `(ByteString -> Either String a) -> String -> a` | Parse from `String` (errors with `error`) |

### `base64P`

Standard base64 parser (not base64url — uses `+`/`/` alphabet). Takes alphanumeric + `+`/`/` characters, optional `=` padding, then decodes. Contrast with `base64urlP` in `Encoding/String.hs` which uses `-`/`_` alphabet.

### JSON options helpers

Platform-conditional JSON encoding for cross-platform compatibility (Haskell ↔ Swift).

| Function | Purpose |
|----------|---------|
| `enumJSON` | All-nullary constructors as strings, with tag modifier |
| `sumTypeJSON` | Platform-conditional: `taggedObjectJSON` on non-Darwin, `singleFieldJSON` on Darwin |
| `taggedObjectJSON` | `{"type": "Tag", "data": {...}}` format |
| `singleFieldJSON` | `{"Tag": value}` format |
| `defaultJSON` | Default options with `omitNothingFields = True` |

Pattern synonyms for JSON field names:
- `TaggedObjectJSONTag = "type"`
- `TaggedObjectJSONData = "data"`
- `SingleFieldJSONTag = "_owsf"`

### String helpers

| Function | Purpose |
|----------|---------|
| `fstToLower` | Lowercase first character |
| `dropPrefix` | Remove prefix string, lowercase remainder |
| `textP` | Parse rest of input as UTF-8 `String` |

## Auxiliary Types and Utilities

### TMap

**Source**: [`TMap.hs`](../src/Simplex/Messaging/TMap.hs)

```haskell
type TMap k a = TVar (Map k a)
```

STM-based concurrent map. Wraps `Data.Map.Strict` in a `TVar`. All mutations use `modifyTVar'` (strict) to prevent thunk accumulation.

| Function | Notes |
|----------|-------|
| `emptyIO` | IO allocation (`newTVarIO`) |
| `singleton` | STM allocation |
| `clear` | Reset to empty |
| `lookup` / `lookupIO` | STM / non-transactional IO read |
| `member` / `memberIO` | STM / non-transactional IO membership |
| `insert` / `insertM` | Insert value / insert from STM action |
| `delete` | Remove key |
| `lookupInsert` | Atomic lookup-then-insert (returns old value) |
| `lookupDelete` | Atomic lookup-then-delete |
| `adjust` / `update` / `alter` / `alterF` | Standard Map operations lifted to STM |
| `union` | Merge `Map` into `TMap` |

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

| Function | Purpose |
|----------|---------|
| `getSessVar` | Lookup or create session. Returns `Left new` or `Right existing` |
| `removeSessVar` | Delete session only if ID matches (prevents removing a replacement) |
| `tryReadSessVar` | Non-blocking read of session result |

The ID-match check in `removeSessVar` prevents a race where:
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

`simplexChat` is the constant `SSAppServer (SrvLoc "simplex.chat" "")`.

### SystemTime

**Source**: [`SystemTime.hs`](../src/Simplex/Messaging/SystemTime.hs)

```haskell
newtype RoundedSystemTime (t :: Nat) = RoundedSystemTime { roundedSeconds :: Int64 }
type SystemDate = RoundedSystemTime 86400    -- day precision
type SystemSeconds = RoundedSystemTime 1     -- second precision
```

Phantom-typed time rounding. The `Nat` type parameter specifies rounding granularity in seconds.

| Function | Purpose |
|----------|---------|
| `getRoundedSystemTime` | Get current time rounded to `t` seconds |
| `getSystemDate` | Alias for day-rounded time |
| `getSystemSeconds` | Second-precision (no rounding needed, just drops nanoseconds) |
| `roundedToUTCTime` | Convert back to `UTCTime` |

`RoundedSystemTime` derives `FromField`/`ToField` for SQLite storage and `FromJSON`/`ToJSON` for API serialization.

### Util

**Source**: [`Util.hs`](../src/Simplex/Messaging/Util.hs)

Selected utilities used across the codebase:

**Monadic combinators**:

| Function | Signature | Purpose |
|----------|-----------|---------|
| `<$?>` | `MonadFail m => (a -> Either String b) -> m a -> m b` | Lift fallible function into parser |
| `$>>=` | `(Monad m, Monad f, Traversable f) => m (f a) -> (a -> m (f b)) -> m (f b)` | Monadic bind through nested monad |
| `ifM` / `whenM` / `unlessM` | Monadic conditionals | |
| `anyM` | Short-circuit `any` for monadic predicates (strict) | |

**Error handling**:

| Function | Purpose |
|----------|---------|
| `tryAllErrors` | Catch all exceptions (including async) into `ExceptT` |
| `catchAllErrors` | Same with handler |
| `tryAllOwnErrors` | Catch only "own" exceptions (re-throws async cancellation) |
| `catchAllOwnErrors` | Same with handler |
| `isOwnException` | `StackOverflow`, `HeapOverflow`, `AllocationLimitExceeded` |
| `isAsyncCancellation` | Any `SomeAsyncException` except own exceptions |
| `catchThrow` | Catch exceptions, wrap in Left |
| `allFinally` | `tryAllErrors` + `final` + `except` (like `finally` for ExceptT) |

The own-vs-async distinction is critical: `catchOwn`/`tryAllOwnErrors` never swallow async cancellation (`ThreadKilled`, `UserInterrupt`, etc.), only synchronous exceptions and resource exhaustion (`StackOverflow`, `HeapOverflow`, `AllocationLimitExceeded`).

**STM**:

| Function | Purpose |
|----------|---------|
| `tryWriteTBQueue` | Non-blocking bounded queue write, returns success |

**Database result helpers**:

| Function | Purpose |
|----------|---------|
| `firstRow` | Extract first row with transform, or Left error |
| `maybeFirstRow` | Extract first row as Maybe |
| `firstRow'` | Like `firstRow` but transform can also fail |

**Collection utilities**:

| Function | Purpose |
|----------|---------|
| `groupOn` | `groupBy` using equality on projected key |
| `groupAllOn` | `groupOn` after `sortOn` (groups non-adjacent elements) |
| `toChunks` | Split list into `NonEmpty` chunks of size n |
| `packZipWith` | Optimized ByteString zipWith (direct memory access) |

**Miscellaneous**:

| Function | Purpose |
|----------|---------|
| `safeDecodeUtf8` | Decode UTF-8 replacing errors with `'?'` |
| `bshow` / `tshow` | `show` to `ByteString` / `Text` |
| `threadDelay'` | `Int64` delay (handles overflow by looping) |
| `diffToMicroseconds` / `diffToMilliseconds` | `NominalDiffTime` conversion |
| `labelMyThread` | Label current thread for debugging |
| `encodeJSON` / `decodeJSON` | `ToJSON a => a -> Text` / `FromJSON a => Text -> Maybe a` |
| `traverseWithKey_` | `Map` traversal discarding results |

## Security notes

- **Length prefix overflow**: `ByteString` encoding uses 1-byte length — silently truncates strings > 255 bytes. Callers must ensure size bounds before encoding. `Large` extends to 65535 bytes via Word16 prefix.
- **`Tail` unbounded**: `Tail` consumes all remaining input with no size check. Only safe when total message size is already bounded (e.g., within a padded SMP block).
- **base64 vs base64url**: `Parsers.base64P` uses standard alphabet (`+`/`/`), while `String.base64urlP` uses URL-safe alphabet (`-`/`_`). Mixing them causes silent decode failures.
- **`safeDecodeUtf8`**: Replaces invalid UTF-8 with `'?'` rather than failing. Suitable for logging/display, not for security-critical string comparison.
