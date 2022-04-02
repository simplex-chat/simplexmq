{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE NamedFieldPuns #-}

module Simplex.Messaging.Notifications.Server.Env where

import Control.Monad.IO.Unlift
import Crypto.Random
import Data.ByteString.Char8 (ByteString)
import Data.X509.Validation (Fingerprint (..))
import Network.Socket
import qualified Network.TLS as T
import Numeric.Natural
import Simplex.Messaging.Agent.RetryInterval
import Simplex.Messaging.Client.Agent
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Notifications.Protocol
import Simplex.Messaging.Notifications.Server.Subscriptions
import Simplex.Messaging.Protocol (CorrId, Transmission)
import Simplex.Messaging.Transport (ATransport)
import Simplex.Messaging.Transport.Server (loadFingerprint, loadTLSServerParams)
import UnliftIO.STM

data NtfServerConfig = NtfServerConfig
  { transports :: [(ServiceName, ATransport)],
    subIdBytes :: Int,
    clientQSize :: Natural,
    subQSize :: Natural,
    pushQSize :: Natural,
    smpAgentCfg :: SMPClientAgentConfig,
    reconnectInterval :: RetryInterval,
    -- CA certificate private key is not needed for initialization
    caCertificateFile :: FilePath,
    privateKeyFile :: FilePath,
    certificateFile :: FilePath
  }

data Notification = Notification

data NtfEnv = NtfEnv
  { config :: NtfServerConfig,
    subscriber :: NtfSubscriber,
    pushServer :: NtfPushServer,
    store :: NtfStore,
    idsDrg :: TVar ChaChaDRG,
    serverIdentity :: C.KeyHash,
    tlsServerParams :: T.ServerParams,
    serverIdentity :: C.KeyHash
  }

newNtfServerEnv :: (MonadUnliftIO m, MonadRandom m) => NtfServerConfig -> m NtfEnv
newNtfServerEnv config@NtfServerConfig {subQSize, pushQSize, smpAgentCfg, caCertificateFile, certificateFile, privateKeyFile} = do
  idsDrg <- newTVarIO =<< drgNew
  store <- atomically newNtfStore
  subscriber <- atomically $ newNtfSubscriber subQSize smpAgentCfg
  pushServer <- atomically $ newNtfPushServer pushQSize
  tlsServerParams <- liftIO $ loadTLSServerParams caCertificateFile certificateFile privateKeyFile
  Fingerprint fp <- liftIO $ loadFingerprint caCertificateFile
  pure NtfEnv {config, subscriber, pushServer, store, idsDrg, tlsServerParams, serverIdentity = C.KeyHash fp}

data NtfSubscriber = NtfSubscriber
  { subQ :: TBQueue (NtfEntityRec 'Subscription),
    smpAgent :: SMPClientAgent
  }

newNtfSubscriber :: Natural -> SMPClientAgentConfig -> STM NtfSubscriber
newNtfSubscriber qSize smpAgentCfg = do
  smpAgent <- newSMPClientAgent smpAgentCfg
  subQ <- newTBQueue qSize
  pure NtfSubscriber {smpAgent, subQ}

newtype NtfPushServer = NtfPushServer
  { pushQ :: TBQueue (NtfTknData, Notification)
  }

newNtfPushServer :: Natural -> STM NtfPushServer
newNtfPushServer qSize = do
  pushQ <- newTBQueue qSize
  pure NtfPushServer {pushQ}

data NtfRequest
  = NtfReqNew CorrId ANewNtfEntity
  | forall e. NtfEntityI e => NtfReqCmd (SNtfEntity e) (NtfEntityRec e) (Transmission (NtfCommand e))

data NtfServerClient = NtfServerClient
  { rcvQ :: TBQueue NtfRequest,
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
