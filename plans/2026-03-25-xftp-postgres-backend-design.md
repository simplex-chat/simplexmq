# XFTP Server PostgreSQL Backend

## Overview

Add PostgreSQL backend support to xftp-server, following the SMP server pattern. Supports bidirectional migration between STM (in-memory with StoreLog) and PostgreSQL backends.

## Goals

- PostgreSQL-backed file metadata storage as an alternative to STM + StoreLog
- Polymorphic server code via `FileStoreClass` typeclass with associated `StoreMonad` (following `MsgStoreClass` pattern)
- Bidirectional migration: StoreLog <-> PostgreSQL via CLI commands
- Shared `server_postgres` cabal flag (same flag enables both SMP and XFTP Postgres support)
- INI-based backend selection at runtime

## Non-Goals

- Hybrid mode (STM caching + Postgres persistence as a distinct user-facing mode)
- Soft deletion / `deletedTTL` (XFTP uses random IDs with no reuse concern)
- Storing file data in PostgreSQL (files remain on disk)
- Separate cabal flag for XFTP Postgres

## Architecture

### FileStoreClass Typeclass

Polymorphic over `StoreMonad`, following the `MsgStoreClass` pattern with injective type family:

```haskell
class FileStoreClass s where
  type StoreMonad s = (m :: Type -> Type) | m -> s
  type FileStoreConfig s :: Type

  -- Lifecycle
  newFileStore :: FileStoreConfig s -> IO s
  closeFileStore :: s -> IO ()

  -- File operations
  addFile :: s -> SenderId -> FileInfo -> RoundedFileTime -> ServerEntityStatus -> StoreMonad s (Either XFTPErrorType ())
  setFilePath :: s -> SenderId -> FilePath -> StoreMonad s (Either XFTPErrorType ())
  addRecipient :: s -> SenderId -> FileRecipient -> StoreMonad s (Either XFTPErrorType ())
  getFile :: s -> SFileParty p -> XFTPFileId -> StoreMonad s (Either XFTPErrorType (FileRec, C.APublicAuthKey))
  deleteFile :: s -> SenderId -> StoreMonad s (Either XFTPErrorType ())
  blockFile :: s -> SenderId -> BlockingInfo -> Bool -> StoreMonad s (Either XFTPErrorType ())
  deleteRecipient :: s -> RecipientId -> FileRec -> StoreMonad s ()
  ackFile :: s -> RecipientId -> StoreMonad s (Either XFTPErrorType ())

  -- Expiration
  expiredFiles :: s -> Int64 -> StoreMonad s [(SenderId, Maybe FilePath, Word32)]

  -- Storage and stats (for init-time computation)
  getUsedStorage :: s -> IO Int64
  getFileCount :: s -> IO Int
```

- STM backend: `StoreMonad s ~ STM`
- Postgres backend: `StoreMonad s ~ DBStoreIO` (i.e., `ReaderT DBTransaction IO`)

Store operations executed via a runner: `atomically` for STM, `withTransaction` for Postgres.

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
- **Postgres backend**: `getFile` reads from DB and creates a `FileRec` with fresh TVars populated from the DB row. Typeclass mutation methods (`setFilePath`, `blockFile`, etc.) update both the DB (persistence) and the TVars (in-session consistency). The `recipientIds` set is populated from a subquery on the `recipients` table.

### usedStorage Ownership

`usedStorage :: TVar Int64` moves from the store to `XFTPEnv`. The store typeclass does **not** manage `usedStorage` — it only provides `getUsedStorage` for init-time computation.

- **STM init**: StoreLog replay calls `setFilePath` (which only sets the filePath TVar — the STM `setFilePath` implementation is changed to **not** update `usedStorage`). After replay, `getUsedStorage` computes the sum over all file sizes (matching current `countUsedStorage` behavior).
- **Postgres init**: `getUsedStorage` executes `SELECT COALESCE(SUM(file_size), 0) FROM files`.
- **Runtime**: Server manages `usedStorage` TVar directly for reserve/commit/rollback during uploads, and adjusts after `deleteFile`/`blockFile` calls.

**Note on `getUsedStorage` semantics**: The current STM `countUsedStorage` sums all file sizes unconditionally (including files without `filePath` set, i.e., created but not yet uploaded). The Postgres `getUsedStorage` matches this: `SELECT SUM(file_size) FROM files` (no `WHERE file_path IS NOT NULL`). In practice, orphaned files (created but never uploaded) are rare and short-lived (expired within 48h), so the difference is negligible. A future improvement could filter by `file_path IS NOT NULL` in both backends to reflect actual disk usage more accurately.

### Server.hs Refactoring

`Server.hs` becomes polymorphic over `FileStoreClass s`. A `runStore` helper dispatches `StoreMonad` execution (`atomically` for STM, `withTransaction` for Postgres).

**Call sites requiring changes** (exhaustive list):

1. **`receiveServerFile`** (line 563): `atomically $ writeTVar filePath (Just fPath)` → `runStore $ setFilePath store senderId fPath`. The `reserve` logic (line 551-555) stays as direct TVar manipulation on `usedStorage` from `XFTPEnv`.

2. **`verifyXFTPTransmission`** (line 453): `atomically $ verify =<< getFile st party fId` — the `getFile` call and subsequent `readTVar fileStatus` are in a single `atomically` block. Refactored to: `runStore $ getFile st party fId`, then read `fileStatus` from the returned `FileRec`'s TVar (safe for both backends — STM TVar is the source of truth, Postgres TVar is a fresh snapshot from DB).

