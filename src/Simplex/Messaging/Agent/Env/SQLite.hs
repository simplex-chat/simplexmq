{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# OPTIONS_GHC -fno-warn-unticked-promoted-constructors #-}

module Simplex.Messaging.Agent.Env.SQLite where

import Control.Monad.IO.Unlift
import Crypto.Random
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Network.Socket
import Numeric.Natural
import Simplex.Messaging.Agent.Store.SQLite
import Simplex.Messaging.Agent.Transmission
import Simplex.Messaging.Client
import UnliftIO.STM

data AgentConfig = AgentConfig
  { tcpPort :: ServiceName,
    tbqSize :: Natural,
    connIdBytes :: Int,
    dbFile :: String,
    smpCfg :: SMPClientConfig
  }

data Env = Env
  { config :: AgentConfig,
    idsDrg :: TVar ChaChaDRG,
    db :: SQLiteStore,
    clientCounter :: TVar Int
  }

data AgentClient = AgentClient
  { rcvQ :: TBQueue (ATransmission Client),
    sndQ :: TBQueue (ATransmission Agent),
    msgQ :: TBQueue SMPServerTransmission,
    smpClients :: TVar (Map SMPServer SMPClient),
    clientId :: Int
  }

newAgentClient :: TVar Int -> Natural -> STM AgentClient
newAgentClient cc qSize = do
  rcvQ <- newTBQueue qSize
  sndQ <- newTBQueue qSize
  msgQ <- newTBQueue qSize
  smpClients <- newTVar M.empty
  clientId <- (+ 1) <$> readTVar cc
  writeTVar cc clientId
  return AgentClient {rcvQ, sndQ, msgQ, smpClients, clientId}

newEnv :: (MonadUnliftIO m, MonadRandom m) => AgentConfig -> m Env
newEnv config = do
  idsDrg <- drgNew >>= newTVarIO
  db <- newSQLiteStore $ dbFile config
  clientCounter <- newTVarIO 0
  return Env {config, idsDrg, db, clientCounter}
