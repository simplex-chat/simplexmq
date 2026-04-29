# XFTP PostgreSQL Backend — Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers-extended-cc:subagent-driven-development (if subagents available) or superpowers-extended-cc:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add PostgreSQL backend support to xftp-server as an alternative to STM + StoreLog, with bidirectional migration.

**Architecture:** Introduce `FileStoreClass` typeclass (IO-based, following `QueueStoreClass` pattern). Extract current STM store into `Store/STM.hs`, make `Server.hs` polymorphic, then add `Store/Postgres.hs` behind `server_postgres` CPP flag. `usedStorage` moves from store to `XFTPEnv` so the server manages quota tracking externally.

**Tech Stack:** Haskell, postgresql-simple, STM, fourmolu, cabal with CPP flags

**Design spec:** `plans/2026-03-25-xftp-postgres-backend-design.md`

---

## File Structure

**Existing files modified:**
- `src/Simplex/FileTransfer/Server/Store.hs` — rewritten: becomes typeclass + shared types
- `src/Simplex/FileTransfer/Server/Env.hs` — polymorphic `XFTPEnv s`, `XFTPStoreConfig` GADT
- `src/Simplex/FileTransfer/Server.hs` — polymorphic over `FileStoreClass s`
- `src/Simplex/FileTransfer/Server/StoreLog.hs` — update for IO store functions
- `src/Simplex/FileTransfer/Server/Main.hs` — INI config, dispatch, CLI commands
- `simplexmq.cabal` — new modules
- `tests/XFTPClient.hs` — Postgres test fixtures
- `tests/Test.hs` — Postgres test group

**New files created:**
- `src/Simplex/FileTransfer/Server/Store/STM.hs` — `STMFileStore` (extracted from current `Store.hs`)
- `src/Simplex/FileTransfer/Server/Store/Postgres.hs` — `PostgresFileStore` [CPP-guarded]
- `src/Simplex/FileTransfer/Server/Store/Postgres/Config.hs` — `PostgresFileStoreCfg` [CPP-guarded]
- `src/Simplex/FileTransfer/Server/Store/Postgres/Migrations.hs` — schema SQL [CPP-guarded]
- `tests/CoreTests/XFTPStoreTests.hs` — Postgres store unit tests [CPP-guarded]

---

## Task 1: Move `usedStorage` from `FileStore` to `XFTPEnv`

**Files:**
- Modify: `src/Simplex/FileTransfer/Server/Store.hs`
- Modify: `src/Simplex/FileTransfer/Server/Env.hs`
- Modify: `src/Simplex/FileTransfer/Server.hs`

- [ ] **Step 1: Remove `usedStorage` from `FileStore` in `Store.hs`**

  1. Remove `usedStorage :: TVar Int64` field from `FileStore` record (line 47).
  2. Remove `usedStorage <- newTVarIO 0` from `newFileStore` (line 75) and drop the field from the record construction (line 76).
  3. In `setFilePath` (line 92-97): remove `modifyTVar' (usedStorage st) (+ fromIntegral (size fileInfo))` — keep only `writeTVar filePath (Just fPath)`. Change pattern from `\FileRec {fileInfo, filePath}` to `\FileRec {filePath}` (fileInfo is now unused — `-Wunused-matches` error).
  4. In `deleteFile` (line 112-119): remove `modifyTVar' usedStorage $ subtract (fromIntegral $ size fileInfo)`. Change outer pattern match from `FileStore {files, recipients, usedStorage}` to `FileStore {files, recipients}`. Change inner pattern from `Just FileRec {fileInfo, recipientIds}` to `Just FileRec {recipientIds}` (`fileInfo` is now unused — `-Wunused-matches` error).
  5. In `blockFile` (line 122-127): remove `when deleted $ modifyTVar' usedStorage $ subtract (fromIntegral $ size fileInfo)`. Change pattern match from `st@FileStore {usedStorage}` to `st`. The `deleted` parameter and `fileInfo` in the inner pattern become unused — prefix with `_` or remove from pattern to avoid `-Wunused-matches`.

- [ ] **Step 2: Add `usedStorage` to `XFTPEnv` in `Env.hs`**

  1. Add `usedStorage :: TVar Int64` field to `XFTPEnv` record (between `store` and `storeLog`, line 93).
  2. In `newXFTPServerEnv` (line 112-126): replace lines 117-118:
     ```
     used <- countUsedStorage <$> readTVarIO (files store)
     atomically $ writeTVar (usedStorage store) used
     ```
     with:
     ```
     usedStorage <- newTVarIO =<< countUsedStorage <$> readTVarIO (files store)
     ```
  3. Add `usedStorage` to the `pure XFTPEnv {..}` construction.

