{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}

module Simplex.FileTransfer.Server.Env where

import Control.Logger.Simple
import Control.Monad
import Crypto.Random
import Data.Int (Int64)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.Map.Strict as M
import Data.Time.Clock (getCurrentTime)
import Data.Word (Word32)
import Data.X509.Validation (Fingerprint (..))
import Network.Socket
import qualified Network.TLS as T
import Simplex.FileTransfer.Protocol (FileCmd, FileInfo (..), XFTPFileId)
import Simplex.FileTransfer.Server.Stats
import Simplex.FileTransfer.Server.Store
import Simplex.FileTransfer.Server.StoreLog
import Simplex.FileTransfer.Transport (VersionRangeXFTP)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Protocol (BasicAuth, RcvPublicAuthKey)
import Simplex.Messaging.Server.Expiration
import Simplex.Messaging.Transport (ALPN)
import Simplex.Messaging.Transport.Server (TransportServerConfig (..), loadFingerprint, loadTLSServerParams)
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
    -- | control port passwords,
    controlPortUserAuth :: Maybe BasicAuth,
    controlPortAdminAuth :: Maybe BasicAuth,
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
    -- | XFTP client-server protocol version range
    xftpServerVRange :: VersionRangeXFTP,
    -- stats config - see SMP server config
    logStatsInterval :: Maybe Int64,
    logStatsStartTime :: Int64,
    serverStatsLogFile :: FilePath,
    serverStatsBackupFile :: Maybe FilePath,
    transportConfig :: TransportServerConfig,
    responseDelay :: Int
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

supportedXFTPhandshakes :: [ALPN]
supportedXFTPhandshakes = ["xftp/1"]

newXFTPServerEnv :: XFTPServerConfig -> IO XFTPEnv
newXFTPServerEnv config@XFTPServerConfig {storeLogFile, fileSizeQuota, caCertificateFile, certificateFile, privateKeyFile, transportConfig} = do
  random <- C.newRandom
  store <- newFileStore
  storeLog <- mapM (`readWriteFileStore` store) storeLogFile
  used <- countUsedStorage <$> readTVarIO (files store)
  atomically $ writeTVar (usedStorage store) used
  forM_ fileSizeQuota $ \quota -> do
    logInfo $ "Total / available storage: " <> tshow quota <> " / " <> tshow (quota - used)
    when (quota < used) $ logInfo "WARNING: storage quota is less than used storage, no files can be uploaded!"
  tlsServerParams <- loadTLSServerParams caCertificateFile certificateFile privateKeyFile (alpn transportConfig)
  Fingerprint fp <- loadFingerprint caCertificateFile
  serverStats <- newFileServerStats =<< getCurrentTime
  pure XFTPEnv {config, store, storeLog, random, tlsServerParams, serverIdentity = C.KeyHash fp, serverStats}

countUsedStorage :: M.Map k FileRec -> Int64
countUsedStorage = M.foldl' (\acc FileRec {fileInfo = FileInfo {size}} -> acc + fromIntegral size) 0

data XFTPRequest
  = XFTPReqNew FileInfo (NonEmpty RcvPublicAuthKey) (Maybe BasicAuth)
  | XFTPReqCmd XFTPFileId FileRec FileCmd
  | XFTPReqPing
