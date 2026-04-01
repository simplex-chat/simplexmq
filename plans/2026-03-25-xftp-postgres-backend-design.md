# XFTP Server PostgreSQL Backend

## Overview

Add PostgreSQL backend support to xftp-server, following the SMP server pattern. Supports bidirectional migration between STM (in-memory with StoreLog) and PostgreSQL backends.

## Goals

- PostgreSQL-backed file metadata storage as an alternative to STM + StoreLog
- Polymorphic server code via `FileStoreClass` typeclass with IO-based methods (following `QueueStoreClass` pattern)
- Bidirectional migration: StoreLog <-> PostgreSQL via CLI commands
- Shared `server_postgres` cabal flag (same flag enables both SMP and XFTP Postgres support)
- INI-based backend selection at runtime

## Architecture

### FileStoreClass Typeclass

IO-based typeclass following the `QueueStoreClass` pattern — each method is a self-contained IO action, with the implementation responsible for its own atomicity (STM backend wraps in `atomically`, Postgres backend uses database transactions):

```haskell
class FileStoreClass s where
  type FileStoreConfig s :: Type

  -- Lifecycle
  newFileStore :: FileStoreConfig s -> IO s
  closeFileStore :: s -> IO ()

  -- File operations
  addFile :: s -> SenderId -> FileInfo -> RoundedFileTime -> ServerEntityStatus -> IO (Either XFTPErrorType ())
  setFilePath :: s -> SenderId -> FilePath -> IO (Either XFTPErrorType ())
  addRecipient :: s -> SenderId -> FileRecipient -> IO (Either XFTPErrorType ())
  getFile :: s -> SFileParty p -> XFTPFileId -> IO (Either XFTPErrorType (FileRec, C.APublicAuthKey))
  deleteFile :: s -> SenderId -> IO (Either XFTPErrorType ())
  blockFile :: s -> SenderId -> BlockingInfo -> Bool -> IO (Either XFTPErrorType ())
  deleteRecipient :: s -> RecipientId -> FileRec -> IO ()
  ackFile :: s -> RecipientId -> IO (Either XFTPErrorType ())

  -- Expiration (with LIMIT for Postgres; called in a loop until empty)
  expiredFiles :: s -> Int64 -> Int -> IO [(SenderId, Maybe FilePath, Word32)]

  -- Storage and stats (for init-time computation)
  getUsedStorage :: s -> IO Int64
  getFileCount :: s -> IO Int
```

- STM backend: each method wraps its STM transaction in `atomically` internally.
- Postgres backend: each method runs its query via `withDB` / database connection internally.

No polymorphic monad or `runStore` dispatcher needed — unlike `MsgStoreClass`, XFTP file operations are individually atomic and don't require grouping multiple operations into backend-dependent transactions.

### PostgresFileStore Data Type

```haskell
data PostgresFileStore = PostgresFileStore
  { dbStore :: DBStore
  , dbStoreLog :: Maybe (StoreLog 'WriteMode)
  }
```

- `dbStore` — connection pool created via `createDBStore`, runs schema migrations on init.
- `dbStoreLog` — optional parallel log file (enabled by `db_store_log` INI setting). When present, every mutation (`addFile`, `setFilePath`, `deleteFile`, `blockFile`, `addRecipient`, `ackFile`) also writes to this log via a `withLog` wrapper. `withLog` is called AFTER the DB operation succeeds (so the log reflects committed state only). Log write failures are non-fatal (logged as warnings, do not fail the DB operation). This provides an audit trail and enables recovery via export.

`closeFileStore` for Postgres calls `closeDBStore` (closes connection pool) then `mapM_ closeStoreLog dbStoreLog` (flushes and closes the parallel log). For STM, it closes the storeLog. Called from a `finally` block during server shutdown, matching SMP's `stopServer` → `closeMsgStore` → `closeQueueStore` pattern.

### STMFileStore Type

After extracting from current `Store.hs`, `STMFileStore` retains the file and recipient maps but no longer owns `usedStorage` (moved to `XFTPEnv`):

```haskell
data STMFileStore = STMFileStore
  { files :: TMap SenderId FileRec
  , recipients :: TMap RecipientId (SenderId, RcvPublicAuthKey)
  }
```

`closeFileStore` for STM is a no-op (TMaps are garbage-collected; the env-level `storeLog` is closed separately by the server).

### Error Handling

