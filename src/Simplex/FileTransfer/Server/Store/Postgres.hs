{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}

module Simplex.FileTransfer.Server.Store.Postgres
  ( PostgresFileStore (..),
    withDB,
    withDB',
    handleDuplicate,
    assertUpdated,
    withLog,
  )
where

import qualified Control.Exception as E
import Control.Logger.Simple
import Control.Monad
import Control.Monad.Except
import Control.Monad.Trans.Except (throwE)
import Control.Monad.IO.Class
import Data.Functor (($>))
import Data.Int (Int64)
import Data.Text (Text)
import Database.PostgreSQL.Simple (SqlError)
import Database.PostgreSQL.Simple.Errors (ConstraintViolation (..), constraintViolation)
import qualified Database.PostgreSQL.Simple as DB
import GHC.IO (catchAny)
import Simplex.FileTransfer.Server.Store
import Simplex.FileTransfer.Server.Store.Postgres.Config
import Simplex.FileTransfer.Server.Store.Postgres.Migrations (xftpServerMigrations)
import Simplex.FileTransfer.Server.StoreLog
import Simplex.FileTransfer.Transport (XFTPErrorType (..))
import Simplex.Messaging.Agent.Store.Postgres (createDBStore, closeDBStore)
import Simplex.Messaging.Agent.Store.Postgres.Common (DBStore, withTransaction)
import Simplex.Messaging.Agent.Store.Shared (MigrationConfig (..))
import Simplex.Messaging.Server.StoreLog (openWriteStoreLog)
import Simplex.Messaging.Util (tshow)
import System.Exit (exitFailure)
import System.IO (IOMode (..))

data PostgresFileStore = PostgresFileStore
  { dbStore :: DBStore,
    dbStoreLog :: Maybe (StoreLog 'WriteMode)
  }

instance FileStoreClass PostgresFileStore where
  type FileStoreConfig PostgresFileStore = PostgresFileStoreCfg

  newFileStore PostgresFileStoreCfg {dbOpts, dbStoreLogPath, confirmMigrations} = do
    dbStore <- either err pure =<< createDBStore dbOpts xftpServerMigrations (MigrationConfig confirmMigrations Nothing)
    dbStoreLog <- mapM (openWriteStoreLog True) dbStoreLogPath
    pure PostgresFileStore {dbStore, dbStoreLog}
    where
      err e = do
        logError $ "STORE: newFileStore, error opening PostgreSQL database, " <> tshow e
        exitFailure

  closeFileStore PostgresFileStore {dbStore, dbStoreLog} = do
    closeDBStore dbStore
    mapM_ closeStoreLog dbStoreLog

  addFile _ _ _ _ _ = error "PostgresFileStore.addFile: not implemented"
  setFilePath _ _ _ = error "PostgresFileStore.setFilePath: not implemented"
  addRecipient _ _ _ = error "PostgresFileStore.addRecipient: not implemented"
  getFile _ _ _ = error "PostgresFileStore.getFile: not implemented"
  deleteFile _ _ = error "PostgresFileStore.deleteFile: not implemented"
  blockFile _ _ _ _ = error "PostgresFileStore.blockFile: not implemented"
  deleteRecipient _ _ _ = error "PostgresFileStore.deleteRecipient: not implemented"
  ackFile _ _ = error "PostgresFileStore.ackFile: not implemented"
  expiredFiles _ _ _ = error "PostgresFileStore.expiredFiles: not implemented"
  getUsedStorage _ = error "PostgresFileStore.getUsedStorage: not implemented"
  getFileCount _ = error "PostgresFileStore.getFileCount: not implemented"

-- Helpers

withDB :: forall a. Text -> PostgresFileStore -> (DB.Connection -> IO (Either XFTPErrorType a)) -> ExceptT XFTPErrorType IO a
withDB op st action =
  ExceptT $ E.try (withTransaction (dbStore st) action) >>= either logErr pure
  where
    logErr :: E.SomeException -> IO (Either XFTPErrorType a)
    logErr e = logError ("STORE: " <> err) $> Left INTERNAL
      where
        err = op <> ", withDB, " <> tshow e

withDB' :: Text -> PostgresFileStore -> (DB.Connection -> IO a) -> ExceptT XFTPErrorType IO a
withDB' op st action = withDB op st $ fmap Right . action

assertUpdated :: ExceptT XFTPErrorType IO Int64 -> ExceptT XFTPErrorType IO ()
assertUpdated = (>>= \n -> when (n == 0) (throwE AUTH))

handleDuplicate :: SqlError -> IO (Either XFTPErrorType a)
handleDuplicate e = case constraintViolation e of
  Just (UniqueViolation _) -> pure $ Left DUPLICATE_
  _ -> E.throwIO e

withLog :: MonadIO m => Text -> PostgresFileStore -> (StoreLog 'WriteMode -> IO ()) -> m ()
withLog op PostgresFileStore {dbStoreLog} action =
  forM_ dbStoreLog $ \sl -> liftIO $ action sl `catchAny` \e ->
    logWarn $ "STORE: " <> op <> ", withLog, " <> tshow e
