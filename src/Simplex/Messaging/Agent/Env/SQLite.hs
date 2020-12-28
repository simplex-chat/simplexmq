{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# OPTIONS_GHC -fno-warn-unticked-promoted-constructors #-}

module Simplex.Messaging.Agent.Env.SQLite where

import Control.Monad.IO.Unlift
import Crypto.Random
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import qualified Database.SQLite.Simple as DB
import Network.Socket (HostName, ServiceName)
import Numeric.Natural
import Simplex.Messaging.Agent.Store.SQLite.Schema
import Simplex.Messaging.Agent.Transmission
import qualified Simplex.Messaging.Server.Transmission as SMP
import UnliftIO.STM

data AgentConfig = AgentConfig
  { tcpPort :: ServiceName,
    tbqSize :: Natural,
    connIdBytes :: Int,
    dbFile :: String
  }

data Env = Env
  { config :: AgentConfig,
    idsDrg :: TVar ChaChaDRG,
    db :: DB.Connection
  }

data AgentClient = AgentClient
  { rcvQ :: TBQueue (ACommand Client),
    sndQ :: TBQueue (ACommand Agent),
    respQ :: TBQueue (),
    servers :: Map (HostName, ServiceName) ServerClient
  }

data ServerClient = ServerClient
  { sndQ :: TBQueue SMP.Transmission,
    commands :: Map SMP.QueueId (TBQueue SMP.Cmd)
  }

newAgentClient :: Natural -> STM AgentClient
newAgentClient qSize = do
  rcvQ <- newTBQueue qSize
  sndQ <- newTBQueue qSize
  respQ <- newTBQueue qSize
  return AgentClient {rcvQ, sndQ, respQ, servers = M.empty}

newServerClient :: Natural -> STM ServerClient
newServerClient qSize = do
  sndQ <- newTBQueue qSize
  return ServerClient {sndQ, commands = M.empty}

openDB :: MonadUnliftIO m => AgentConfig -> m DB.Connection
openDB AgentConfig {dbFile} = liftIO $ do
  db <- DB.open dbFile
  createSchema db
  return db

newEnv :: (MonadUnliftIO m, MonadRandom m) => AgentConfig -> m Env
newEnv config = do
  idsDrg <- drgNew >>= newTVarIO
  db <- openDB config
  return Env {config, idsDrg, db}
