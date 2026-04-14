{-# LANGUAGE CPP #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}
{-# LANGUAGE TypeFamilies #-}

module Simplex.FileTransfer.Server.Env
  ( XFTPServerConfig (..),
    XFTPStoreConfig (..),
    XFTPEnv (..),
    XFTPRequest (..),
    XFTPStoreType,
    FileStore (..),
    AFStoreType (..),
    fileStore,
    fromFileStore,
    defaultInactiveClientExpiration,
    defFileExpirationHours,
    defaultFileExpiration,
    newXFTPServerEnv,
    readFileStoreType,
    runWithStoreConfig,
    checkFileStoreMode,
    importToDatabase,
    exportFromDatabase,
  ) where

import Control.Logger.Simple
import Control.Monad
import Crypto.Random
import Data.Int (Int64)
import Data.List.NonEmpty (NonEmpty)
import Data.Time.Clock (getCurrentTime)
import Data.Word (Word32)
import Data.X509.Validation (Fingerprint (..))
import Network.Socket
import qualified Network.TLS as T
import Simplex.FileTransfer.Protocol (FileCmd, FileInfo (..), XFTPFileId)
import Simplex.FileTransfer.Server.Stats
import Data.Ini (Ini)
import Simplex.FileTransfer.Server.Store
import Simplex.Messaging.Agent.Store.Shared (MigrationConfirmation)
#if defined(dbServerPostgres)
import Data.Functor (($>))
import Data.Maybe (isNothing)
import Simplex.FileTransfer.Server.Store.Postgres (PostgresFileStore, importFileStore, exportFileStore)
import Simplex.FileTransfer.Server.Store.Postgres.Config (PostgresFileStoreCfg (..), defaultXFTPDBOpts)
import Simplex.Messaging.Server.CLI (iniDBOptions, settingIsOn)
import System.Directory (doesFileExist)
import System.Exit (exitFailure)
#endif
import Simplex.FileTransfer.Server.StoreLog
import Simplex.FileTransfer.Transport (VersionRangeXFTP)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Protocol (BasicAuth, RcvPublicAuthKey)
import Simplex.Messaging.Server.Expiration
import Simplex.Messaging.Transport.Server (ServerCredentials (..), TransportServerConfig (..), loadFingerprint, loadServerCredential)
import Simplex.Messaging.Util (tshow)
import System.IO (IOMode (..))
import UnliftIO.STM

data XFTPServerConfig s = XFTPServerConfig
  { xftpPort :: ServiceName,
    controlPort :: Maybe ServiceName,
    fileIdSize :: Int,
    serverStoreCfg :: XFTPStoreConfig s,
    storeLogFile :: Maybe FilePath,
    filesPath :: FilePath,
    -- | server storage quota
    fileSizeQuota :: Maybe Int64,
    -- | allowed file chunk sizes
    allowedChunkSizes :: [Word32],
    -- | set to False to prohibit creating new files
    allowNewFiles :: Bool,
    -- | simple password that the clients need to pass in handshake to be able to create new files
    newFileBasicAuth :: Maybe BasicAuth,
    -- | control port passwords,
    controlPortUserAuth :: Maybe BasicAuth,
    controlPortAdminAuth :: Maybe BasicAuth,
    -- | time after which the files can be removed and check interval, seconds
    fileExpiration :: Maybe ExpirationConfig,
    -- | timeout to receive file
    fileTimeout :: Int,
    -- | time after which inactive clients can be disconnected and check interval, seconds
    inactiveClientExpiration :: Maybe ExpirationConfig,
    xftpCredentials :: ServerCredentials,
    httpCredentials :: Maybe ServerCredentials,
    -- | XFTP client-server protocol version range
    xftpServerVRange :: VersionRangeXFTP,
    -- stats config - see SMP server config
    logStatsInterval :: Maybe Int64,
    logStatsStartTime :: Int64,
    serverStatsLogFile :: FilePath,
    serverStatsBackupFile :: Maybe FilePath,
    prometheusInterval :: Maybe Int,
    prometheusMetricsFile :: FilePath,
    transportConfig :: TransportServerConfig,
    responseDelay :: Int,
    webStaticPath :: Maybe FilePath
  }

defaultInactiveClientExpiration :: ExpirationConfig
defaultInactiveClientExpiration =
  ExpirationConfig
    { ttl = 21600, -- seconds, 6 hours
      checkInterval = 3600 -- seconds, 1 hours
    }

data XFTPStoreConfig s where
  XSCMemory :: Maybe FilePath -> XFTPStoreConfig STMFileStore
#if defined(dbServerPostgres)
  XSCDatabase :: PostgresFileStoreCfg -> XFTPStoreConfig PostgresFileStore
#endif

type family XFTPStoreType (fs :: FSType) where
  XFTPStoreType 'FSMemory = STMFileStore
#if defined(dbServerPostgres)
  XFTPStoreType 'FSPostgres = PostgresFileStore
#endif

data FileStore s where
  StoreMemory :: STMFileStore -> FileStore STMFileStore
#if defined(dbServerPostgres)
  StoreDatabase :: PostgresFileStore -> FileStore PostgresFileStore
#endif

data AFStoreType = forall fs. FileStoreClass (XFTPStoreType fs) => AFSType (SFSType fs)

fromFileStore :: FileStore s -> s
fromFileStore = \case
  StoreMemory s -> s
#if defined(dbServerPostgres)
  StoreDatabase s -> s
#endif
{-# INLINE fromFileStore #-}

data XFTPEnv s = XFTPEnv
  { config :: XFTPServerConfig s,
    fileStore_ :: FileStore s,
    usedStorage :: TVar Int64,
    storeLog :: Maybe (StoreLog 'WriteMode),
    random :: TVar ChaChaDRG,
    serverIdentity :: C.KeyHash,
    tlsServerCreds :: T.Credential,
    httpServerCreds :: Maybe T.Credential,
    serverStats :: FileServerStats
  }

fileStore :: XFTPEnv s -> s
fileStore = fromFileStore . fileStore_
{-# INLINE fileStore #-}

defFileExpirationHours :: Int64
defFileExpirationHours = 48

defaultFileExpiration :: ExpirationConfig
defaultFileExpiration =
  ExpirationConfig
    { ttl = defFileExpirationHours * 3600, -- seconds
      checkInterval = 2 * 3600 -- seconds, 2 hours
    }

newXFTPServerEnv :: FileStoreClass s => XFTPServerConfig s -> IO (XFTPEnv s)
newXFTPServerEnv config@XFTPServerConfig {serverStoreCfg, fileSizeQuota, xftpCredentials, httpCredentials} = do
  random <- C.newRandom
  (fileStore_, storeLog) <- case serverStoreCfg of
    XSCMemory storeLogPath -> do
      st <- newFileStore ()
      sl <- mapM (`readWriteFileStore` st) storeLogPath
      atomically $ writeTVar (stmStoreLog st) sl
      pure (StoreMemory st, sl)
#if defined(dbServerPostgres)
    XSCDatabase dbCfg -> do
      st <- newFileStore dbCfg
      pure (StoreDatabase st, Nothing)
#endif
  used <- getUsedStorage (fromFileStore fileStore_)
  usedStorage <- newTVarIO used
  forM_ fileSizeQuota $ \quota -> do
    logNote $ "Total / available storage: " <> tshow quota <> " / " <> tshow (quota - used)
    when (quota < used) $ logWarn "WARNING: storage quota is less than used storage, no files can be uploaded!"
  tlsServerCreds <- loadServerCredential xftpCredentials
  httpServerCreds <- mapM loadServerCredential httpCredentials
  Fingerprint fp <- loadFingerprint xftpCredentials
  serverStats <- newFileServerStats =<< getCurrentTime
  pure XFTPEnv {config, fileStore_, usedStorage, storeLog, random, tlsServerCreds, httpServerCreds, serverIdentity = C.KeyHash fp, serverStats}

data XFTPRequest
  = XFTPReqNew FileInfo (NonEmpty RcvPublicAuthKey) (Maybe BasicAuth)
  | XFTPReqCmd XFTPFileId FileRec FileCmd
  | XFTPReqPing

readFileStoreType :: String -> Either String AFStoreType
readFileStoreType = \case
  "memory" -> Right $ AFSType SFSMemory
#if defined(dbServerPostgres)
  "database" -> Right $ AFSType SFSPostgres
#else
  "database" -> Left "Error: server binary is compiled without support for PostgreSQL database.\nPlease re-compile with `cabal build -fserver_postgres`."
#endif
  other -> Left $ "Invalid store_files value: " <> other

-- | Dispatch store config from AFStoreType singleton and run the callback.
-- CPP guards for Postgres are handled here so Main.hs stays CPP-free.
runWithStoreConfig ::
  AFStoreType ->
  Ini ->
  FilePath ->
  MigrationConfirmation ->
  (forall s. FileStoreClass s => XFTPStoreConfig s -> IO ()) ->
  IO ()
runWithStoreConfig (AFSType fs) ini storeLogFilePath confirmMigrations run =
  run $ iniStoreCfg fs
  where
    enableStoreLog' = settingIsOn "STORE_LOG" "enable" ini
    iniStoreCfg :: SFSType fs -> XFTPStoreConfig (XFTPStoreType fs)
    iniStoreCfg SFSMemory = XSCMemory (enableStoreLog' $> storeLogFilePath)
#if defined(dbServerPostgres)
    iniStoreCfg SFSPostgres = XSCDatabase dbCfg
      where
        enableDbStoreLog' = settingIsOn "STORE_LOG" "db_store_log" ini
        dbStoreLogPath = enableDbStoreLog' $> storeLogFilePath
        dbCfg = PostgresFileStoreCfg {dbOpts = iniDBOptions ini defaultXFTPDBOpts, dbStoreLogPath, confirmMigrations}
#endif

-- | Validate startup config when store_files=database.
checkFileStoreMode :: Ini -> String -> FilePath -> IO ()
#if defined(dbServerPostgres)
checkFileStoreMode ini storeType storeLogFilePath = case storeType of
  "database" -> do
    storeLogExists <- doesFileExist storeLogFilePath
    let dbStoreLogOn = settingIsOn "STORE_LOG" "db_store_log" ini
    when (storeLogExists && isNothing dbStoreLogOn) $ do
      putStrLn $ "Error: store log file " <> storeLogFilePath <> " exists but store_files is `database`."
      putStrLn "Use `file-server database import` to migrate, or set `db_store_log: on`."
      exitFailure
  _ -> pure ()
#else
checkFileStoreMode _ _ _ = pure ()
#endif

-- | Import StoreLog to PostgreSQL database.
importToDatabase :: FilePath -> Ini -> MigrationConfirmation -> IO ()
#if defined(dbServerPostgres)
importToDatabase storeLogFilePath ini _confirmMigrations = do
  let dbCfg = PostgresFileStoreCfg {dbOpts = iniDBOptions ini defaultXFTPDBOpts, dbStoreLogPath = Nothing, confirmMigrations = _confirmMigrations}
  importFileStore storeLogFilePath dbCfg
#else
importToDatabase _ _ _ = error "Error: server binary is compiled without support for PostgreSQL database.\nPlease re-compile with `cabal build -fserver_postgres`."
#endif

-- | Export PostgreSQL database to StoreLog.
exportFromDatabase :: FilePath -> Ini -> MigrationConfirmation -> IO ()
#if defined(dbServerPostgres)
exportFromDatabase storeLogFilePath ini _confirmMigrations = do
  let dbCfg = PostgresFileStoreCfg {dbOpts = iniDBOptions ini defaultXFTPDBOpts, dbStoreLogPath = Nothing, confirmMigrations = _confirmMigrations}
  exportFileStore storeLogFilePath dbCfg
#else
exportFromDatabase _ _ _ = error "Error: server binary is compiled without support for PostgreSQL database.\nPlease re-compile with `cabal build -fserver_postgres`."
#endif
