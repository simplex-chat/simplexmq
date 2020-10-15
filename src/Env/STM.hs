{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NamedFieldPuns #-}

module Env.STM where

import ConnStore.STM
import Control.Concurrent.STM
import qualified Data.Map as M
import qualified Data.Set as S
import Network.Socket (ServiceName)
import Numeric.Natural
import Transmission

data Env = Env
  { tcpPort :: ServiceName,
    queueSize :: Natural,
    server :: TVar Server,
    connStore :: TVar ConnStoreData
  }

data Server = Server
  { clients :: S.Set Client,
    connections :: M.Map RecipientId Client
  }

data Client = Client
  { connections :: S.Set RecipientId,
    rcvQ :: TBQueue Signed,
    sndQ :: TBQueue Signed
  }

newServer :: STM (TVar Server)
newServer = newTVar $ Server {clients = S.empty, connections = M.empty}

newClient :: Natural -> STM Client
newClient qSize = do
  rcvQ <- newTBQueue qSize
  sndQ <- newTBQueue qSize
  return Client {connections = S.empty, rcvQ, sndQ}

newEnv :: String -> Natural -> STM Env
newEnv tcpPort queueSize = do
  srv <- newServer
  st <- newConnStore
  return Env {tcpPort, queueSize, server = srv, connStore = st}
