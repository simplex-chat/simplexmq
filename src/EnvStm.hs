{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NamedFieldPuns #-}

module EnvStm where

import Control.Concurrent.STM
import qualified Data.Map as M
import qualified Data.Set as S
import Store
import System.IO
import Transmission

data Env = Env
  { port :: String,
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

newEnv :: String -> STM Env
newEnv port = do
  srv <- newServer
  st <- newConnStore
  return Env {port, server = srv, connStore = st}
