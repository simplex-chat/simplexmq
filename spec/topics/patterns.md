# Code Patterns

Cross-cutting patterns used throughout the codebase: exception handling, encoding utilities, compression, concurrent data structures, and batch processing. These patterns provide consistency, type safety, and correctness guarantees across all modules.

For protocol-specific encoding details, see [transport.md](transport.md). For cryptographic operations, see the inline documentation in [Crypto.hs](../../src/Simplex/Messaging/Crypto.hs).

- [Exception handling](#exception-handling)
- [Binary encoding](#binary-encoding)
- [String encoding](#string-encoding)
- [Compression](#compression)
- [Concurrent data structures](#concurrent-data-structures)
- [Batch processing](#batch-processing)

---

## Exception handling

**Source**: [Agent/Protocol.hs](../../src/Simplex/Messaging/Agent/Protocol.hs), [Agent/Client.hs](../../src/Simplex/Messaging/Agent/Client.hs), [Agent/Store/SQLite.hs](../../src/Simplex/Messaging/Agent/Store/SQLite.hs)

### Error type hierarchy

The codebase uses a hierarchical error type structure:

**`AgentErrorType`** - top-level error type for agent client responses:
- `CMD` - command/response errors with context string
- `CONN` - connection errors with context (NOT_FOUND, DUPLICATE, SIMPLEX)
- `SMP`/`NTF`/`XFTP` - protocol-specific errors with server address
- `BROKER` - transport-level broker errors
- `AGENT` - internal agent errors (A_DUPLICATE, A_PROHIBITED)
- `INTERNAL` - implementation bugs (should never occur in production)
- `CRITICAL` - critical errors with optional restart offer

**`StoreError`** - database/storage layer errors:
- `SEInternal` - IO exceptions during database operations
- `SEDatabaseBusy` - database locked/busy (triggers CRITICAL with restart)
- `SEConnNotFound`/`SEUserNotFound` - entity lookup failures
- `SEBadConnType` - wrong connection type for operation

**`AgentCryptoError`** - cryptographic failures:
- `DECRYPT_AES`/`DECRYPT_CB` - decryption failures
- `RATCHET_HEADER`/`RATCHET_EARLIER Word32`/`RATCHET_SKIPPED Word32`/`RATCHET_SYNC` - double ratchet state issues

### Monad stack

```
AM a  = ExceptT AgentErrorType (ReaderT Env IO) a  -- full error handling
AM' a = ReaderT Env IO a                            -- no error handling (for batch ops)
```

### Store access patterns

**Basic operations** lift IO actions into the AM monad:

```haskell
withStore :: AgentClient -> (DB.Connection -> IO (Either StoreError a)) -> AM a
withStore' :: AgentClient -> (DB.Connection -> IO a) -> AM a  -- wraps result in Right
```

Both wrap the action in a database transaction and convert `StoreError` to `AgentErrorType` via `storeError`.

**Error mapping** (key cases from `storeError`):
- `SEConnNotFound`/`SERatchetNotFound` -> `CONN NOT_FOUND`
- `SEConnDuplicate` -> `CONN DUPLICATE`
- `SEBadConnType` -> `CONN SIMPLEX` with context
- `SEUserNotFound` -> `NO_USER`
- `SEAgentError e` -> `e` (propagates wrapped error)
- `SEDatabaseBusy` -> `CRITICAL True` (offers restart)
- Other errors -> `INTERNAL` with error message

### Error recovery patterns

**tryError** - attempt an operation, handle failure without throwing:
```haskell
tryError (deleteQueue c NRMBackground rq') >>= \case
  Left e -> logError e >> continue
  Right () -> success
```

**catchAllErrors** - catch errors and run cleanup:
```haskell
getQueueMessage c rq `catchAllErrors` \e ->
  atomically (releaseGetLock c rq) >> throwError e
```

**catchAll_** - catch all exceptions, return default on failure:
```haskell
notices <- liftIO $ withTransaction store (`getClientNotices` servers) `catchAll_` pure []
```

---

## Binary encoding

**Source**: [Encoding.hs](../../src/Simplex/Messaging/Encoding.hs)

### Encoding typeclass

```haskell
class Encoding a where
  smpEncode :: a -> ByteString      -- encode to binary
  smpP :: Parser a                   -- attoparsec parser
  smpDecode :: ByteString -> Either String a  -- default via parseAll smpP
```

### Primitive encoding

| Type | Wire format |
|------|-------------|
| `Char` | Single byte |
| `Bool` | `'T'` or `'F'` |
| `Word16` | 2-byte big-endian |
| `Word32` | 4-byte big-endian |
| `Int64` | Two `Word32`s combined |
| `ByteString` | 1-byte length prefix + data (max 255 bytes) |
| `Maybe a` | `'0'` (Nothing) or `'1'` + encoded value |
| `(a, b)` | Concatenated encodings (no separator) |

### Special wrappers

**`Tail`** - takes remaining bytes without length prefix:
```haskell
newtype Tail = Tail {unTail :: ByteString}
-- smpEncode = unTail (no prefix)
-- smpP = takeByteString
```

**`Large`** - for ByteStrings > 255 bytes:
```haskell
newtype Large = Large {unLarge :: ByteString}
-- smpEncode = Word16 length prefix + data
-- smpP = read Word16, take that many bytes
```

### List encoding

```haskell
smpEncodeList :: Encoding a => [a] -> ByteString
-- 1-byte count prefix + concatenated encoded items (max 255 items)

instance Encoding (NonEmpty a)
-- Same format, fails on empty input during parsing
```

---

## String encoding

**Source**: [Encoding/String.hs](../../src/Simplex/Messaging/Encoding/String.hs)

### StrEncoding typeclass

```haskell
class StrEncoding a where
  strEncode :: a -> ByteString      -- human-readable encoding
  strP :: Parser a                   -- parser (defaults to base64url)
  strDecode :: ByteString -> Either String a
```

Used for addresses, keys, and values displayed to users or in URIs.

### Base64 URL encoding

`ByteString` instances use base64url encoding (RFC 4648):
- Alphabet: A-Z, a-z, 0-9, `-`, `_`
- No padding by default in output
- Accepts optional `=` padding on input

### Tuple and list encoding

**Tuples** use space separation (via `B.unwords`):
```haskell
strEncode (a, b) = B.unwords [strEncode a, strEncode b]
```

**Lists** use comma separation:
```haskell
strEncodeList :: StrEncoding a => [a] -> ByteString
strEncodeList = B.intercalate "," . map strEncode
```

### Numeric types

`Int`, `Word16`, `Word32`, `Int64` encode as decimal strings (not binary).

### JSON conversion utilities

```haskell
strToJSON :: StrEncoding a => a -> J.Value
strParseJSON :: StrEncoding a => String -> J.Value -> JT.Parser a
```

Convert between `StrEncoding` and JSON string values for API serialization.

---

## Compression

**Source**: [Compression.hs](../../src/Simplex/Messaging/Compression.hs)

### Algorithm and thresholds

Uses Zstandard (zstd) compression at level 3 (moderate compression/speed tradeoff).

```haskell
maxLengthPassthrough :: Int
maxLengthPassthrough = 180  -- messages <= 180 bytes are not compressed
```

### Wire format

```haskell
data Compressed
  = Passthrough ByteString  -- tag '0' + 1-byte length + data
  | Compressed Large        -- tag '1' + 2-byte length + zstd data
```

### Decompression bomb protection

`decompress1` requires the compressed data to declare its decompressed size upfront:

```haskell
decompress1 :: Int -> Compressed -> Either String ByteString
```

The function checks `Z1.decompressedSize` before decompressing. If the declared size exceeds the `limit` parameter (or is not specified), decompression is rejected. This prevents zip-bomb attacks where a small compressed payload would expand to exhaust memory.

Zstd's `decompress` can return `Error`, `Skip` (empty result), or `Decompress bs'` - all cases are handled explicitly.

---

## Concurrent data structures

**Source**: [TMap.hs](../../src/Simplex/Messaging/TMap.hs)

### TMap

A `TVar`-wrapped immutable `Data.Map`, providing atomic read-modify-write operations via STM:

```haskell
type TMap k a = TVar (Map k a)
```

### STM operations (atomic)

| Operation | Description |
|-----------|-------------|
| `lookup k m` | Read value for key |
| `member k m` | Check key existence |
| `insert k v m` | Insert/update value |
| `delete k m` | Remove key |
| `lookupInsert k v m` | Atomic lookup-then-insert, returns old value |
| `lookupDelete k m` | Atomic lookup-then-delete, returns deleted value |

### IO operations (non-transactional)

```haskell
lookupIO :: Ord k => k -> TMap k a -> IO (Maybe a)
memberIO :: Ord k => k -> TMap k a -> IO Bool
```

These bypass STM for read-only access when atomicity with other operations is not needed.

### Usage pattern

```haskell
-- Within STM transaction (atomic with other STM ops)
atomically $ do
  existing <- TM.lookup key map
  case existing of
    Nothing -> TM.insert key newValue map
    Just _ -> pure ()

-- Outside transaction (simple read)
value <- TM.lookupIO key map
```

---

## Batch processing

**Source**: [Agent/Client.hs](../../src/Simplex/Messaging/Agent/Client.hs)

### withStoreBatch

Executes multiple database operations in a single transaction:

```haskell
withStoreBatch :: Traversable t
  => AgentClient
  -> (DB.Connection -> t (IO (Either AgentErrorType a)))
  -> AM' (t (Either AgentErrorType a))
```

All operations run within one database transaction, ensuring:
- **Atomicity**: All operations succeed or all fail together
- **Isolation**: No partial updates visible to other readers
- **Efficiency**: Single transaction overhead instead of per-operation

### Result semantics

Each batched operation produces an individual `Either AgentErrorType a`:
- Partial success is possible (some `Right`, some `Left`)
- If the transaction itself fails, all results become errors
- Fine-grained error handling per operation

### Common patterns

**Store multiple items**:
```haskell
void $ withStoreBatch' c $ \db ->
  map (storeDelivery db) deliveries
```

**Fetch multiple items**:
```haskell
results <- withStoreBatch c $ \db ->
  map (getConnection db) connIds
```

**Update multiple items**:
```haskell
void $ withStoreBatch' c $ \db ->
  map (\connId -> setConnPQSupport db connId PQSupportOn) connIds
```

### withStoreBatch'

Convenience variant that wraps results in `Right`:

```haskell
withStoreBatch' :: Traversable t
  => AgentClient
  -> (DB.Connection -> t (IO a))
  -> AM' (t (Either AgentErrorType a))
```

Use when operations cannot fail (or failures should become `INTERNAL` errors).
