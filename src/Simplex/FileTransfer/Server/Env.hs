{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}

module Simplex.FileTransfer.Server.Env where

import Control.Logger.Simple (logInfo)
import Control.Monad
import Control.Monad.IO.Unlift
import Crypto.Random
import Data.Int (Int64)
import Data.List.NonEmpty (NonEmpty)
import Data.Time.Clock (getCurrentTime)
import Data.Word (Word32)
import Data.X509.Validation (Fingerprint (..))
import Network.Socket
import qualified Network.TLS as T
import Simplex.FileTransfer.Protocol (FileCmd, FileInfo, XFTPFileId)
import Simplex.FileTransfer.Server.Stats
import Simplex.FileTransfer.Server.Store
import Simplex.FileTransfer.Server.StoreLog
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Protocol (BasicAuth, RcvPublicAuthKey)
import Simplex.Messaging.Server.Expiration
import Simplex.Messaging.Transport.Server (TransportServerConfig, loadFingerprint, loadTLSServerParams)
import Simplex.Messaging.Util (tshow)
import System.IO (IOMode (..))
import UnliftIO.STM

data XFTPServerConfig = XFTPServerConfig
  { xftpPort :: ServiceName,
    controlPort :: Maybe ServiceName,
    fileIdSize :: Int,
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
    -- | time after which the files can be removed and check interval, seconds
    fileExpiration :: Maybe ExpirationConfig,
    -- | timeout to receive file
    fileTimeout :: Int,
    -- | time after which inactive clients can be disconnected and check interval, seconds
    inactiveClientExpiration :: Maybe ExpirationConfig,
    -- CA certificate private key is not needed for initialization
    caCertificateFile :: FilePath,
    privateKeyFile :: FilePath,
    certificateFile :: FilePath,
    -- stats config - see SMP server config
    logStatsInterval :: Maybe Int64,
    logStatsStartTime :: Int64,
    serverStatsLogFile :: FilePath,
    serverStatsBackupFile :: Maybe FilePath,
    transportConfig :: TransportServerConfig
  }

defaultInactiveClientExpiration :: ExpirationConfig
defaultInactiveClientExpiration =
  ExpirationConfig
    { ttl = 43200, -- seconds, 12 hours
      checkInterval = 3600 -- seconds, 1 hours
    }

data XFTPEnv = XFTPEnv
  { config :: XFTPServerConfig,
    store :: FileStore,
    storeLog :: Maybe (StoreLog 'WriteMode),
    random :: TVar ChaChaDRG,
    serverIdentity :: C.KeyHash,
    tlsServerParams :: T.ServerParams,
    serverStats :: FileServerStats
  }

defFileExpirationHours :: Int64
defFileExpirationHours = 48

defaultFileExpiration :: ExpirationConfig
defaultFileExpiration =
  ExpirationConfig
    { ttl = defFileExpirationHours * 3600, -- seconds
      checkInterval = 2 * 3600 -- seconds, 2 hours
    }

newXFTPServerEnv :: (MonadUnliftIO m, MonadRandom m) => XFTPServerConfig -> m XFTPEnv
newXFTPServerEnv config@XFTPServerConfig {storeLogFile, fileSizeQuota, caCertificateFile, certificateFile, privateKeyFile} = do
  random <- liftIO C.newRandom
  store <- atomically newFileStore
  storeLog <- liftIO $ mapM (`readWriteFileStore` store) storeLogFile
  used <- readTVarIO (usedStorage store)
  forM_ fileSizeQuota $ \quota -> do
    logInfo $ "Total / available storage: " <> tshow quota <> " / " <> tshow (quota - used)
    when (quota < used) $ logInfo "WARNING: storage quota is less than used storage, no files can be uploaded!"
  tlsServerParams <- liftIO $ loadTLSServerParams caCertificateFile certificateFile privateKeyFile
  Fingerprint fp <- liftIO $ loadFingerprint caCertificateFile
  serverStats <- atomically . newFileServerStats =<< liftIO getCurrentTime
  pure XFTPEnv {config, store, storeLog, random, tlsServerParams, serverIdentity = C.KeyHash fp, serverStats}

data XFTPRequest
  = XFTPReqNew FileInfo (NonEmpty RcvPublicAuthKey) (Maybe BasicAuth)
  | XFTPReqCmd XFTPFileId FileRec FileCmd
  | XFTPReqPing
