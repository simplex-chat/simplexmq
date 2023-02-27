{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeApplications #-}
{-# OPTIONS_GHC -fno-warn-unticked-promoted-constructors #-}

module Simplex.Messaging.Agent.Env.SQLite
  ( AgentMonad,
    AgentConfig (..),
    AgentDatabase (..),
    databaseFile,
    InitialAgentServers (..),
    NetworkConfig (..),
    defaultAgentConfig,
    defaultReconnectInterval,
    Env (..),
    newSMPAgentEnv,
    createAgentStore,
    NtfSupervisor (..),
    NtfSupervisorCommand (..),
    XFTPSupervisor (..),
  )
where

import Control.Monad.Except
import Control.Monad.IO.Unlift
import Control.Monad.Reader
import Crypto.Random
import Data.List.NonEmpty (NonEmpty)
import Data.Map (Map)
import Data.Time.Clock (NominalDiffTime, nominalDay)
import Data.Word (Word16)
import Network.Socket
import Numeric.Natural
import Simplex.Messaging.Agent.Protocol
import Simplex.Messaging.Agent.RetryInterval
import Simplex.Messaging.Agent.Store (UserId)
import Simplex.Messaging.Agent.Store.SQLite
import qualified Simplex.Messaging.Agent.Store.SQLite.Migrations as Migrations
import Simplex.Messaging.Client
import Simplex.Messaging.Client.Agent ()
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Crypto.Ratchet (supportedE2EEncryptVRange)
import Simplex.Messaging.Notifications.Types
import Simplex.Messaging.Protocol (NtfServer, XFTPServer, supportedSMPClientVRange)
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Transport (TLS, Transport (..))
import Simplex.Messaging.Transport.Client (defaultSMPPort)
import Simplex.Messaging.Version
import System.Random (StdGen, newStdGen)
import UnliftIO (Async)
import UnliftIO.STM

-- | Agent monad with MonadReader Env and MonadError AgentErrorType
type AgentMonad m = (MonadUnliftIO m, MonadReader Env m, MonadError AgentErrorType m)

data InitialAgentServers = InitialAgentServers
  { smp :: Map UserId (NonEmpty SMPServerWithAuth),
    ntf :: [NtfServer],
    netCfg :: NetworkConfig
  }

data AgentDatabase
  = AgentDB SQLiteStore
  | AgentDBFile {dbFile :: FilePath, dbKey :: String}

databaseFile :: AgentDatabase -> FilePath
databaseFile = \case
  AgentDB SQLiteStore {dbFilePath} -> dbFilePath
  AgentDBFile {dbFile} -> dbFile

data AgentConfig = AgentConfig
  { tcpPort :: ServiceName,
    cmdSignAlg :: C.SignAlg,
    connIdBytes :: Int,
    tbqSize :: Natural,
    database :: AgentDatabase,
    yesToMigrations :: Bool,
    smpCfg :: ProtocolClientConfig,
    ntfCfg :: ProtocolClientConfig,
    reconnectInterval :: RetryInterval,
    messageRetryInterval :: RetryInterval2,
    messageTimeout :: NominalDiffTime,
    helloTimeout :: NominalDiffTime,
    initialCleanupDelay :: Int,
    cleanupInterval :: Int,
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
    smpClientVRange :: VersionRange,
    initialClientId :: Int
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
            maxInterval = 1200_000000 -- 20min
          }
    }

defaultAgentConfig :: AgentConfig
defaultAgentConfig =
  AgentConfig
    { tcpPort = "5224",
      cmdSignAlg = C.SignAlg C.SEd448,
      connIdBytes = 12,
      tbqSize = 64,
      database = AgentDBFile {dbFile = "smp-agent.db", dbKey = ""},
      yesToMigrations = False,
      smpCfg = defaultClientConfig {defaultTransport = (show defaultSMPPort, transport @TLS)},
      ntfCfg = defaultClientConfig {defaultTransport = ("443", transport @TLS)},
      reconnectInterval = defaultReconnectInterval,
      messageRetryInterval = defaultMessageRetryInterval,
      messageTimeout = 2 * nominalDay,
      helloTimeout = 2 * nominalDay,
      initialCleanupDelay = 30 * 1000000, -- 30 seconds
      cleanupInterval = 30 * 60 * 1000000, -- 30 minutes
      deleteErrorCount = 10,
      ntfCron = 20, -- minutes
      ntfWorkerDelay = 100000, -- microseconds
      ntfSMPWorkerDelay = 500000, -- microseconds
      ntfSubCheckInterval = nominalDay,
      ntfMaxMessages = 4,
      -- CA certificate private key is not needed for initialization
      -- ! we do not generate these
      caCertificateFile = "/etc/opt/simplex-agent/ca.crt",
      privateKeyFile = "/etc/opt/simplex-agent/agent.key",
      certificateFile = "/etc/opt/simplex-agent/agent.crt",
      e2eEncryptVRange = supportedE2EEncryptVRange,
      smpAgentVRange = supportedSMPAgentVRange,
      smpClientVRange = supportedSMPClientVRange,
      initialClientId = 0
    }

data Env = Env
  { config :: AgentConfig,
    store :: SQLiteStore,
    idsDrg :: TVar ChaChaDRG,
    clientCounter :: TVar Int,
    randomServer :: TVar StdGen,
    ntfSupervisor :: NtfSupervisor,
    xftpSupervisor :: XFTPSupervisor
  }

newSMPAgentEnv :: (MonadUnliftIO m, MonadRandom m) => AgentConfig -> m Env
newSMPAgentEnv config@AgentConfig {database, yesToMigrations, initialClientId} = do
  idsDrg <- newTVarIO =<< drgNew
  store <- case database of
    AgentDB st -> pure st
    AgentDBFile {dbFile, dbKey} -> liftIO $ createAgentStore dbFile dbKey yesToMigrations
  clientCounter <- newTVarIO initialClientId
  randomServer <- newTVarIO =<< liftIO newStdGen
  ntfSupervisor <- atomically . newNtfSubSupervisor $ tbqSize config
  xftpSupervisor <- atomically newXFTPSupervisor
  return Env {config, store, idsDrg, clientCounter, randomServer, ntfSupervisor, xftpSupervisor}

createAgentStore :: FilePath -> String -> Bool -> IO SQLiteStore
createAgentStore dbFilePath dbKey = createSQLiteStore dbFilePath dbKey Migrations.app

data NtfSupervisor = NtfSupervisor
  { ntfTkn :: TVar (Maybe NtfToken),
    ntfSubQ :: TBQueue (ConnId, NtfSupervisorCommand),
    ntfWorkers :: TMap NtfServer (TMVar (), Async ()),
    ntfSMPWorkers :: TMap SMPServer (TMVar (), Async ())
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

data XFTPSupervisor = XFTPSupervisor
  { xftpWorkers :: TMap (Maybe XFTPServer) (TMVar (), Async ())
  }

newXFTPSupervisor :: STM XFTPSupervisor
newXFTPSupervisor = do
  xftpWorkers <- TM.empty
  pure XFTPSupervisor {xftpWorkers}
