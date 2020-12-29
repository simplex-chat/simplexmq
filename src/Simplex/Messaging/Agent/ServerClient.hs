{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Simplex.Messaging.Agent.ServerClient where

import Control.Monad
import Control.Monad.IO.Unlift
import Data.Maybe
import Network.Socket (HostName, ServiceName)
import Numeric.Natural
import Simplex.Messaging.Agent.Store
import qualified Simplex.Messaging.Server.Transmission as SMP
import Simplex.Messaging.Transport
import UnliftIO.Async
import UnliftIO.IO
import UnliftIO.STM

data ServerClientConfig = ServerClientConfig
  { tcpPort :: ServiceName,
    tbqSize :: Natural,
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
  Maybe ServiceName ->
  m ServerClient
newServerClient cfg smpRcvQ host port = do
  smpSndQ <- atomically . newTBQueue $ tbqSize cfg
  let c = ServerClient {smpSndQ, smpRcvQ}
  _srvA <- async $ runClient (fromMaybe (tcpPort cfg) port) c
  return c
  where
    runClient :: ServiceName -> ServerClient -> m ()
    runClient p c = do
      liftIO $ print (host, p)
      runTCPClient host p $ \h -> do
        liftIO $ putStrLn "SMP connected"
        _line <- getLn h -- "Welcome to SMP"
        liftIO $ print _line
        -- TODO test connection failure
        race_ (send h c) (receive h)

    send :: Handle -> ServerClient -> m ()
    send h ServerClient {smpSndQ} = forever $ atomically (readTBQueue smpSndQ) >>= SMP.tPut h

    receive :: Handle -> m ()
    receive h = forever $ SMP.tGet SMP.fromServer h >>= atomically . writeTBQueue smpRcvQ