3. **`retryAdd`** (line 516): Signature `XFTPFileId -> STM (Either XFTPErrorType a)` → `XFTPFileId -> StoreMonad s (Either XFTPErrorType a)`. The `atomically` call (line 520) replaced with `runStore`.

4. **`deleteOrBlockServerFile_`** (line 620): Parameter `FileStore -> STM (Either XFTPErrorType ())` → `FileStoreClass s => s -> StoreMonad s (Either XFTPErrorType ())`. The `atomically` call (line 626) replaced with `runStore`. After the store action, server adjusts `usedStorage` TVar in `XFTPEnv` based on `fileInfo.size`.

5. **`ackFileReception`** (line 601): `atomically $ deleteRecipient st rId fr` → `runStore $ deleteRecipient st rId fr`.

6. **Control port `CPDelete`/`CPBlock`** (lines 371, 377): `atomically $ getFile fs SFRecipient fileId` → `runStore $ getFile fs SFRecipient fileId`.

7. **`expireServerFiles`** (line 636): Replace per-file `expiredFilePath` iteration with bulk `runStore $ expiredFiles st old`, which returns `[(SenderId, Maybe FilePath, Word32)]` — the `Word32` file size is needed so the server can adjust the `usedStorage` TVar after each deletion. The `itemDelay` between files applies to the deletion loop over the returned list, not the store query itself.

8. **`restoreServerStats`** (line 694): `FileStore {files, usedStorage} <- asks store` accesses store fields directly. Refactored to: `usedStorage` from `XFTPEnv` via `asks usedStorage`, file count via `getFileCount store` (new typeclass method). STM: `M.size <$> readTVarIO files`. Postgres: `SELECT COUNT(*) FROM files`.

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
- `sender_key` and `recipient_key` stored as `BYTEA` using `StrEncoding` serialization (includes type tag for `APublicAuthKey` algebraic type — Ed25519 or X25519 variant)
- `file_path` nullable (set after upload completes via `setFilePath`)
- `ON DELETE CASCADE` for recipients when file is hard-deleted
- `created_at` stores rounded epoch seconds (1-hour precision, `RoundedFileTime`)
- `status` as TEXT via `StrEncoding` (`ServerEntityStatus`: `EntityActive`, `EntityBlocked info`, `EntityOff`)
- Hard deletes (no `deleted_at` column)
- No PL/pgSQL functions needed; row-level locking via `SELECT ... FOR UPDATE` on `setFilePath` to prevent duplicate uploads
- `used_storage` computed on startup: `SELECT COALESCE(SUM(file_size), 0) FROM files` (matches STM `countUsedStorage` — all files, see usedStorage Ownership section)

### Postgres Operations

Key query patterns:

- **`addFile`**: `INSERT INTO files (...) VALUES (...)`, return `DUPLICATE_` on unique violation.
- **`setFilePath`**: `UPDATE files SET file_path = ? WHERE sender_id = ? AND file_path IS NULL`, `FOR UPDATE` row lock. Only persists the path; `usedStorage` managed by server.
- **`addRecipient`**: `INSERT INTO recipients (...)`, plus check for duplicates. No need for `recipientIds` TVar update — Postgres derives it from the table.
- **`getFile`** (sender): `SELECT ... FROM files WHERE sender_id = ?`, returns auth key from `sender_key` column.
- **`getFile`** (recipient): `SELECT f.*, r.recipient_key FROM recipients r JOIN files f ON ... WHERE r.recipient_id = ?`.
- **`deleteFile`**: `DELETE FROM files WHERE sender_id = ?` (recipients cascade).
- **`blockFile`**: `UPDATE files SET status = ? WHERE sender_id = ?`, optionally with file path clearing when `deleted = True`.
- **`expiredFiles`**: `SELECT sender_id, file_path, file_size FROM files WHERE created_at + ? < ?` — single query replaces per-file iteration, includes `file_size` for `usedStorage` adjustment.

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
xftp-server database import files [--database DB_CONN] [--schema DB_SCHEMA] [--pool-size N]
xftp-server database export files [--database DB_CONN] [--schema DB_SCHEMA] [--pool-size N]
```

CLI options reuse `dbOptsP` parser from `Simplex.Messaging.Server.CLI`.

### Import (StoreLog -> PostgreSQL)

1. Read and replay StoreLog into temporary `STMFileStore`
2. Connect to PostgreSQL, run schema migrations
3. Batch-insert file records into `files` table
4. Batch-insert recipient records into `recipients` table
5. Report counts

### Export (PostgreSQL -> StoreLog)

1. Connect to PostgreSQL
2. Open new StoreLog file for writing
3. Fold over all file records, writing per file (in this order, matching existing `writeFileStore`): `AddFile` (with `ServerEntityStatus` — this preserves `EntityBlocked` state), `AddRecipients`, then `PutFile` (if `file_path` is set)
4. Report counts

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

- **Unit tests**: `PostgresFileStore` operations — add/get/delete/block/expire, duplicate detection, auth errors
- **Migration round-trip**: STM store → export to StoreLog → import to Postgres → export back → verify equality (including blocked file status)
- **Integration test**: run xftp-server with Postgres backend, perform file upload/download/delete cycle
- **Tests location**: in `tests/` alongside existing XFTP tests, guarded by `server_postgres` CPP flag
- **Test database**: PostgreSQL on `localhost:5432`, using a dedicated `xftp_server_test` schema (dropped and recreated per test run, following `xftp-web` test cleanup pattern)
