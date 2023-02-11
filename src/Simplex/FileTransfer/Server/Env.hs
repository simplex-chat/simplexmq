{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE StrictData #-}

module Simplex.FileTransfer.Server.Env where

import Control.Monad.IO.Unlift
import Crypto.Random
import Data.List.NonEmpty (NonEmpty)
import Data.Time.Clock (getCurrentTime)
import Data.X509.Validation (Fingerprint (..))
import Network.Socket
import qualified Network.TLS as T
import Simplex.FileTransfer.Protocol (FileCmd, FileInfo)
import Simplex.FileTransfer.Server.Stats
import Simplex.FileTransfer.Server.Store
import Simplex.FileTransfer.Server.StoreLog
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Protocol (RcvPublicVerifyKey)
import Simplex.Messaging.Transport.Server (loadFingerprint, loadTLSServerParams)
import System.IO (IOMode (..))
import UnliftIO.STM

data XFTPServerConfig = XFTPServerConfig
  { xftpPort :: ServiceName,
    fileIdSize :: Int,
    storeLogFile :: Maybe FilePath,
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

data XFTPEnv = XFTPEnv
  { config :: XFTPServerConfig,
    store :: FileStore,
    storeLog :: Maybe (StoreLog 'WriteMode),
    idsDrg :: TVar ChaChaDRG,
    serverIdentity :: C.KeyHash,
    tlsServerParams :: T.ServerParams,
    serverStats :: FileServerStats
  }

newXFTPServerEnv :: (MonadUnliftIO m, MonadRandom m) => XFTPServerConfig -> m XFTPEnv
newXFTPServerEnv config@XFTPServerConfig {storeLogFile, caCertificateFile, certificateFile, privateKeyFile} = do
  idsDrg <- drgNew >>= newTVarIO
  store <- atomically newFileStore
  storeLog <- liftIO $ mapM (`readWriteFileStore` store) storeLogFile
  tlsServerParams <- liftIO $ loadTLSServerParams caCertificateFile certificateFile privateKeyFile
  Fingerprint fp <- liftIO $ loadFingerprint caCertificateFile
  serverStats <- atomically . newFileServerStats =<< liftIO getCurrentTime
  pure XFTPEnv {config, store, storeLog, idsDrg, tlsServerParams, serverIdentity = C.KeyHash fp, serverStats}

data XFTPRequest
  = XFTPReqNew FileInfo (NonEmpty RcvPublicVerifyKey)
  | XFTPReqCmd FileRec FileCmd
  | XFTPReqPing
