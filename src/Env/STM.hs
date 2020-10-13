{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NamedFieldPuns #-}

module Env.STM where

import ConnStore.STM
import Control.Concurrent.STM
import qualified Data.Map as M
import qualified Data.Set as S
import Network.Socket (ServiceName)
import System.IO
import Transmission

data Env = Env
  { tcpPort :: ServiceName,
    server :: TVar Server,
    connStore :: TVar ConnStoreData
  }

data Server = Server
  { clients :: S.Set Client,
    connections :: M.Map RecipientId Client
  }

data Client = Client
  { handle :: Handle,
    connections :: S.Set RecipientId,
    channel :: TChan SomeSigned
  }

newServer :: STM (TVar Server)
newServer = newTVar $ Server {clients = S.empty, connections = M.empty}

newClient :: Handle -> STM Client
newClient h = do
  c <- newTChan
  return Client {handle = h, connections = S.empty, channel = c}

newEnv :: String -> STM Env
newEnv tcpPort = do
  srv <- newServer
  st <- newConnStore
  return Env {tcpPort, server = srv, connStore = st}
