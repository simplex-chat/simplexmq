{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NamedFieldPuns #-}

module Simplex.Messaging.Notifications.Server.Env where

import Control.Monad.IO.Unlift
import Crypto.Random
import Data.ByteString.Char8 (ByteString)
import qualified Data.Map.Strict as M
import Data.X509.Validation (Fingerprint (..))
import Network.Socket
import qualified Network.TLS as T
import Numeric.Natural
import Simplex.Messaging.Agent.RetryInterval
import Simplex.Messaging.Client
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Notifications.Protocol
import Simplex.Messaging.Notifications.Server.Subscriptions
import Simplex.Messaging.Protocol (Transmission)
import Simplex.Messaging.Transport (ATransport)
import Simplex.Messaging.Transport.Server (loadFingerprint, loadTLSServerParams)
import UnliftIO.STM

data NtfServerConfig = NtfServerConfig
  { transports :: [(ServiceName, ATransport)],
    subscriptionIdBytes :: Int,
    tbqSize :: Natural,
    smpCfg :: SMPClientConfig,
    reconnectInterval :: RetryInterval,
    -- CA certificate private key is not needed for initialization
    caCertificateFile :: FilePath,
    privateKeyFile :: FilePath,
    certificateFile :: FilePath
  }

data NtfEnv = NtfEnv
  { config :: NtfServerConfig,
    serverIdentity :: C.KeyHash,
    store :: NtfSubscriptions,
    idsDrg :: TVar ChaChaDRG,
    tlsServerParams :: T.ServerParams,
    serverIdentity :: C.KeyHash
  }

newNtfServerEnv :: (MonadUnliftIO m, MonadRandom m) => NtfServerConfig -> m NtfEnv
newNtfServerEnv config@NtfServerConfig {caCertificateFile, certificateFile, privateKeyFile} = do
  idsDrg <- newTVarIO =<< drgNew
  store <- newTVarIO M.empty
  tlsServerParams <- liftIO $ loadTLSServerParams caCertificateFile certificateFile privateKeyFile
  Fingerprint fp <- liftIO $ loadFingerprint caCertificateFile
  let serverIdentity = C.KeyHash fp
  pure NtfEnv {config, store, idsDrg, tlsServerParams, serverIdentity}

data NtfServerClient = NtfServerClient
  { rcvQ :: TBQueue (Transmission NtfCommand),
    sndQ :: TBQueue (Transmission NtfResponse),
    sessionId :: ByteString,
    connected :: TVar Bool
  }

newNtfServerClient :: Natural -> ByteString -> STM NtfServerClient
newNtfServerClient qSize sessionId = do
  rcvQ <- newTBQueue qSize
  sndQ <- newTBQueue qSize
  connected <- newTVar True
  return NtfServerClient {rcvQ, sndQ, sessionId, connected}
