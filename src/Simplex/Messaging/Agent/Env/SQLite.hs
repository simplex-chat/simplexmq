{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# OPTIONS_GHC -fno-warn-unticked-promoted-constructors #-}

module Simplex.Messaging.Agent.Env.SQLite where

import Control.Monad.IO.Unlift
import Crypto.Random
import Data.List.NonEmpty (NonEmpty)
import Network.Socket
import Numeric.Natural
import Simplex.Messaging.Agent.Protocol (SMPServer)
import Simplex.Messaging.Agent.Store.SQLite
import qualified Simplex.Messaging.Agent.Store.SQLite.Migrations as Migrations
import Simplex.Messaging.Client
import System.Random (StdGen, newStdGen)
import UnliftIO.STM

data AgentConfig = AgentConfig
  { tcpPort :: ServiceName,
    smpServers :: NonEmpty SMPServer,
    rsaKeySize :: Int,
    connIdBytes :: Int,
    tbqSize :: Natural,
    dbFile :: FilePath,
    dbPoolSize :: Int,
    smpCfg :: SMPClientConfig
  }

data Env = Env
  { config :: AgentConfig,
    store' :: SQLiteStore,
    idsDrg :: TVar ChaChaDRG,
    clientCounter :: TVar Int,
    reservedMsgSize :: Int,
    randomServer :: TVar StdGen
  }

newSMPAgentEnv :: (MonadUnliftIO m, MonadRandom m) => AgentConfig -> m Env
newSMPAgentEnv cfg = do
  idsDrg <- newTVarIO =<< drgNew
  store' <- liftIO $ createSQLiteStore (dbFile cfg) (dbPoolSize cfg) Migrations.app
  clientCounter <- newTVarIO 0
  randomServer <- newTVarIO =<< liftIO newStdGen
  return Env {config = cfg, store', idsDrg, clientCounter, reservedMsgSize, randomServer}
  where
    -- 1st rsaKeySize is used by the RSA signature in each command,
    -- 2nd - by encrypted message body header
    -- 3rd - by message signature
    -- smpCommandSize - is the estimated max size for SMP command, queueId, corrId
    reservedMsgSize = 3 * rsaKeySize cfg + smpCommandSize (smpCfg cfg)
