{-# LANGUAGE DataKinds #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# OPTIONS_GHC -fno-warn-unticked-promoted-constructors #-}

module Simplex.Messaging.Agent.Env where

import Control.Monad.IO.Unlift
import Crypto.Random
import Network.Socket (ServiceName)
import Numeric.Natural
import Simplex.Messaging.Agent.Command
import UnliftIO.STM

data AgentConfig = AgentConfig
  { tcpPort :: ServiceName,
    tbqSize :: Natural,
    connIdBytes :: Int
  }

data Env = Env
  { config :: AgentConfig,
    idsDrg :: TVar ChaChaDRG
  }

data AgentClient = AgentClient
  { rcvQ :: TBQueue (Either ErrorType (ACommand User)),
    sndQ :: TBQueue (ACommand Agent)
  }

newAgentClient :: Natural -> STM AgentClient
newAgentClient qSize = do
  rcvQ <- newTBQueue qSize
  sndQ <- newTBQueue qSize
  return AgentClient {rcvQ, sndQ}

newEnv :: (MonadUnliftIO m, MonadRandom m) => AgentConfig -> m Env
newEnv config = do
  idsDrg <- drgNew >>= newTVarIO
  return Env {config, idsDrg}
