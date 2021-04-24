{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# OPTIONS_GHC -fno-warn-unticked-promoted-constructors #-}

module Simplex.Messaging.Agent.Env.SQLite where

import Control.Monad.IO.Unlift
import Crypto.Random
import Network.Socket
import Numeric.Natural
import Simplex.Messaging.Agent.Store.SQLite
import Simplex.Messaging.Client
import UnliftIO.STM

data AgentConfig = AgentConfig
  { tcpPort :: ServiceName,
    rsaKeySize :: Int,
    connIdBytes :: Int,
    tbqSize :: Natural,
    dbFile :: FilePath,
    smpCfg :: SMPClientConfig
  }

data Env = Env
  { config :: AgentConfig,
    idsDrg :: TVar ChaChaDRG,
    clientCounter :: TVar Int,
    reservedMsgSize :: Int
    -- paddedMsgSize :: Int
  }

newSMPAgentEnv :: (MonadUnliftIO m, MonadRandom m) => AgentConfig -> m Env
newSMPAgentEnv config = do
  idsDrg <- drgNew >>= newTVarIO
  _ <- createSQLiteStore $ dbFile config
  clientCounter <- newTVarIO 0
  return Env {config, idsDrg, clientCounter, reservedMsgSize}
  where
    -- 1st rsaKeySize is used by the RSA signature in each command,
    -- 2nd - by encrypted message body header
    -- 3rd - by encrypted message signature
    -- smpCommandSize - is the estimated max size for SMP command, queueId, corrId
    reservedMsgSize = 3 * rsaKeySize config + smpCommandSize (smpCfg config)
