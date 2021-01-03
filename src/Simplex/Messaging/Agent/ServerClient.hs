{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Simplex.Messaging.Agent.ServerClient where

import Control.Monad
import Control.Monad.IO.Unlift
import Network.Socket (HostName, ServiceName)
import Numeric.Natural
import qualified Simplex.Messaging.Server.Transmission as SMP
import Simplex.Messaging.Transport
import UnliftIO.Async
import UnliftIO.IO
import UnliftIO.STM

data ServerClientConfig = ServerClientConfig
  { tbqSize :: Natural,
    corrIdBytes :: Natural
  }

data ServerClient = ServerClient
  { smpSndQ :: TBQueue SMP.Transmission,
    smpRcvQ :: TBQueue SMP.TransmissionOrError
    -- srvA :: Async ()
  }

newServerClient ::
  forall m.
  MonadUnliftIO m =>
  ServerClientConfig ->
  TBQueue SMP.TransmissionOrError ->
  HostName ->
  ServiceName ->
  m ServerClient
newServerClient cfg smpRcvQ host port = do
  smpSndQ <- atomically . newTBQueue $ tbqSize cfg
  let c = ServerClient {smpSndQ, smpRcvQ}
  _srvA <- async $ runTCPClient host p (client c)
  -- TODO because exception can be thrown inside async it is not caught by newSMPServer
  -- there possibly needs to be another channel to communicate with ServerClient if it fails
  -- alternatively, there may be just timeout on sent commands -
  -- in this case late responses should be just ignored rather than result in smpErrCorrelationId
  return c
  where
    client :: ServerClient -> Handle -> m ()
    client c h = do
      _line <- getLn h -- "Welcome to SMP"
      -- TODO test connection failure
      send c h `race_` receive h

    send :: ServerClient -> Handle -> m ()
    send ServerClient {smpSndQ} h = forever $ atomically (readTBQueue smpSndQ) >>= SMP.tPut h

    receive :: Handle -> m ()
    receive h = forever $ SMP.tGet SMP.fromServer h >>= atomically . writeTBQueue smpRcvQ