- [ ] **Step 3: Update all `usedStorage` access sites in `Server.hs`**

  1. Line 552: `us <- asks $ usedStorage . store` → `us <- asks usedStorage`.
  2. Line 569: `us <- asks $ usedStorage . store` → `us <- asks usedStorage`.
  3. Line 639: `usedStart <- readTVarIO $ usedStorage st` → `usedStart <- readTVarIO =<< asks usedStorage`.
  4. Line 647: `usedEnd <- readTVarIO $ usedStorage st` → `usedEnd <- readTVarIO =<< asks usedStorage`.
  5. Line 694: `FileStore {files, usedStorage} <- asks store` → split into `FileStore {files} <- asks store` and `usedStorage <- asks usedStorage`.
  6. In `deleteOrBlockServerFile_` (line 620): after `void $ atomically $ storeAction st`, add usedStorage adjustment — `us <- asks usedStorage` then `atomically $ modifyTVar' us $ subtract (fromIntegral $ size fileInfo)` when file had a path (check `path` from `readTVarIO filePath` earlier in the function).

- [ ] **Step 4: Build and verify**

  Run: `cabal build`

- [ ] **Step 5: Run existing tests**

  Run: `cabal test --test-show-details=streaming --test-option=--match="/XFTP/"`

- [ ] **Step 6: Format and commit**

  ```bash
  fourmolu -i src/Simplex/FileTransfer/Server/Store.hs src/Simplex/FileTransfer/Server/Env.hs src/Simplex/FileTransfer/Server.hs
  git add src/Simplex/FileTransfer/Server/Store.hs src/Simplex/FileTransfer/Server/Env.hs src/Simplex/FileTransfer/Server.hs
  git commit -m "refactor(xftp): move usedStorage from FileStore to XFTPEnv"
  ```

---

## Task 2: Add `getUsedStorage`, `getFileCount`, `expiredFiles` functions

**Files:**
- Modify: `src/Simplex/FileTransfer/Server/Store.hs`
- Modify: `src/Simplex/FileTransfer/Server/Env.hs`
- Modify: `src/Simplex/FileTransfer/Server.hs`

- [ ] **Step 1: Add three new functions to `Store.hs`**

  1. Add to exports: `getUsedStorage`, `getFileCount`, `expiredFiles`.
  2. Remove `expiredFilePath` from exports AND delete the function definition (dead code → `-Wunused-binds` error). Also remove `($>>=)` from import `Simplex.Messaging.Util (ifM, ($>>=))` → `Simplex.Messaging.Util (ifM)` — `$>>=` was only used by `expiredFilePath`.
  3. Add import: `qualified Data.Map.Strict as M` (needed for `M.foldl'` in `getUsedStorage` and `M.toList` in `expiredFiles`).
  4. Implement:
     ```haskell
     getUsedStorage :: FileStore -> IO Int64
     getUsedStorage FileStore {files} =
       M.foldl' (\acc FileRec {fileInfo = FileInfo {size}} -> acc + fromIntegral size) 0 <$> readTVarIO files

     getFileCount :: FileStore -> IO Int
     getFileCount FileStore {files} = M.size <$> readTVarIO files

     expiredFiles :: FileStore -> Int64 -> Int -> IO [(SenderId, Maybe FilePath, Word32)]
     expiredFiles FileStore {files} old _limit = do
       fs <- readTVarIO files
       fmap catMaybes . forM (M.toList fs) $ \(sId, FileRec {fileInfo = FileInfo {size}, filePath, createdAt = RoundedSystemTime createdAt}) ->
         if createdAt + fileTimePrecision < old
           then do
             path <- readTVarIO filePath
             pure $ Just (sId, path, size)
           else pure Nothing
     ```
  5. Add imports: `Data.Maybe (catMaybes)`, `Data.Word (Word32)` (note: `qualified Data.Map.Strict as M` already added in item 3).

- [ ] **Step 2: Replace `countUsedStorage` in `Env.hs`**

  1. Replace `countUsedStorage <$> readTVarIO (files store)` with `getUsedStorage store` in `newXFTPServerEnv`.
  2. Remove `countUsedStorage` function definition and its export.
  3. Remove `qualified Data.Map.Strict as M` import if no longer used.

- [ ] **Step 3: Update `restoreServerStats` in `Server.hs` to use `getFileCount`**

  In `restoreServerStats` (line 694-696): replace `FileStore {files} <- asks store` and `_filesCount <- M.size <$> readTVarIO files` with `st <- asks store` and `_filesCount <- liftIO $ getFileCount st` (eliminates the `FileStore` pattern match — `files` binding no longer needed).

- [ ] **Step 4: Replace `expireServerFiles` iteration in `Server.hs`**

  1. Replace the body of `expireServerFiles` (lines 636-660). Remove `files' <- readTVarIO (files st)` and the `forM_ (M.keys files')` loop.
  2. New body: call `expiredFiles st old 10000` in a loop. For each `(sId, filePath_, fileSize)` in returned list: apply `itemDelay`, remove disk file if present, call `atomically $ deleteFile st sId`, adjust `usedStorage` TVar by `fileSize`, increment `filesExpired` stat. Loop until `expiredFiles` returns `[]`.
  3. Remove `Data.Map.Strict` import from Server.hs if no longer needed (was used for `M.size` and `M.keys` — now replaced by `getFileCount` and `expiredFiles`).