Postgres operations follow SMP's `withDB` / `handleDuplicate` pattern:

```haskell
withDB :: Text -> PostgresFileStore -> (DB.Connection -> IO (Either XFTPErrorType a)) -> IO (Either XFTPErrorType a)
withDB op st action =
  E.try (withTransaction (dbStore st) action) >>= \case
    Right r -> pure r
    Left (e :: SomeException) -> logError ("STORE: " <> op <> ", " <> tshow e) $> Left INTERNAL

handleDuplicate :: SqlError -> IO (Either XFTPErrorType a)
handleDuplicate e = case constraintViolation e of
  Just (UniqueViolation _) -> pure $ Left DUPLICATE_
  _ -> E.throwIO e
```

- All DB operations wrapped in `withDB` — catches exceptions, logs, returns `INTERNAL`.
- Unique constraint violations caught by `handleDuplicate` and mapped to `DUPLICATE_`.
- UPDATE operations verified with `assertUpdated` — returns `AUTH` if 0 rows affected (matching SMP pattern, prevents silent failures when WHERE clause doesn't match).
- Critical sections (DB write + TVar update) wrapped in `uninterruptibleMask_` to prevent async exceptions from leaving inconsistent state between DB and TVars.

### FileRec and TVar Fields

`FileRec` retains its `TVar` fields (matching SMP's `PostgresQueue` pattern):

```haskell
data FileRec = FileRec
  { senderId :: SenderId
  , fileInfo :: FileInfo
  , filePath :: TVar (Maybe FilePath)
  , recipientIds :: TVar (Set RecipientId)
  , createdAt :: RoundedFileTime
  , fileStatus :: TVar ServerEntityStatus
  }
```

- **STM backend**: TVars are the source of truth, as currently.
- **Postgres backend**: `getFile` reads from DB and creates a `FileRec` with fresh TVars populated from the DB row (matching SMP's `mkQ` pattern — `newTVarIO` per load). Mutation methods (`setFilePath`, `blockFile`, etc.) update both the DB (persistence) and the TVars (in-session consistency). The `recipientIds` TVar is initialized to `S.empty` — no subquery needed because no server code reads `recipientIds` directly; all recipient operations go through the typeclass methods (`addRecipient`, `deleteRecipient`, `ackFile`), which query the `recipients` table for Postgres.

### usedStorage Ownership

`usedStorage :: TVar Int64` moves from the store to `XFTPEnv`. The store typeclass does **not** manage `usedStorage` — it only provides `getUsedStorage` for init-time computation.

- **STM init**: StoreLog replay calls `setFilePath` (which only sets the filePath TVar — the STM `setFilePath` implementation is changed to **not** update `usedStorage`). Similarly, STM `deleteFile` (Store.hs line 117) and `blockFile` (line 125) are changed to **not** update `usedStorage` — the server handles all `usedStorage` adjustments externally. After replay, `getUsedStorage` computes the sum over all file sizes (matching current `countUsedStorage` behavior).
- **Postgres init**: `getUsedStorage` executes `SELECT COALESCE(SUM(file_size), 0) FROM files`.
- **Runtime**: Server manages `usedStorage` TVar directly for reserve/commit/rollback during uploads, and adjusts after `deleteFile`/`blockFile` calls.

**Note on `getUsedStorage` semantics**: The current STM `countUsedStorage` sums all file sizes unconditionally (including files without `filePath` set, i.e., created but not yet uploaded). The Postgres `getUsedStorage` matches this: `SELECT SUM(file_size) FROM files` (no `WHERE file_path IS NOT NULL`). In practice, orphaned files (created but never uploaded) are rare and short-lived (expired within 48h), so the difference is negligible. A future improvement could filter by `file_path IS NOT NULL` in both backends to reflect actual disk usage more accurately.

### Server.hs Refactoring

`Server.hs` becomes polymorphic over `FileStoreClass s`. Since all typeclass methods are IO, call sites replace `atomically` with direct IO calls to the store.

**Call sites requiring changes** (exhaustive list):

1. **`receiveServerFile`** (line 563): `atomically $ writeTVar filePath (Just fPath)` → `setFilePath store senderId fPath`. The `reserve` logic (line 551-555) stays as direct TVar manipulation on `usedStorage` from `XFTPEnv`.

2. **`verifyXFTPTransmission`** (line 453): `atomically $ verify =<< getFile st party fId` — the `getFile` call and subsequent `readTVar fileStatus` are in a single `atomically` block. Refactored to: `getFile st party fId` (IO), then `readTVarIO (fileStatus fr)` from the returned `FileRec` (safe for both backends — STM TVar is the source of truth, Postgres TVar is a fresh snapshot from DB).

3. **`retryAdd`** (line 516): Signature `XFTPFileId -> STM (Either XFTPErrorType a)` → `XFTPFileId -> IO (Either XFTPErrorType a)`. The `atomically` call (line 520) replaced with `liftIO`.

4. **`deleteOrBlockServerFile_`** (line 620): Parameter `FileStore -> STM (Either XFTPErrorType ())` → `FileStoreClass s => s -> IO (Either XFTPErrorType ())`. The `atomically` call (line 626) removed — the store method is already IO. After the store action, server adjusts `usedStorage` TVar in `XFTPEnv` based on `fileInfo.size`.

5. **`ackFileReception`** (line 605): `atomically $ deleteRecipient st rId fr` → `deleteRecipient st rId fr`.

6. **Control port `CPDelete`/`CPBlock`** (lines 371, 377): `atomically $ getFile fs SFRecipient fileId` → `getFile fs SFRecipient fileId`.

7. **`expireServerFiles`** (line 636): Replace per-file `expiredFilePath` iteration with batched `expiredFiles st old batchSize`, which returns `[(SenderId, Maybe FilePath, Word32)]` — the `Word32` file size is needed so the server can adjust the `usedStorage` TVar after each deletion. Called in a loop until the returned list is empty. The `itemDelay` between files applies to the deletion loop over each batch, not the query itself. STM backend ignores the batch size limit (returns all expired files from TMap scan); Postgres uses `LIMIT`.

8. **`restoreServerStats`** (line 694): `FileStore {files, usedStorage} <- asks store` accesses store fields directly. Refactored to: `usedStorage` from `XFTPEnv` via `asks usedStorage`, file count via `getFileCount store`. STM: `M.size <$> readTVarIO files`. Postgres: `SELECT COUNT(*) FROM files`.

### Store Config Selection

GADT in `Env.hs`:

```haskell
data XFTPStoreConfig s where
  XSCMemory :: Maybe FilePath -> XFTPStoreConfig STMFileStore
#if defined(dbServerPostgres)
  XSCDatabase :: PostgresFileStoreCfg -> XFTPStoreConfig PostgresFileStore
#endif
```

`XFTPEnv` becomes polymorphic:

```haskell
data XFTPEnv s = XFTPEnv
  { config :: XFTPServerConfig
  , store :: s
  , usedStorage :: TVar Int64
  , storeLog :: Maybe (StoreLog 'WriteMode)
  , ...
  }
```

The `M` monad (`ReaderT (XFTPEnv s) IO`) and all functions in `Server.hs` gain `FileStoreClass s =>` constraints.

**StoreLog lifecycle per backend:**

- **STM mode**: `storeLog = Just sl` (current behavior — append-only log for persistence and recovery).
- **Postgres mode**: `storeLog = Nothing` (main storeLog disabled — Postgres is the source of truth). The optional parallel `dbStoreLog` inside `PostgresFileStore` provides audit/recovery if enabled via `db_store_log` INI setting.

The existing `withFileLog` pattern in Server.hs continues to work unchanged — it maps over `Maybe (StoreLog 'WriteMode)`, which is `Nothing` in Postgres mode so the calls become no-ops.

### Main.hs Store Type Dispatch

The `Start` CLI command gains a `--confirm-migrations` flag (default `MCConsole` — manual prompt, matching SMP's `StartOptions`). For automated deployments, `--confirm-migrations up` auto-applies forward migrations. The import command uses `MCYesUp` (always auto-apply).

Following SMP's existential dispatch pattern (`AStoreType` + `run`), `Main.hs` selects the store type from INI config and dispatches to the polymorphic server:

```haskell
runServer ini = do
  let storeType = fromRight "memory" $ lookupValue "STORE_LOG" "store_files" ini
  case storeType of
    "memory" -> run $ XSCMemory (enableStoreLog $> storeLogFilePath)
    "database" ->
#if defined(dbServerPostgres)
      run $ XSCDatabase PostgresFileStoreCfg {..}
#else
      exitError "server not compiled with Postgres support"
#endif
    _ -> exitError $ "Invalid store_files value: " <> storeType
  where
    run :: FileStoreClass s => XFTPStoreConfig s -> IO ()
    run storeCfg = do
      env <- newXFTPServerEnv storeCfg config
      runReaderT (xftpServer config) env
```

**`newXFTPServerEnv` refactored signature:**

```haskell
newXFTPServerEnv :: FileStoreClass s => XFTPStoreConfig s -> XFTPServerConfig -> IO (XFTPEnv s)
newXFTPServerEnv storeCfg config = do
  (store, storeLog) <- case storeCfg of
    XSCMemory storeLogPath -> do
      st <- newFileStore ()
      sl <- mapM (`readWriteFileStore` st) storeLogPath
      pure (st, sl)
    XSCDatabase dbCfg -> do
      st <- newFileStore dbCfg
      pure (st, Nothing)  -- main storeLog disabled for Postgres
  usedStorage <- newTVarIO =<< getUsedStorage store
  ...
  pure XFTPEnv {config, store, usedStorage, storeLog, ...}
```

### Startup Config Validation

Following SMP's `checkMsgStoreMode` pattern, `Main.hs` validates config before starting:

- **`store_files=database` + StoreLog file exists** (without `db_store_log=on`): Error — "StoreLog file present but store_files is `database`. Use `xftp-server database import` to migrate, or set `db_store_log: on`."
- **`store_files=database` + schema doesn't exist**: Error — "Create schema in PostgreSQL or use `xftp-server database import`."
- **`store_files=memory` + Postgres schema exists**: Warning — "Postgres schema exists but store_files is `memory`. Data in Postgres will not be used."
- **Binary compiled without `server_postgres` + `store_files=database`**: Error — "Server not compiled with Postgres support."

## Module Structure

```
src/Simplex/FileTransfer/Server/
  Store.hs                    -- FileStoreClass typeclass + shared types (FileRec, FileRecipient, etc.)
  Store/
    STM.hs                    -- STMFileStore (extracted from current Store.hs)
    Postgres.hs               -- PostgresFileStore                [CPP-guarded]
    Postgres/
      Migrations.hs           -- Schema migrations                [CPP-guarded]
      Config.hs               -- PostgresFileStoreCfg             [CPP-guarded]
  StoreLog.hs                 -- Unchanged (interchange format for both backends + migration)
  Env.hs                      -- XFTPStoreConfig GADT, polymorphic XFTPEnv
  Main.hs                     -- Store selection, migration CLI commands
  Server.hs                   -- Polymorphic over FileStoreClass
```

## PostgreSQL Schema

Initial migration (`20260325_initial`):

```sql
CREATE TABLE files (
  sender_id BYTEA NOT NULL PRIMARY KEY,
  file_size INT4 NOT NULL,
  file_digest BYTEA NOT NULL,
  sender_key BYTEA NOT NULL,
  file_path TEXT,
  created_at INT8 NOT NULL,
  status TEXT NOT NULL DEFAULT 'active'
);

CREATE TABLE recipients (
  recipient_id BYTEA NOT NULL PRIMARY KEY,
  sender_id BYTEA NOT NULL REFERENCES files ON DELETE CASCADE,
  recipient_key BYTEA NOT NULL
);

CREATE INDEX idx_recipients_sender_id ON recipients (sender_id);
CREATE INDEX idx_files_created_at ON files (created_at);
```

- `file_size` is `INT4` matching `Word32` in `FileInfo.size`
- `sender_key` and `recipient_key` stored as `BYTEA` using binary encoding via `C.encodePubKey` / `C.decodePubKey` (matching SMP's `ToField`/`FromField` instances for `APublicAuthKey` — includes algorithm type tag in the binary format)
- `file_path` nullable (set after upload completes via `setFilePath`)
- `ON DELETE CASCADE` for recipients when file is hard-deleted
- `created_at` stores rounded epoch seconds (1-hour precision, `RoundedFileTime`)
- `status` as TEXT via `StrEncoding` (`ServerEntityStatus`: `EntityActive`, `EntityBlocked info`, `EntityOff`)
- Hard deletes (no `deleted_at` column)
- No PL/pgSQL functions needed; `setFilePath` uses `WHERE file_path IS NULL` to prevent duplicate uploads (the `UPDATE` itself acquires a row-level lock)
- `used_storage` computed on startup: `SELECT COALESCE(SUM(file_size), 0) FROM files` (matches STM `countUsedStorage` — all files, see usedStorage Ownership section)

### Migrations Module

Following SMP's `QueueStore/Postgres/Migrations.hs` pattern:

```haskell
module Simplex.FileTransfer.Server.Store.Postgres.Migrations (xftpServerMigrations) where

import Data.List (sortOn)
import Data.Text (Text)
import Simplex.Messaging.Agent.Store.Shared (Migration (..))
import Text.RawString.QQ (r)

xftpServerMigrations :: [Migration]
xftpServerMigrations = sortOn name $ map (\(name, up, down) -> Migration {name, up, down}) schemaMigrations

schemaMigrations :: [(String, Text, Maybe Text)]
schemaMigrations =
  [ ("20260325_initial", m20260325_initial, Nothing)  -- no down migration for initial
  ]

m20260325_initial :: Text
m20260325_initial = [r| ... CREATE TABLE files ... |]
```

The `Migration` type (from `Simplex.Messaging.Agent.Store.Shared`) has fields `{name :: String, up :: Text, down :: Maybe Text}`. Initial migration has `Nothing` for `down`. Future migrations should include `Just down_migration` for rollback support. Called via `createDBStore dbOpts xftpServerMigrations (MigrationConfig confirmMigrations Nothing)`.

### Postgres Operations

Key query patterns:

- **`addFile`**: `INSERT INTO files (...) VALUES (...)`, return `DUPLICATE_` on unique violation.
- **`setFilePath`**: `UPDATE files SET file_path = ? WHERE sender_id = ? AND file_path IS NULL`, verified with `assertUpdated` (returns `AUTH` if 0 rows affected — file not found or already uploaded). The `WHERE file_path IS NULL` prevents duplicate uploads; the `UPDATE` acquires a row lock implicitly. Only persists the path; `usedStorage` managed by server.
- **`addRecipient`**: `INSERT INTO recipients (...)`, plus check for duplicates. No need for `recipientIds` TVar update — Postgres derives it from the table.
- **`getFile`** (sender): `SELECT ... FROM files WHERE sender_id = ?`, returns auth key from `sender_key` column.
- **`getFile`** (recipient): `SELECT f.*, r.recipient_key FROM recipients r JOIN files f ON ... WHERE r.recipient_id = ?`.
- **`deleteFile`**: `DELETE FROM files WHERE sender_id = ?` (recipients cascade).
- **`blockFile`**: `UPDATE files SET status = ? WHERE sender_id = ?`. When `deleted = True`, the server adjusts `usedStorage` externally (matching current STM behavior where `blockFile` only updates status and storage, not `filePath`).
- **`expiredFiles`**: `SELECT sender_id, file_path, file_size FROM files WHERE created_at + ? < ? LIMIT ?` — batched query replaces per-file iteration, includes `file_size` for `usedStorage` adjustment. Called in a loop until no rows returned.

## INI Configuration

New keys in `[STORE_LOG]` section:

```ini
[STORE_LOG]
enable: on
store_files: memory            # memory | database
db_connection: postgresql://xftp@/xftp_server_store
db_schema: xftp_server
db_pool_size: 10
db_store_log: off
expire_files_hours: 48
```

`store_files` selects the backend (`store_files` rather than `store_queues` because XFTP stores files, not queues):
- `memory` -> `XSCMemory` (current behavior)
- `database` -> `XSCDatabase` (requires `server_postgres` build flag)

### INI Template Generation (`xftp-server init`)

The `iniFileContent` function in `Main.hs` must be updated to generate the new keys in the `[STORE_LOG]` section. Following SMP's `iniDbOpts` pattern with `optDisabled'` (prefixes `"# "` when value equals default), Postgres keys are generated commented out by default:

```ini
[STORE_LOG]
enable: on

# File storage mode: `memory` or `database` (PostgreSQL).
store_files: memory

# Database connection settings for PostgreSQL database (`store_files: database`).
# db_connection: postgresql://xftp@/xftp_server_store
# db_schema: xftp_server
# db_pool_size: 10

# Write database changes to store log file
# db_store_log: off

expire_files_hours: 48
```

Reuses `iniDBOptions` from `Simplex.Messaging.Server.CLI` for runtime parsing (falls back to defaults when keys are commented out or missing). `enableDbStoreLog'` pattern (`settingIsOn "STORE_LOG" "db_store_log"`) controls `dbStoreLogPath`.

### PostgresFileStoreCfg

```haskell
data PostgresFileStoreCfg = PostgresFileStoreCfg
  { dbOpts :: DBOpts          -- connstr, schema, poolSize, createSchema
  , dbStoreLogPath :: Maybe FilePath
  , confirmMigrations :: MigrationConfirmation
  }
```

No `deletedTTL` (hard deletes).

### Default DB Options

```haskell
defaultXFTPDBOpts :: DBOpts
defaultXFTPDBOpts = DBOpts
  { connstr = "postgresql://xftp@/xftp_server_store"
  , schema = "xftp_server"
  , poolSize = 10
  , createSchema = False
  }
```

## Migration CLI

Bidirectional migration via StoreLog as interchange format:

```
xftp-server database import [--database DB_CONN] [--schema DB_SCHEMA] [--pool-size N]
xftp-server database export [--database DB_CONN] [--schema DB_SCHEMA] [--pool-size N]
```

No `--table` flag needed (unlike SMP which has queues/messages/all) — XFTP has a single entity type (files + recipients, always migrated together).

CLI options reuse `dbOptsP` parser from `Simplex.Messaging.Server.CLI`.

### Import (StoreLog -> PostgreSQL)

1. Confirm: prompt user with database connection details and StoreLog path
2. Read and replay StoreLog into temporary `STMFileStore`
3. Connect to PostgreSQL, run schema migrations (`createSchema = True`, `confirmMigrations = MCYesUp`)
4. Batch-insert file records into `files` table using PostgreSQL COPY protocol (matching SMP's `batchInsertQueues` pattern for performance). Progress reported every 10k files.
5. Batch-insert recipient records into `recipients` table using COPY protocol
6. Verify counts: `SELECT COUNT(*) FROM files` / `recipients` — warn if mismatch
7. Rename StoreLog to `.bak` (prevents accidental re-import, preserves original for rollback)
8. Report counts

### Export (PostgreSQL -> StoreLog)

1. Confirm: prompt user with database connection details and output path. Fail if output file already exists.
2. Connect to PostgreSQL
3. Open new StoreLog file for writing
4. Fold over all file records, writing per file (in this order, matching existing `writeFileStore`): `AddFile` (with `ServerEntityStatus` — this preserves `EntityBlocked` state), `AddRecipients`, then `PutFile` (if `file_path` is set)
5. Report counts

Note: `AddFile` carries `ServerEntityStatus` which includes `EntityBlocked info`, so blocking state is preserved through export/import without needing separate `BlockFile` log entries.

File data on disk is untouched by migration — only metadata moves between backends.

## Cabal Integration

Shared `server_postgres` flag. New Postgres modules added to existing conditional block:

```cabal
if flag(server_postgres)
  cpp-options: -DdbServerPostgres
  exposed-modules:
    ...existing SMP modules...
    Simplex.FileTransfer.Server.Store.Postgres
    Simplex.FileTransfer.Server.Store.Postgres.Migrations
    Simplex.FileTransfer.Server.Store.Postgres.Config
```

CPP guards (`#if defined(dbServerPostgres)`) in:
- `Store.hs` — Postgres `FromField`/`ToField` instances for XFTP-specific types if needed
- `Env.hs` — `XSCDatabase` constructor
- `Main.hs` — database CLI commands, store selection for `database` mode, Postgres imports
- `Server.hs` — Postgres-specific imports if needed

## Testing

- **Parameterized server tests**: Existing `xftpServerTests` refactored to accept a store type parameter (following SMP's `SpecWith (ASrvTransport, AStoreType)` pattern). The same server tests run against both STM and Postgres backends — STM tests run unconditionally, Postgres tests added under `#if defined(dbServerPostgres)` with `postgressBracket` for database lifecycle (drop → create → test → drop).
- **Unit tests**: `PostgresFileStore` operations — add/get/delete/block/expire, duplicate detection, auth errors
- **Migration round-trip**: STM store → export to StoreLog → import to Postgres → export back → verify StoreLog equality (including blocked file status)
- **Tests location**: in `tests/` alongside existing XFTP tests, guarded by `server_postgres` CPP flag
- **Test database**: PostgreSQL on `localhost:5432`, using a dedicated `xftp_server_test` schema (dropped and recreated per test run via `postgressBracket`, following SMP's test database lifecycle pattern)
- **Test fixtures**: `testXFTPStoreDBOpts :: DBOpts` with `createSchema = True`, `confirmMigrations = MCYesUp`, in `tests/XFTPClient.hs`
