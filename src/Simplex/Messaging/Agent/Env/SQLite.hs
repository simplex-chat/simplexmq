{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# OPTIONS_GHC -fno-warn-unticked-promoted-constructors #-}

module Simplex.Messaging.Agent.Env.SQLite
  ( AgentMonad,
    AgentMonad',
    AgentConfig (..),
    InitialAgentServers (..),
    NetworkConfig (..),
    defaultAgentConfig,
    defaultReconnectInterval,
    tryAgentError,
    tryAgentError',
    catchAgentError,
    agentFinally,
    Env (..),
    newSMPAgentEnv,
    createAgentStore,
    NtfSupervisor (..),
    NtfSupervisorCommand (..),
    XFTPAgent (..),
    Worker (..),
    RestartCount (..),
    updateRestartCount,
  )
where

import Control.Monad
import Control.Monad.Except
import Control.Monad.IO.Unlift
import Control.Monad.Reader
import Crypto.Random
import Data.ByteArray (ScrubbedBytes)
import Data.Int (Int64)
import Data.List.NonEmpty (NonEmpty)
import Data.Map (Map)
import Data.Time.Clock (NominalDiffTime, nominalDay)
import Data.Time.Clock.System (SystemTime (..))
import Data.Word (Word16)
import Network.Socket
import Numeric.Natural
import Simplex.FileTransfer.Client (XFTPClientConfig (..), defaultXFTPClientConfig)
import Simplex.FileTransfer.Description (ValidFileDescription)
import Simplex.FileTransfer.Protocol (FileParty (..))
import Simplex.Messaging.Agent.Protocol
import Simplex.Messaging.Agent.RetryInterval
import Simplex.Messaging.Agent.Store.SQLite
import qualified Simplex.Messaging.Agent.Store.SQLite.Migrations as Migrations
import Simplex.Messaging.Client
import Simplex.Messaging.Client.Agent ()
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Crypto.Ratchet (supportedE2EEncryptVRange)
import Simplex.Messaging.Notifications.Types
import Simplex.Messaging.Protocol (NtfServer, XFTPServer, XFTPServerWithAuth, supportedSMPClientVRange)
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Transport (TLS, Transport (..))
import Simplex.Messaging.Transport.Client (defaultSMPPort)
import Simplex.Messaging.Util (allFinally, catchAllErrors, tryAllErrors)
import Simplex.Messaging.Version
import System.Random (StdGen, newStdGen)
import UnliftIO (Async, SomeException)
import UnliftIO.STM

type AgentMonad' m = (MonadUnliftIO m, MonadReader Env m)

type AgentMonad m = (AgentMonad' m, MonadError AgentErrorType m)

data InitialAgentServers = InitialAgentServers
  { smp :: Map UserId (NonEmpty SMPServerWithAuth),
    ntf :: [NtfServer],
    xftp :: Map UserId (NonEmpty XFTPServerWithAuth),
    netCfg :: NetworkConfig
  }

data AgentConfig = AgentConfig
  { tcpPort :: ServiceName,
    cmdSignAlg :: C.SignAlg,
    connIdBytes :: Int,
    tbqSize :: Natural,
    smpCfg :: ProtocolClientConfig,
    ntfCfg :: ProtocolClientConfig,
    xftpCfg :: XFTPClientConfig,
    reconnectInterval :: RetryInterval,
    messageRetryInterval :: RetryInterval2,
    messageTimeout :: NominalDiffTime,
    helloTimeout :: NominalDiffTime,
    initialCleanupDelay :: Int64,
    cleanupInterval :: Int64,
    cleanupStepInterval :: Int,
    maxWorkerRestartsPerMin :: Int,
    maxSubscriptionTimeouts :: Int,
    storedMsgDataTTL :: NominalDiffTime,
    rcvFilesTTL :: NominalDiffTime,
    sndFilesTTL :: NominalDiffTime,
    xftpNotifyErrsOnRetry :: Bool,
    xftpConsecutiveRetries :: Int,
    xftpMaxRecipientsPerRequest :: Int,
    deleteErrorCount :: Int,
    ntfCron :: Word16,
    ntfWorkerDelay :: Int,
    ntfSMPWorkerDelay :: Int,
    ntfSubCheckInterval :: NominalDiffTime,
    ntfMaxMessages :: Int,
    caCertificateFile :: FilePath,
    privateKeyFile :: FilePath,
    certificateFile :: FilePath,
    e2eEncryptVRange :: VersionRange,
    smpAgentVRange :: VersionRange,
    smpClientVRange :: VersionRange
  }

defaultReconnectInterval :: RetryInterval
defaultReconnectInterval =
  RetryInterval
    { initialInterval = 2_000000,
      increaseAfter = 10_000000,
      maxInterval = 180_000000
    }

defaultMessageRetryInterval :: RetryInterval2
defaultMessageRetryInterval =
  RetryInterval2
    { riFast =
        RetryInterval
          { initialInterval = 1_000000,
            increaseAfter = 10_000000,
            maxInterval = 60_000000
          },
      riSlow =
        -- TODO: these timeouts can be increased in v5.0 once most clients are updated
        -- to resume sending on QCONT messages.
        -- After that local message expiration period should be also increased.
        RetryInterval
          { initialInterval = 60_000000,
            increaseAfter = 60_000000,
            maxInterval = 3600_000000 -- 1 hour
          }
    }

defaultAgentConfig :: AgentConfig
defaultAgentConfig =
  AgentConfig
    { tcpPort = "5224",
      cmdSignAlg = C.SignAlg C.SEd448,
      connIdBytes = 12,
      tbqSize = 64,
      smpCfg = defaultClientConfig {defaultTransport = (show defaultSMPPort, transport @TLS)},
      ntfCfg = defaultClientConfig {defaultTransport = ("443", transport @TLS)},
      xftpCfg = defaultXFTPClientConfig,
      reconnectInterval = defaultReconnectInterval,
      messageRetryInterval = defaultMessageRetryInterval,
      messageTimeout = 2 * nominalDay,
      helloTimeout = 2 * nominalDay,
      initialCleanupDelay = 30 * 1000000, -- 30 seconds
      cleanupInterval = 30 * 60 * 1000000, -- 30 minutes
      cleanupStepInterval = 200000, -- 200ms
      maxWorkerRestartsPerMin = 5,
      -- 3 consecutive subscription timeouts will result in alert to the user
      -- this is a fallback, as the timeout set to 3x of expected timeout, to avoid potential locking.
      maxSubscriptionTimeouts = 3,
      storedMsgDataTTL = 21 * nominalDay,
      rcvFilesTTL = 2 * nominalDay,
      sndFilesTTL = nominalDay,
      xftpNotifyErrsOnRetry = True,
      xftpConsecutiveRetries = 3,
      xftpMaxRecipientsPerRequest = 200,
      deleteErrorCount = 10,
      ntfCron = 20, -- minutes
      ntfWorkerDelay = 100000, -- microseconds
      ntfSMPWorkerDelay = 500000, -- microseconds
      ntfSubCheckInterval = nominalDay,
      ntfMaxMessages = 3,
      -- CA certificate private key is not needed for initialization
      -- ! we do not generate these
      caCertificateFile = "/etc/opt/simplex-agent/ca.crt",
      privateKeyFile = "/etc/opt/simplex-agent/agent.key",
      certificateFile = "/etc/opt/simplex-agent/agent.crt",
      e2eEncryptVRange = supportedE2EEncryptVRange,
      smpAgentVRange = supportedSMPAgentVRange,
      smpClientVRange = supportedSMPClientVRange
    }

data Env = Env
  { config :: AgentConfig,
    store :: SQLiteStore,
    random :: TVar ChaChaDRG,
    randomServer :: TVar StdGen,
    ntfSupervisor :: NtfSupervisor,
    xftpAgent :: XFTPAgent,
    multicastSubscribers :: TMVar Int
  }

newSMPAgentEnv :: AgentConfig -> SQLiteStore -> IO Env
newSMPAgentEnv config store = do
  random <- C.newRandom
  randomServer <- newTVarIO =<< liftIO newStdGen
  ntfSupervisor <- atomically . newNtfSubSupervisor $ tbqSize config
  xftpAgent <- atomically newXFTPAgent
  multicastSubscribers <- newTMVarIO 0
  pure Env {config, store, random, randomServer, ntfSupervisor, xftpAgent, multicastSubscribers}

createAgentStore :: FilePath -> ScrubbedBytes -> Bool -> MigrationConfirmation -> IO (Either MigrationError SQLiteStore)
createAgentStore dbFilePath dbKey keepKey = createSQLiteStore dbFilePath dbKey keepKey Migrations.app

data NtfSupervisor = NtfSupervisor
  { ntfTkn :: TVar (Maybe NtfToken),
    ntfSubQ :: TBQueue (ConnId, NtfSupervisorCommand),
    ntfWorkers :: TMap NtfServer Worker,
    ntfSMPWorkers :: TMap SMPServer Worker
  }

data NtfSupervisorCommand = NSCCreate | NSCDelete | NSCSmpDelete | NSCNtfWorker NtfServer | NSCNtfSMPWorker SMPServer
  deriving (Show)

newNtfSubSupervisor :: Natural -> STM NtfSupervisor
newNtfSubSupervisor qSize = do
  ntfTkn <- newTVar Nothing
  ntfSubQ <- newTBQueue qSize
  ntfWorkers <- TM.empty
  ntfSMPWorkers <- TM.empty
  pure NtfSupervisor {ntfTkn, ntfSubQ, ntfWorkers, ntfSMPWorkers}

data XFTPAgent = XFTPAgent
  { -- if set, XFTP file paths will be considered as relative to this directory
    xftpWorkDir :: TVar (Maybe FilePath),
    xftpRcvWorkers :: TMap (Maybe XFTPServer) Worker,
    xftpSndWorkers :: TMap (Maybe XFTPServer) Worker,
    xftpSndCallbacks :: TMap SndFileId (SndFileId -> ValidFileDescription 'FSender -> [ValidFileDescription 'FRecipient] -> IO ()),
    xftpDelWorkers :: TMap XFTPServer Worker
  }

newXFTPAgent :: STM XFTPAgent
newXFTPAgent = do
  xftpWorkDir <- newTVar Nothing
  xftpRcvWorkers <- TM.empty
  xftpSndWorkers <- TM.empty
  xftpSndCallbacks <- TM.empty
  xftpDelWorkers <- TM.empty
  pure XFTPAgent {xftpWorkDir, xftpRcvWorkers, xftpSndWorkers, xftpSndCallbacks, xftpDelWorkers}

tryAgentError :: AgentMonad m => m a -> m (Either AgentErrorType a)
tryAgentError = tryAllErrors mkInternal
{-# INLINE tryAgentError #-}

-- unlike runExceptT, this ensures we catch IO exceptions as well
tryAgentError' :: AgentMonad' m => ExceptT AgentErrorType m a -> m (Either AgentErrorType a)
tryAgentError' = fmap join . runExceptT . tryAgentError
{-# INLINE tryAgentError' #-}

catchAgentError :: AgentMonad m => m a -> (AgentErrorType -> m a) -> m a
catchAgentError = catchAllErrors mkInternal
{-# INLINE catchAgentError #-}

agentFinally :: AgentMonad m => m a -> m b -> m a
agentFinally = allFinally mkInternal
{-# INLINE agentFinally #-}

mkInternal :: SomeException -> AgentErrorType
mkInternal = INTERNAL . show
{-# INLINE mkInternal #-}

data Worker = Worker
  { workerId :: Int,
    doWork :: TMVar (),
    action :: TMVar (Maybe (Async ())),
    restarts :: TVar RestartCount
  }

data RestartCount = RestartCount
  { restartMinute :: Int64,
    restartCount :: Int
  }

updateRestartCount :: SystemTime -> RestartCount -> RestartCount
updateRestartCount t (RestartCount minute count) = do
  let min' = systemSeconds t `div` 60
   in RestartCount min' $ if minute == min' then count + 1 else 1
