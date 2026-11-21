{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}

module Simplex.Messaging.Transport.HTTP2.Server where

import Control.Concurrent.Async (Async, async, uninterruptibleCancel)
import Control.Concurrent.STM
import Control.Monad
import Data.Maybe (catMaybes)
import Data.Time.Clock.System (SystemTime, getSystemTime, systemSeconds)
import Network.HPACK (BufferSize)
import Network.HTTP2.Server (Request, Response)
import qualified Network.HTTP2.Server as H
import Network.Socket
import qualified Network.TLS as T
import Numeric.Natural (Natural)
import Simplex.Messaging.Server.Expiration
import Simplex.Messaging.Transport (ALPN, SessionId, TLS, tlsALPN, tlsUniq)
import Simplex.Messaging.Transport.HTTP2
import Simplex.Messaging.Transport.Server (ReloadableCredential, SNICredentialUsed, ServerCredentials, SocketState, TLSServerCredential (..), TransportServerConfig (..), loadServerCredential, newSocketState, runTransportServerState_)
import Simplex.Messaging.Util (threadDelay')
import UnliftIO (bracket_, finally)
import UnliftIO.Concurrent (forkIO, killThread, myThreadId, threadDelay)

type HTTP2ServerFunc = SessionId -> Maybe ALPN -> Request -> (Response -> IO ()) -> IO ()

data HTTP2ServerConfig = HTTP2ServerConfig
  { qSize :: Natural,
    http2Port :: ServiceName,
    bufferSize :: BufferSize,
    bodyHeadSize :: Int,
    serverSupported :: T.Supported,
    https2Credentials :: ServerCredentials,
    transportConfig :: TransportServerConfig
  }
  deriving (Show)

data HTTP2Request = HTTP2Request
  { sessionId :: SessionId,
    sessionALPN :: Maybe ALPN,
    request :: Request,
    reqBody :: HTTP2Body,
    sendResponse :: Response -> IO ()
  }

data HTTP2Server = HTTP2Server
  { action :: Async (),
    reqQ :: TBQueue HTTP2Request
  }

-- This server is for testing only, it processes all requests in a single queue.
getHTTP2Server :: HTTP2ServerConfig -> IO HTTP2Server
getHTTP2Server HTTP2ServerConfig {qSize, http2Port, bufferSize, bodyHeadSize, serverSupported, https2Credentials, transportConfig} = do
  srvCreds <- loadServerCredential https2Credentials
  started <- newEmptyTMVarIO
  reqQ <- newTBQueueIO qSize
  action <- async $
    newSocketState >>= \ss -> runHTTP2Server ss started http2Port bufferSize serverSupported srvCreds Nothing transportConfig Nothing (const $ pure ()) $ \_sniUsed _closeSession sessionId sessionALPN r sendResponse -> do
      reqBody <- getHTTP2Body r bodyHeadSize
      atomically $ writeTBQueue reqQ HTTP2Request {sessionId, sessionALPN, request = r, reqBody, sendResponse}
  void . atomically $ takeTMVar started
  pure HTTP2Server {action, reqQ}

closeHTTP2Server :: HTTP2Server -> IO ()
closeHTTP2Server = uninterruptibleCancel . action

runHTTP2Server :: SocketState -> TMVar Bool -> ServiceName -> BufferSize -> T.Supported -> T.Credential -> Maybe ReloadableCredential -> TransportServerConfig -> Maybe ExpirationConfig -> (SessionId -> IO ()) -> (SNICredentialUsed -> IO () -> HTTP2ServerFunc) -> IO ()
runHTTP2Server ss started port bufferSize srvSupported srvCreds httpCreds_ transportConfig expCfg_ clientFinished = runHTTP2ServerWith_ expCfg_ (Just $ firstRequestTimeout transportConfig) clientFinished bufferSize setup
  where
    setup handler = do
      let combinedCreds = TLSServerCredential {credential = srvCreds, sniCredential = httpCreds_}
      runTransportServerState_ ss started port srvSupported combinedCreds transportConfig $ \_ -> handler

-- HTTP2 server can be run on both client and server TLS connections.
runHTTP2ServerWith :: BufferSize -> ((TLS p -> IO ()) -> a) -> HTTP2ServerFunc -> a
runHTTP2ServerWith bufferSize tlsSetup http2Server =
  runHTTP2ServerWith_
    Nothing
    Nothing
    (\_sessId -> pure ())
    bufferSize
    (\handler -> tlsSetup $ \tls -> handler (False, tls))
    (\_ _ -> http2Server)

runHTTP2ServerWith_ :: Maybe ExpirationConfig -> Maybe Int -> (SessionId -> IO ()) -> BufferSize -> (((SNICredentialUsed, TLS p) -> IO ()) -> a) -> (SNICredentialUsed -> IO () -> HTTP2ServerFunc) -> a
runHTTP2ServerWith_ expCfg_ firstRequestTimeout_ clientFinished bufferSize setup http2Server = setup $ \(sniUsed, tls) -> do
  activity <- newClientActivity
  sessionThread <- myThreadId
  tids <-
    sequence $
      catMaybes
        [ forkIO . expireInactiveClient sessionThread activity <$> expCfg_,
          forkIO . closeWithoutRequest sessionThread activity <$> firstRequestTimeout_
        ]
  withHTTP2 bufferSize (run sniUsed tls sessionThread activity) (clientFinished $ tlsUniq tls) tls `finally` mapM_ killThread tids
  where
    run sniUsed tls sessionThread activity cfg = H.run cfg $ \req _aux sendResp ->
      trackRequest activity $ http2Server sniUsed (killThread sessionThread) (tlsUniq tls) (tlsALPN tls) req (`sendResp` [])
    expireInactiveClient sessionThread activity expCfg = loop
      where
        loop = do
          threadDelay' $ checkInterval expCfg * 1000000
          old <- expireBeforeEpoch expCfg
          idle <- idleSince <$> readTVarIO activity
          if maybe False ((< old) . systemSeconds) idle
            then killThread sessionThread
            else loop
    closeWithoutRequest sessionThread activity t = do
      threadDelay t
      readTVarIO activity >>= \case
        NoRequestSince _ -> killThread sessionThread
        _ -> pure ()

data ClientActivity
  = NoRequestSince SystemTime
  | RequestsInFlight Int
  | IdleSince SystemTime

idleSince :: ClientActivity -> Maybe SystemTime
idleSince = \case
  NoRequestSince ts -> Just ts
  RequestsInFlight _ -> Nothing
  IdleSince ts -> Just ts

newClientActivity :: IO (TVar ClientActivity)
newClientActivity = newTVarIO . NoRequestSince =<< getSystemTime

trackRequest :: TVar ClientActivity -> IO a -> IO a
trackRequest activity = bracket_ started ended
  where
    started = atomically $ modifyTVar' activity $ \case
      RequestsInFlight n -> RequestsInFlight (n + 1)
      _ -> RequestsInFlight 1
    ended = do
      ts <- getSystemTime
      atomically $ modifyTVar' activity $ \case
        RequestsInFlight n | n > 1 -> RequestsInFlight (n - 1)
        _ -> IdleSince ts
