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
  ( AM',
    AM,
    AgentConfig (..),
    InitialAgentServers (..),
    NetworkConfig (..),
    defaultAgentConfig,
    defaultReconnectInterval,
    tryAgentError,
    tryAgentError',
    catchAgentError,
    catchAgentError',
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
import Simplex.Messaging.Agent.Protocol
import Simplex.Messaging.Agent.RetryInterval
import Simplex.Messaging.Agent.Store.SQLite
import qualified Simplex.Messaging.Agent.Store.SQLite.Migrations as Migrations
import Simplex.Messaging.Client
import Simplex.Messaging.Client.Agent ()
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Crypto.Ratchet (VersionRangeE2E, supportedE2EEncryptVRange)
import Simplex.Messaging.Notifications.Client (defaultNTFClientConfig)
import Simplex.Messaging.Notifications.Transport (NTFVersion)
import Simplex.Messaging.Notifications.Types
import Simplex.Messaging.Protocol (NtfServer, VersionRangeSMPC, XFTPServer, XFTPServerWithAuth, supportedSMPClientVRange)
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Transport (SMPVersion, TLS, Transport (..))
import Simplex.Messaging.Transport.Client (defaultSMPPort)
import Simplex.Messaging.Util (allFinally, catchAllErrors, catchAllErrors', tryAllErrors, tryAllErrors')
import System.Random (StdGen, newStdGen)
import UnliftIO (Async, SomeException)
import UnliftIO.STM

type AM' a = ReaderT Env IO a

type AM a = ExceptT AgentErrorType (ReaderT Env IO) a

data InitialAgentServers = InitialAgentServers
  { smp :: Map UserId (NonEmpty SMPServerWithAuth),
    ntf :: [NtfServer],
    xftp :: Map UserId (NonEmpty XFTPServerWithAuth),
    netCfg :: NetworkConfig
  }

data AgentConfig = AgentConfig
  { tcpPort :: Maybe ServiceName,
    rcvAuthAlg :: C.AuthAlg,
    sndAuthAlg :: C.AuthAlg,
    connIdBytes :: Int,
    tbqSize :: Natural,
    smpCfg :: ProtocolClientConfig SMPVersion,
    ntfCfg :: ProtocolClientConfig NTFVersion,
    xftpCfg :: XFTPClientConfig,
    reconnectInterval :: RetryInterval,
    messageRetryInterval :: RetryInterval2,
    userNetworkInterval :: Int,
    userOfflineDelay :: NominalDiffTime,
    messageTimeout :: NominalDiffTime,
    connDeleteDeliveryTimeout :: NominalDiffTime,
    helloTimeout :: NominalDiffTime,
    quotaExceededTimeout :: NominalDiffTime,
    persistErrorInterval :: NominalDiffTime,
    initialCleanupDelay :: Int64,
    cleanupInterval :: Int64,
    cleanupStepInterval :: Int,
    maxWorkerRestartsPerMin :: Int,
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
    e2eEncryptVRange :: VersionRangeE2E,
    smpAgentVRange :: VersionRangeSMPA,
    smpClientVRange :: VersionRangeSMPC
  }

defaultReconnectInterval :: RetryInterval
defaultReconnectInterval =
  RetryInterval
    { initialInterval = 2_000000,
      increaseAfter = 10_000000,
      maxInterval = 60_000000
    }

defaultMessageRetryInterval :: RetryInterval2
defaultMessageRetryInterval =
  RetryInterval2
    { riFast =
        RetryInterval
          { initialInterval = 2_000000,
            increaseAfter = 10_000000,
            maxInterval = 60_000000
          },
      riSlow =
        RetryInterval
          { initialInterval = 300_000000, -- 5 minutes
            increaseAfter = 60_000000,
            maxInterval = 6 * 3600_000000 -- 6 hours
          }
    }

defaultAgentConfig :: AgentConfig
defaultAgentConfig =
  AgentConfig
    { tcpPort = Just "5224",
      -- while the current client version supports X25519, it can only be enabled once support for SMP v6 is dropped,
      -- and all servers are required to support v7 to be compatible.
      rcvAuthAlg = C.AuthAlg C.SEd25519, -- this will stay as Ed25519
      sndAuthAlg = C.AuthAlg C.SEd25519, -- TODO replace with X25519 when switching to v7
      connIdBytes = 12,
      tbqSize = 64,
      smpCfg = defaultSMPClientConfig {defaultTransport = (show defaultSMPPort, transport @TLS)},
      ntfCfg = defaultNTFClientConfig {defaultTransport = ("443", transport @TLS)},
      xftpCfg = defaultXFTPClientConfig,
      reconnectInterval = defaultReconnectInterval,
      messageRetryInterval = defaultMessageRetryInterval,
      userNetworkInterval = 1800_000000, -- 30 minutes, should be less than Int32 max value
      userOfflineDelay = 2, -- if network offline event happens in less than 2 seconds after it was set online, it is ignored
      messageTimeout = 2 * nominalDay,
      connDeleteDeliveryTimeout = 2 * nominalDay,
      helloTimeout = 2 * nominalDay,
      quotaExceededTimeout = 7 * nominalDay,
      persistErrorInterval = 3, -- seconds
      initialCleanupDelay = 30 * 1000000, -- 30 seconds
      cleanupInterval = 30 * 60 * 1000000, -- 30 minutes
      cleanupStepInterval = 200000, -- 200ms
      maxWorkerRestartsPerMin = 5,
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
    xftpDelWorkers :: TMap XFTPServer Worker
  }

newXFTPAgent :: STM XFTPAgent
newXFTPAgent = do
  xftpWorkDir <- newTVar Nothing
  xftpRcvWorkers <- TM.empty
  xftpSndWorkers <- TM.empty
  xftpDelWorkers <- TM.empty
  pure XFTPAgent {xftpWorkDir, xftpRcvWorkers, xftpSndWorkers, xftpDelWorkers}

tryAgentError :: AM a -> AM (Either AgentErrorType a)
tryAgentError = tryAllErrors mkInternal
{-# INLINE tryAgentError #-}

-- unlike runExceptT, this ensures we catch IO exceptions as well
tryAgentError' :: AM a -> AM' (Either AgentErrorType a)
tryAgentError' = tryAllErrors' mkInternal
{-# INLINE tryAgentError' #-}

catchAgentError :: AM a -> (AgentErrorType -> AM a) -> AM a
catchAgentError = catchAllErrors mkInternal
{-# INLINE catchAgentError #-}

catchAgentError' :: AM a -> (AgentErrorType -> AM' a) -> AM' a
catchAgentError' = catchAllErrors' mkInternal
{-# INLINE catchAgentError' #-}

agentFinally :: AM a -> AM b -> AM a
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