- [ ] **Step 5: Build and verify**

  Run: `cabal build`

- [ ] **Step 6: Run existing tests**

  Run: `cabal test --test-show-details=streaming --test-option=--match="/XFTP/"`

- [ ] **Step 7: Format and commit**

  ```bash
  fourmolu -i src/Simplex/FileTransfer/Server/Store.hs src/Simplex/FileTransfer/Server/Env.hs src/Simplex/FileTransfer/Server.hs
  git add src/Simplex/FileTransfer/Server/Store.hs src/Simplex/FileTransfer/Server/Env.hs src/Simplex/FileTransfer/Server.hs
  git commit -m "refactor(xftp): add getUsedStorage, getFileCount, expiredFiles store functions"
  ```

---

## Task 3: Change `Store.hs` functions from STM to IO

**Files:**
- Modify: `src/Simplex/FileTransfer/Server/Store.hs`
- Modify: `src/Simplex/FileTransfer/Server.hs`
- Modify: `src/Simplex/FileTransfer/Server/StoreLog.hs`

- [ ] **Step 1: Change all Store.hs function signatures from STM to IO**

  For each of: `addFile`, `setFilePath`, `addRecipient`, `getFile`, `deleteFile`, `blockFile`, `deleteRecipient`, `ackFile`:
  1. Change return type from `STM (Either XFTPErrorType ...)` to `IO (Either XFTPErrorType ...)` (or `STM ()` to `IO ()` for `deleteRecipient`).
  2. Wrap the function body in `atomically $ do ...`.
  3. Keep `withFile` and `newFileRec` as internal STM helpers (called inside the `atomically` blocks).

