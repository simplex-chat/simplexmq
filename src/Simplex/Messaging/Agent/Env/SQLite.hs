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
    InitialAgentServers (..),
    defaultAgentConfig,
    defaultReconnectInterval,
    Env (..),
    newSMPAgentEnv,
    NtfSupervisor (..),
    NtfSupervisorCommand (..),
    withStore,
  )
where

import Control.Monad.Except
import Control.Monad.IO.Unlift
import Control.Monad.Reader
import Crypto.Random
import Data.List.NonEmpty (NonEmpty)
import Data.Time.Clock (NominalDiffTime, nominalDay)
import Database.SQLite.Simple (SQLError)
import Network.Socket
import Numeric.Natural
import Simplex.Messaging.Agent.Protocol
import Simplex.Messaging.Agent.RetryInterval
import Simplex.Messaging.Agent.Store (ConnType (..), RcvQueue, StoreError (..))
import Simplex.Messaging.Agent.Store.SQLite
import qualified Simplex.Messaging.Agent.Store.SQLite.Migrations as Migrations
import Simplex.Messaging.Client
import Simplex.Messaging.Client.Agent ()
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Notifications.Client (NtfServer, NtfToken)
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Transport (TLS, Transport (..))
import Simplex.Messaging.Util (bshow)
import Simplex.Messaging.Version
import System.Random (StdGen, newStdGen)
import UnliftIO (Async)
import qualified UnliftIO.Exception as E
import UnliftIO.STM

-- | Agent monad with MonadReader Env and MonadError AgentErrorType
type AgentMonad m = (MonadUnliftIO m, MonadReader Env m, MonadError AgentErrorType m)

data InitialAgentServers = InitialAgentServers
  { smp :: NonEmpty SMPServer,
    ntf :: [NtfServer]
  }

data AgentConfig = AgentConfig
  { tcpPort :: ServiceName,
    cmdSignAlg :: C.SignAlg,
    connIdBytes :: Int,
    tbqSize :: Natural,
    dbFile :: FilePath,
    dbPoolSize :: Int,
    yesToMigrations :: Bool,
    smpCfg :: ProtocolClientConfig,
    ntfCfg :: ProtocolClientConfig,
    reconnectInterval :: RetryInterval,
    helloTimeout :: NominalDiffTime,
    resubscriptionConcurrency :: Int,
    caCertificateFile :: FilePath,
    privateKeyFile :: FilePath,
    certificateFile :: FilePath,
    smpAgentVersion :: Version,
    smpAgentVRange :: VersionRange
  }

defaultReconnectInterval :: RetryInterval
defaultReconnectInterval =
  RetryInterval
    { initialInterval = second,
      increaseAfter = 10 * second,
      maxInterval = 10 * second
    }
  where
    second = 1_000_000

defaultAgentConfig :: AgentConfig
defaultAgentConfig =
  AgentConfig
    { tcpPort = "5224",
      cmdSignAlg = C.SignAlg C.SEd448,
      connIdBytes = 12,
      tbqSize = 64,
      dbFile = "smp-agent.db",
      dbPoolSize = 1,
      yesToMigrations = False,
      smpCfg = defaultClientConfig {defaultTransport = ("5223", transport @TLS)},
      ntfCfg = defaultClientConfig {defaultTransport = ("443", transport @TLS)},
      reconnectInterval = defaultReconnectInterval,
      helloTimeout = 2 * nominalDay,
      resubscriptionConcurrency = 16,
      -- CA certificate private key is not needed for initialization
      -- ! we do not generate these
      caCertificateFile = "/etc/opt/simplex-agent/ca.crt",
      privateKeyFile = "/etc/opt/simplex-agent/agent.key",
      certificateFile = "/etc/opt/simplex-agent/agent.crt",
      smpAgentVersion = currentSMPAgentVersion,
      smpAgentVRange = supportedSMPAgentVRange
    }

data Env = Env
  { config :: AgentConfig,
    store :: SQLiteStore,
    idsDrg :: TVar ChaChaDRG,
    clientCounter :: TVar Int,
    randomServer :: TVar StdGen,
    ntfSupervisor :: NtfSupervisor
  }

newSMPAgentEnv :: (MonadUnliftIO m, MonadRandom m) => AgentConfig -> m Env
newSMPAgentEnv config@AgentConfig {dbFile, dbPoolSize, yesToMigrations} = do
  idsDrg <- newTVarIO =<< drgNew
  store <- liftIO $ createSQLiteStore dbFile dbPoolSize Migrations.app yesToMigrations
  clientCounter <- newTVarIO 0
  randomServer <- newTVarIO =<< liftIO newStdGen
  ntfSupervisor <- atomically . newNtfSubSupervisor $ tbqSize config
  return Env {config, store, idsDrg, clientCounter, randomServer, ntfSupervisor}

data NtfSupervisor = NtfSupervisor
  { ntfTkn :: TVar (Maybe NtfToken),
    ntfSubQ :: TBQueue (RcvQueue, NtfSupervisorCommand),
    ntfWorkers :: TMap NtfServer (TMVar (), Async ()),
    ntfSMPWorkers :: TMap SMPServer (TMVar (), Async ())
  }

data NtfSupervisorCommand = NSCCreate | NSCDelete

newNtfSubSupervisor :: Natural -> STM NtfSupervisor
newNtfSubSupervisor qSize = do
  ntfTkn <- newTVar Nothing
  ntfSubQ <- newTBQueue qSize
  ntfWorkers <- TM.empty
  ntfSMPWorkers <- TM.empty
  pure NtfSupervisor {ntfTkn, ntfSubQ, ntfWorkers, ntfSMPWorkers}

withStore :: AgentMonad m => (forall m'. AgentStoreMonad m' => SQLiteStore -> m' a) -> m a
withStore action = do
  st <- asks store
  runExceptT (action st `E.catch` handleInternal) >>= \case
    Right c -> return c
    Left e -> throwError $ storeError e
  where
    -- TODO when parsing exception happens in store, the agent hangs;
    -- changing SQLError to SomeException does not help
    handleInternal :: (MonadError StoreError m') => SQLError -> m' a
    handleInternal e = throwError . SEInternal $ bshow e
    storeError :: StoreError -> AgentErrorType
    storeError = \case
      SEConnNotFound -> CONN NOT_FOUND
      SEConnDuplicate -> CONN DUPLICATE
      SEBadConnType CRcv -> CONN SIMPLEX
      SEBadConnType CSnd -> CONN SIMPLEX
      SEInvitationNotFound -> CMD PROHIBITED
      -- this error is never reported as store error,
      -- it is used to wrap agent operations when "transaction-like" store access is needed
      -- NOTE: network IO should NOT be used inside AgentStoreMonad
      SEAgentError e -> e
      e -> INTERNAL $ show e
