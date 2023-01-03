{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE NamedFieldPuns #-}

module Simplex.FileTransfer.Server.Env where

import Control.Monad.IO.Unlift
import Crypto.Random
import Data.Time.Clock (getCurrentTime)
import Data.X509.Validation (Fingerprint (..))
import Network.Socket
import qualified Network.TLS as T
import Numeric.Natural
import Simplex.Messaging.Client.Agent
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Server.Expiration
import Simplex.Messaging.Transport (ATransport)
import Simplex.Messaging.Transport.Server (loadFingerprint, loadTLSServerParams)
import System.IO (IOMode (..))
import UnliftIO.STM
import Simplex.FileTransfer.Server.Stats
import Simplex.FileTransfer.Server.Store
import Simplex.FileTransfer.Server.StoreLog

data FileServerConfig = FileServerConfig
  { transports :: [(ServiceName, ATransport)],
    subIdBytes :: Int,
    regCodeBytes :: Int,
    clientQSize :: Natural,
    subQSize :: Natural,
    smpAgentCfg :: SMPClientAgentConfig,
    inactiveClientExpiration :: Maybe ExpirationConfig,
    storeLogFile :: Maybe FilePath,
    resubscribeDelay :: Int, -- microseconds
    -- CA certificate private key is not needed for initialization
    caCertificateFile :: FilePath,
    privateKeyFile :: FilePath,
    certificateFile :: FilePath,
    -- stats config - see SMP server config
    logStatsInterval :: Maybe Int,
    logStatsStartTime :: Int,
    serverStatsLogFile :: FilePath,
    serverStatsBackupFile :: Maybe FilePath,
    logTLSErrors :: Bool
  }

defaultInactiveClientExpiration :: ExpirationConfig
defaultInactiveClientExpiration =
  ExpirationConfig
    { ttl = 7200, -- 2 hours
      checkInterval = 3600 -- seconds, 1 hour
    }

data FileEnv = FileEnv
  { config :: FileServerConfig,
    -- subscriber :: FileSubscriber,
    store :: FileStore,
    storeLog :: Maybe (StoreLog 'WriteMode),
    idsDrg :: TVar ChaChaDRG,
    serverIdentity :: C.KeyHash,
    tlsServerParams :: T.ServerParams,
    serverIdentity :: C.KeyHash,
    serverStats :: FileServerStats
  }

newFileServerEnv :: (MonadUnliftIO m, MonadRandom m) => FileServerConfig -> m FileEnv
newFileServerEnv config@FileServerConfig {subQSize, smpAgentCfg, storeLogFile, caCertificateFile, certificateFile, privateKeyFile} = do
  idsDrg <- newTVarIO =<< drgNew
  store <- atomically newFileStore
  storeLog <- liftIO $ mapM (`readWriteFileStore` store) storeLogFile
  -- subscriber <- atomically $ newFileSubscriber subQSize smpAgentCfg
  tlsServerParams <- liftIO $ loadTLSServerParams caCertificateFile certificateFile privateKeyFile
  Fingerprint fp <- liftIO $ loadFingerprint caCertificateFile
  serverStats <- atomically . newFileServerStats =<< liftIO getCurrentTime
  pure FileEnv {config, store, storeLog, idsDrg, tlsServerParams, serverIdentity = C.KeyHash fp, serverStats}