- [ ] **Step 2: Update Server.hs call sites — remove `atomically` wrappers**

  1. Line 563 (`receiveServerFile`): change `atomically $ writeTVar filePath (Just fPath)` → add `st <- asks store` then `void $ liftIO $ setFilePath st senderId fPath` (design call site #1 — `store` is not in scope in `receiveServerFile`'s `receive` helper, so bind via `asks`; `void` avoids `-Wunused-do-bind` warning on the `Either` result).
  2. Line 453 (`verifyXFTPTransmission`): split `atomically $ verify =<< getFile st party fId` into: `liftIO (getFile st party fId)` (IO→M lift), then pattern match on result, use `readTVarIO (fileStatus fr)` instead of `readTVar`.
  3. Lines 371, 377 (control port `CPDelete`/`CPBlock`): change `ExceptT $ atomically $ getFile fs SFRecipient fileId` → `ExceptT $ liftIO $ getFile fs SFRecipient fileId` (inside `unliftIO u $ do` block which runs in M monad — `liftIO` required to lift IO into M).
  4. Line 508 (`addFile` in `createFile`): the `ExceptT $ addFile st sId file ts EntityActive` — `addFile` is now IO, `ExceptT` wraps IO directly. Remove any `atomically`.
  5. Line 514 (`addRecipient`): same — `ExceptT . addRecipient st sId` works directly in IO.
  6. Line 516 (`retryAdd`): change parameter type from `(XFTPFileId -> STM (Either XFTPErrorType a))` to `(XFTPFileId -> IO (Either XFTPErrorType a))`. Line 520: change `atomically (add fId)` to `liftIO (add fId)`.
  7. Line 605 (`ackFileReception`): change `atomically $ deleteRecipient st rId fr` to `liftIO $ deleteRecipient st rId fr`.
  8. Line 620 (`deleteOrBlockServerFile_`): change third parameter type from `(FileStore -> STM (Either XFTPErrorType ()))` to `(FileStore -> IO (Either XFTPErrorType ()))`. Line 626: change `void $ atomically $ storeAction st` to `void $ liftIO $ storeAction st`.
  9. `expireServerFiles` `delete` helper: change `atomically $ deleteFile st sId` to `liftIO $ deleteFile st sId` (deleteFile is now IO; `liftIO` required because the helper runs in M monad, not IO).

- [ ] **Step 3: Update `StoreLog.hs` — remove `atomically` from replay**

  In `readFileStore` (line 93), function `addToStore`:
  1. Change `atomically (addToStore lr)` to `addToStore lr` — store functions are now IO.
  2. The `addToStore` body calls `addFile`, `setFilePath`, `deleteFile`, `blockFile`, `ackFile` — all IO now, no `atomically` needed.
  3. For `AddRecipients`: `runExceptT $ mapM_ (ExceptT . addRecipient st sId) rcps` — `addRecipient` returns `IO (Either ...)`, so `ExceptT . addRecipient st sId` works directly.

- [ ] **Step 4: Build and verify**

  Run: `cabal build`

- [ ] **Step 5: Run existing tests**

  Run: `cabal test --test-show-details=streaming --test-option=--match="/XFTP/"`

- [ ] **Step 6: Format and commit**

  ```bash
  fourmolu -i src/Simplex/FileTransfer/Server/Store.hs src/Simplex/FileTransfer/Server.hs src/Simplex/FileTransfer/Server/StoreLog.hs
  git add src/Simplex/FileTransfer/Server/Store.hs src/Simplex/FileTransfer/Server.hs src/Simplex/FileTransfer/Server/StoreLog.hs
  git commit -m "refactor(xftp): change file store operations from STM to IO"
  ```

---

## Task 4: Extract `FileStoreClass` typeclass, move STM impl to `Store/STM.hs`

**Files:**
- Rewrite: `src/Simplex/FileTransfer/Server/Store.hs`
- Create: `src/Simplex/FileTransfer/Server/Store/STM.hs`
- Modify: `src/Simplex/FileTransfer/Server/StoreLog.hs`
- Modify: `src/Simplex/FileTransfer/Server/Env.hs`
- Modify: `src/Simplex/FileTransfer/Server.hs`
- Modify: `simplexmq.cabal`

- [ ] **Step 1: Create `Store/STM.hs` — move all implementation code**

  1. Create directory `src/Simplex/FileTransfer/Server/Store/`.
  2. Create `src/Simplex/FileTransfer/Server/Store/STM.hs`.
  3. Move from `Store.hs`: `FileStore` data type (rename to `STMFileStore`), all function implementations, internal helpers (`withFile`, `newFileRec`), all STM-specific imports.
  4. Rename all `FileStore` references to `STMFileStore` in the new file.
  5. Module declaration: `module Simplex.FileTransfer.Server.Store.STM` exporting only `STMFileStore (..)` — do NOT export standalone functions (`addFile`, `setFilePath`, etc.) to avoid name collisions with the typeclass methods from `Store.hs`.

- [ ] **Step 2: Rewrite `Store.hs` as the typeclass module**

  1. Add `{-# LANGUAGE TypeFamilies #-}` pragma to `Store.hs` (required for `type FileStoreConfig s` associated type).
  2. Keep in `Store.hs`: `FileRec (..)`, `FileRecipient (..)`, `RoundedFileTime`, `fileTimePrecision` definitions and their `StrEncoding` instance.
  3. Add `FileStoreClass` typeclass:
     ```haskell
     class FileStoreClass s where
       type FileStoreConfig s

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

       -- Expiration
       expiredFiles :: s -> Int64 -> Int -> IO [(SenderId, Maybe FilePath, Word32)]

       -- Stats
       getUsedStorage :: s -> IO Int64
       getFileCount :: s -> IO Int
     ```
  4. Do NOT re-export from `Store/STM.hs` — this would create a circular module dependency (Store.hs imports Store/STM.hs, Store/STM.hs imports Store.hs). Consumers must import `Store.STM` directly where they need `STMFileStore`.
  5. Remove all STM-specific imports that are no longer needed.

- [ ] **Step 3: Add `FileStoreClass` instance in `Store/STM.hs`**

  1. Import `FileStoreClass` from `Simplex.FileTransfer.Server.Store`.
  2. Inline all implementations directly in the instance body (do NOT delegate to standalone functions — the standalone names collide with typeclass method names, causing ambiguous occurrences for importers):
     ```haskell
     instance FileStoreClass STMFileStore where
       type FileStoreConfig STMFileStore = ()
       newFileStore () = do
         files <- TM.emptyIO
         recipients <- TM.emptyIO
         pure STMFileStore {files, recipients}
       closeFileStore _ = pure ()
       addFile st sId fileInfo createdAt status = atomically $ ...
       setFilePath st sId fPath = atomically $ ...
       -- ... (each method's body is the existing function body, inlined)
     ```
  3. Remove the standalone top-level function definitions — they are now instance methods. Keep only `withFile` and `newFileRec` as internal helpers used by the instance methods.

- [ ] **Step 4: Update importers**

  1. `Env.hs`: add `import Simplex.FileTransfer.Server.Store.STM (STMFileStore (..))`. Change `FileStore` → `STMFileStore` in `XFTPEnv` type and `newXFTPServerEnv`. Change `store <- newFileStore` to `store <- newFileStore ()` (typeclass method now takes `FileStoreConfig STMFileStore` which is `()`). Keep `import Simplex.FileTransfer.Server.Store` for `FileRec`, `FileRecipient`, `FileStoreClass`, etc.
  2. `Server.hs`: add `import Simplex.FileTransfer.Server.Store.STM`. Change `FileStore` → `STMFileStore` in any explicit type annotations. Import `FileStoreClass` from `Simplex.FileTransfer.Server.Store`.
  3. `StoreLog.hs`: add `import Simplex.FileTransfer.Server.Store.STM` to access concrete `STMFileStore` type and store functions used during log replay. Change `FileStore` → `STMFileStore` in `readWriteFileStore` and `writeFileStore` parameter types.

- [ ] **Step 5: Update cabal file**

  Add `Simplex.FileTransfer.Server.Store.STM` to `exposed-modules` in the `!flag(client_library)` section, alongside existing XFTP server modules.

- [ ] **Step 6: Build and verify**

  Run: `cabal build`

- [ ] **Step 7: Run existing tests**

  Run: `cabal test --test-show-details=streaming --test-option=--match="/XFTP/"`

- [ ] **Step 8: Format and commit**

  ```bash
  fourmolu -i src/Simplex/FileTransfer/Server/Store.hs src/Simplex/FileTransfer/Server/Store/STM.hs src/Simplex/FileTransfer/Server/Env.hs src/Simplex/FileTransfer/Server.hs src/Simplex/FileTransfer/Server/StoreLog.hs
  git add src/Simplex/FileTransfer/Server/Store.hs src/Simplex/FileTransfer/Server/Store/STM.hs src/Simplex/FileTransfer/Server/Env.hs src/Simplex/FileTransfer/Server.hs src/Simplex/FileTransfer/Server/StoreLog.hs simplexmq.cabal
  git commit -m "refactor(xftp): extract FileStoreClass typeclass, move STM impl to Store.STM"
  ```

---

## Task 5: Make `XFTPEnv` and `Server.hs` polymorphic over `FileStoreClass`

**Files:**
- Modify: `src/Simplex/FileTransfer/Server/Env.hs`
- Modify: `src/Simplex/FileTransfer/Server.hs`
- Modify: `src/Simplex/FileTransfer/Server/Main.hs`
- Modify: `tests/XFTPClient.hs` (if it calls `runXFTPServerBlocking` directly)

- [ ] **Step 1: Make `XFTPEnv` polymorphic in `Env.hs`**

  1. Add `XFTPStoreConfig` GADT: `data XFTPStoreConfig s where XSCMemory :: Maybe FilePath -> XFTPStoreConfig STMFileStore`.
  2. Change `data XFTPEnv` to `data XFTPEnv s` — field `store :: FileStore` becomes `store :: s`.
  3. Change `newXFTPServerEnv :: XFTPServerConfig -> IO XFTPEnv` to `newXFTPServerEnv :: FileStoreClass s => XFTPStoreConfig s -> XFTPServerConfig -> IO (XFTPEnv s)`.
  4. Pattern match on `XSCMemory storeLogPath` in `newXFTPServerEnv` body. Create store via `newFileStore ()`, storeLog via `mapM (`readWriteFileStore` st) storeLogPath`.

- [ ] **Step 2: Make `Server.hs` polymorphic**

  1. Change `type M a = ReaderT XFTPEnv IO a` to `type M s a = ReaderT (XFTPEnv s) IO a`.
  2. Add `FileStoreClass s =>` constraint to all functions using `M s a`. Use `forall s.` in signatures of functions that have `where`-block bindings with `M s` type annotations — `ScopedTypeVariables` requires explicit `forall` to bring `s` into scope for inner type signatures (matching SMP's `smpServer :: forall s. MsgStoreClass s => ...` pattern). Full list: `xftpServer`, `processRequest`, `verifyXFTPTransmission`, `processXFTPRequest` and all its `where`-bound functions (`createFile`, `addRecipients`, `receiveServerFile`, `sendServerFile`, `deleteServerFile`, `ackFileReception`, `retryAdd`, `addFileRetry`, `addRecipientRetry`), `deleteServerFile_`, `blockServerFile`, `deleteOrBlockServerFile_`, `expireServerFiles`, `randomId`, `getFileId`, `withFileLog`, `incFileStat`, `saveServerStats`, `restoreServerStats`, `randomDelay` (inside `#ifdef slow_servers` CPP block). Also update `encodeXftp` (line 236) and `runCPClient` (line 339) which use explicit `ReaderT XFTPEnv IO` instead of the `M` alias — change to `ReaderT (XFTPEnv s) IO`.
  3. Change `runXFTPServerBlocking` and `runXFTPServer` to take `XFTPStoreConfig s` parameter.
  4. Add `closeFileStore store` call to the server shutdown path (in the `finally` block or `stopServer` equivalent — after saving stats, before logging "Server stopped"). This ensures Postgres connection pool and `dbStoreLog` are properly closed. For STM this is a no-op.

- [ ] **Step 3: Update `Main.hs` dispatch**

  1. In `runServer`: construct `XSCMemory (enableStoreLog $> storeLogFilePath)`.
  2. Add dispatch function that calls the updated `runXFTPServer` (which creates `started` internally):
     ```haskell
     run :: FileStoreClass s => XFTPStoreConfig s -> IO ()
     run storeCfg = runXFTPServer storeCfg serverConfig
     ```
  3. Call `run` with the `XSCMemory` config.

- [ ] **Step 4: Update test helper if needed**

  If `tests/XFTPClient.hs` calls `runXFTPServerBlocking` directly, update the call to pass an `XSCMemory` config. Check the `withXFTPServer` / `serverBracket` helper.

- [ ] **Step 5: Build and verify**

  Run: `cabal build && cabal build test:simplexmq-test`

- [ ] **Step 6: Run existing tests**

  Run: `cabal test --test-show-details=streaming --test-option=--match="/XFTP/"`

- [ ] **Step 7: Format and commit**

  ```bash
  fourmolu -i src/Simplex/FileTransfer/Server/Env.hs src/Simplex/FileTransfer/Server.hs src/Simplex/FileTransfer/Server/Main.hs
  git add src/Simplex/FileTransfer/Server/Env.hs src/Simplex/FileTransfer/Server.hs src/Simplex/FileTransfer/Server/Main.hs tests/XFTPClient.hs simplexmq.cabal
  git commit -m "refactor(xftp): make XFTPEnv and server polymorphic over FileStoreClass"
  ```

---

## Task 6: Add Postgres config, migrations, and store skeleton

**Files:**
- Create: `src/Simplex/FileTransfer/Server/Store/Postgres/Config.hs`
- Create: `src/Simplex/FileTransfer/Server/Store/Postgres/Migrations.hs`
- Create: `src/Simplex/FileTransfer/Server/Store/Postgres.hs`
- Modify: `src/Simplex/FileTransfer/Server/Env.hs`
- Modify: `simplexmq.cabal`

- [ ] **Step 1: Create `Store/Postgres/Config.hs`**

  ```haskell
  module Simplex.FileTransfer.Server.Store.Postgres.Config
    ( PostgresFileStoreCfg (..),
      defaultXFTPDBOpts,
    )
  where

  import Simplex.Messaging.Agent.Store.Postgres.Options (DBOpts (..))
  import Simplex.Messaging.Agent.Store.Shared (MigrationConfirmation)

  data PostgresFileStoreCfg = PostgresFileStoreCfg
    { dbOpts :: DBOpts,
      dbStoreLogPath :: Maybe FilePath,
      confirmMigrations :: MigrationConfirmation
    }

  defaultXFTPDBOpts :: DBOpts
  defaultXFTPDBOpts =
    DBOpts
      { connstr = "postgresql://xftp@/xftp_server_store",
        schema = "xftp_server",
        poolSize = 10,
        createSchema = False
      }
  ```

- [ ] **Step 2: Create `Store/Postgres/Migrations.hs`**

  Full migration module with `xftpServerMigrations :: [Migration]` and `m20260325_initial` containing CREATE TABLE SQL for `files` and `recipients` tables plus indexes. Follow SMP's `QueueStore/Postgres/Migrations.hs` pattern exactly: tuple list → `sortOn name . map migration`.

- [ ] **Step 3: Create `Store/Postgres.hs` with stub instance**

  1. Define `PostgresFileStore` with `dbStore :: DBStore` and `dbStoreLog :: Maybe (StoreLog 'WriteMode)`.
  2. `instance FileStoreClass PostgresFileStore` with `error "not implemented"` for all methods except `newFileStore` (calls `createDBStore` + opens `dbStoreLog`) and `closeFileStore` (closes both). `type FileStoreConfig PostgresFileStore = PostgresFileStoreCfg`.
  3. Add `withDB`, `handleDuplicate`, `assertUpdated`, `withLog` helpers.

- [ ] **Step 4: Add `XSCDatabase` GADT constructor in `Env.hs` (CPP-guarded)**

  ```haskell
  #if defined(dbServerPostgres)
  import Simplex.FileTransfer.Server.Store.Postgres (PostgresFileStore)
  import Simplex.FileTransfer.Server.Store.Postgres.Config (PostgresFileStoreCfg)
  #endif

  data XFTPStoreConfig s where
    XSCMemory :: Maybe FilePath -> XFTPStoreConfig STMFileStore
  #if defined(dbServerPostgres)
    XSCDatabase :: PostgresFileStoreCfg -> XFTPStoreConfig PostgresFileStore
  #endif
  ```

- [ ] **Step 5: Update cabal**

  Add to existing `if flag(server_postgres)` block:
  ```
  Simplex.FileTransfer.Server.Store.Postgres
  Simplex.FileTransfer.Server.Store.Postgres.Config
  Simplex.FileTransfer.Server.Store.Postgres.Migrations
  ```

- [ ] **Step 6: Build both ways**

  Run: `cabal build && cabal build -fserver_postgres`

- [ ] **Step 7: Format and commit**

  ```bash
  fourmolu -i src/Simplex/FileTransfer/Server/Store/Postgres.hs src/Simplex/FileTransfer/Server/Store/Postgres/Config.hs src/Simplex/FileTransfer/Server/Env.hs
  git add src/Simplex/FileTransfer/Server/Store/Postgres.hs src/Simplex/FileTransfer/Server/Store/Postgres/Config.hs src/Simplex/FileTransfer/Server/Store/Postgres/Migrations.hs src/Simplex/FileTransfer/Server/Env.hs simplexmq.cabal
  git commit -m "feat(xftp): add PostgreSQL store skeleton with schema migration"
  ```

---

## Task 7: Implement `PostgresFileStore` operations

**Files:**
- Modify: `src/Simplex/FileTransfer/Server/Store/Postgres.hs`

- [ ] **Step 1: Implement `addFile`**

  `INSERT INTO files (sender_id, file_size, file_digest, sender_key, file_path, created_at, status) VALUES (?,?,?,?,NULL,?,?)`. Catch unique violation with `handleDuplicate` → `DUPLICATE_`. Call `withLog "addFile"` after.

- [ ] **Step 2: Implement `getFile`**

  For `SFSender`: `SELECT ... FROM files WHERE sender_id = ?`. Construct `FileRec` with `newTVarIO` per TVar field. `recipientIds = S.empty`.
  For `SFRecipient`: `SELECT f.*, r.recipient_key FROM recipients r JOIN files f ON r.sender_id = f.sender_id WHERE r.recipient_id = ?`.

- [ ] **Step 3: Implement `setFilePath`**

  `UPDATE files SET file_path = ? WHERE sender_id = ? AND file_path IS NULL`. Use `assertUpdated`. Call `withLog "setFilePath"`.

- [ ] **Step 4: Implement `addRecipient`**

  `INSERT INTO recipients (recipient_id, sender_id, recipient_key) VALUES (?,?,?)`. `handleDuplicate` → `DUPLICATE_`. Call `withLog "addRecipient"`.

- [ ] **Step 5: Implement `deleteFile`, `blockFile`**

  `deleteFile`: `DELETE FROM files WHERE sender_id = ?` (CASCADE). `withLog "deleteFile"`.
  `blockFile`: `UPDATE files SET status = ? WHERE sender_id = ?`. `assertUpdated`. `withLog "blockFile"`.

- [ ] **Step 6: Implement `deleteRecipient`, `ackFile`**

  `deleteRecipient`: `DELETE FROM recipients WHERE recipient_id = ?`. `withLog "deleteRecipient"`.
  `ackFile`: same + return `Left AUTH` if 0 rows.

- [ ] **Step 7: Implement `expiredFiles`, `getUsedStorage`, `getFileCount`**

  `expiredFiles`: `SELECT sender_id, file_path, file_size FROM files WHERE created_at + ? < ? LIMIT ?`.
  `getUsedStorage`: `SELECT COALESCE(SUM(file_size), 0) FROM files`.
  `getFileCount`: `SELECT COUNT(*) FROM files`.

- [ ] **Step 8: Add `ToField`/`FromField` instances**

  For `RoundedFileTime` (Int64 wrapper), `ServerEntityStatus` (Text via StrEncoding), `C.APublicAuthKey` (Binary via `encodePubKey`/`decodePubKey`). Check SMP's `QueueStore/Postgres.hs` for existing instances to import.

- [ ] **Step 9: Wrap mutation operations in `uninterruptibleMask_`**

  Operations that combine a DB write with a TVar update (e.g., `getFile` constructs `FileRec` with `newTVarIO`) must be wrapped in `E.uninterruptibleMask_` to prevent async exceptions from leaving inconsistent state. Follow SMP's `addQueue_`, `deleteStoreQueue` pattern.

- [ ] **Step 10: Build**

  Run: `cabal build -fserver_postgres`

- [ ] **Step 11: Format and commit**

  ```bash
  fourmolu -i src/Simplex/FileTransfer/Server/Store/Postgres.hs
  git add src/Simplex/FileTransfer/Server/Store/Postgres.hs
  git commit -m "feat(xftp): implement PostgresFileStore operations"
  ```

---

## Task 8: Add INI config, Main.hs dispatch, startup validation

**Files:**
- Modify: `src/Simplex/FileTransfer/Server/Main.hs`
- Modify: `src/Simplex/FileTransfer/Server/Env.hs`

- [ ] **Step 1: Update `iniFileContent` in `Main.hs`**

  Add to `[STORE_LOG]` section: `store_files: memory`, commented-out `db_connection`, `db_schema`, `db_pool_size`, `db_store_log` keys. Follow SMP's `optDisabled'` pattern for commented defaults.

- [ ] **Step 2: Add `StartOptions` and `--confirm-migrations` flag**

  ```haskell
  data StartOptions = StartOptions
    { confirmMigrations :: MigrationConfirmation
    }
  ```
  Add to `Start` command parser with default `MCConsole`. Thread through to `runServer`.

- [ ] **Step 3: Add store_files INI parsing and CPP-guarded Postgres dispatch**

  In `runServer`: read `store_files` from INI (`fromRight "memory" $ lookupValue "STORE_LOG" "store_files" ini`). Add `"database"` branch (CPP-guarded) that constructs `PostgresFileStoreCfg` using `iniDBOptions ini defaultXFTPDBOpts` and `enableDbStoreLog'` pattern. Non-postgres build: `exitError`.

- [ ] **Step 4: Add `XSCDatabase` branch in `newXFTPServerEnv` (`Env.hs`)**

  CPP-guarded pattern match on `XSCDatabase dbCfg`: `newFileStore dbCfg`, `storeLog = Nothing`.

- [ ] **Step 5: Add startup config validation**

  Add `checkFileStoreMode` (CPP-guarded) before `run`: validate conflicting storeLog file + database mode, missing schema, etc. per design doc.

- [ ] **Step 6: Build both ways**

  Run: `cabal build && cabal build -fserver_postgres`

- [ ] **Step 7: Format and commit**

  ```bash
  fourmolu -i src/Simplex/FileTransfer/Server/Main.hs src/Simplex/FileTransfer/Server/Env.hs
  git add src/Simplex/FileTransfer/Server/Main.hs src/Simplex/FileTransfer/Server/Env.hs
  git commit -m "feat(xftp): add PostgreSQL INI config, store dispatch, startup validation"
  ```

---

## Task 9: Add database import/export CLI commands

**Files:**
- Modify: `src/Simplex/FileTransfer/Server/Main.hs`

- [ ] **Step 1: Add `Database` CLI command (CPP-guarded)**

  Add `Database StoreCmd DBOpts` constructor to `CliCommand`. Add `database` subcommand parser with `import`/`export` subcommands + `dbOptsP defaultXFTPDBOpts`.

- [ ] **Step 2: Implement `importFileStoreToDatabase`**

  1. `confirmOrExit` with database details.
  2. Create temporary `STMFileStore`, replay StoreLog via `readWriteFileStore`.
  3. Create `PostgresFileStore` with `createSchema = True`, `confirmMigrations = MCYesUp`.
  4. Batch-insert files using PostgreSQL COPY protocol. Progress every 10k.
  5. Batch-insert recipients using COPY protocol.
  6. Verify counts: `SELECT COUNT(*)` — warn on mismatch.
  7. Rename StoreLog to `.bak`.
  8. Report counts.

- [ ] **Step 3: Implement `exportDatabaseToStoreLog`**

  1. `confirmOrExit`. Fail if output file exists.
  2. Create `PostgresFileStore` from config.
  3. Open StoreLog for writing.
  4. Fold over file records: write `AddFile` (with status), `AddRecipients`, `PutFile` per file.
  5. Close StoreLog, report counts.

- [ ] **Step 4: Build**

  Run: `cabal build -fserver_postgres`

- [ ] **Step 5: Format and commit**

  ```bash
  fourmolu -i src/Simplex/FileTransfer/Server/Main.hs
  git add src/Simplex/FileTransfer/Server/Main.hs
  git commit -m "feat(xftp): add database import/export CLI commands"
  ```

---

## Task 10: Add Postgres tests

**Files:**
- Modify: `tests/XFTPClient.hs`
- Modify: `tests/Test.hs`
- Create: `tests/CoreTests/XFTPStoreTests.hs`

- [ ] **Step 1: Add test fixtures in `tests/XFTPClient.hs`**

  ```haskell
  testXFTPStoreDBOpts :: DBOpts
  testXFTPStoreDBOpts =
    DBOpts
      { connstr = "postgresql://test_xftp_server_user@/test_xftp_server_db",
        schema = "xftp_server_test",
        poolSize = 10,
        createSchema = True
      }
  ```
  Add `testXFTPDBConnectInfo :: ConnectInfo` matching the connection string.

- [ ] **Step 2: Add Postgres server test group in `tests/Test.hs`**

  CPP-guarded block that runs existing `xftpServerTests` with Postgres store config, wrapped in `postgressBracket testXFTPDBConnectInfo`. Parameterize `withXFTPServer` to accept store config if needed.

- [ ] **Step 3: Create `tests/CoreTests/XFTPStoreTests.hs` — unit tests**

  Test `PostgresFileStore` operations directly:
  - `addFile` + `getFile SFSender` round-trip.
  - `addFile` duplicate → `DUPLICATE_`.
  - `getFile` nonexistent → `AUTH`.
  - `setFilePath` + verify `WHERE file_path IS NULL` guard.
  - `addRecipient` + `getFile SFRecipient` round-trip.
  - `deleteFile` cascades recipients.
  - `blockFile` + verify status.
  - `expiredFiles` batch semantics.
  - `getUsedStorage`, `getFileCount` correctness.

- [ ] **Step 4: Add migration round-trip test**

  Create `STMFileStore` with test data (files + recipients + blocked status) → export to StoreLog → import to Postgres → export back → compare StoreLog files byte-for-byte.

- [ ] **Step 5: Build and run tests**

  ```bash
  cabal build -fserver_postgres test:simplexmq-test
  cabal test --test-show-details=streaming --test-option=--match="/XFTP/" -fserver_postgres
  ```

- [ ] **Step 6: Format and commit**

  ```bash
  fourmolu -i tests/CoreTests/XFTPStoreTests.hs tests/XFTPClient.hs
  git add tests/CoreTests/XFTPStoreTests.hs tests/XFTPClient.hs tests/Test.hs
  git commit -m "test(xftp): add PostgreSQL backend tests"
  ```
