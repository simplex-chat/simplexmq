{-# LANGUAGE NamedFieldPuns #-}

module Simplex.Messaging.Transport.HTTP2.Server where

import Control.Concurrent.Async (Async, async, uninterruptibleCancel)
import Control.Concurrent.STM
import Control.Monad
import Data.Time.Clock.System (getSystemTime, systemSeconds)
import Network.HPACK (BufferSize)
import Network.HTTP2.Server (Request, Response)
import qualified Network.HTTP2.Server as H
import Network.Socket
import qualified Network.TLS as T
import Numeric.Natural (Natural)
import Simplex.Messaging.Server.Expiration
import Simplex.Messaging.Transport (ALPN, SessionId, TLS, closeConnection, tlsALPN, tlsUniq)
import Simplex.Messaging.Transport.HTTP2
import Simplex.Messaging.Transport.Server (TransportServerConfig (..), loadSupportedTLSServerParams, runTransportServer)
import Simplex.Messaging.Util (threadDelay', atomically')
import UnliftIO (finally)
import UnliftIO.Concurrent (forkIO, killThread)

type HTTP2ServerFunc = SessionId -> Maybe ALPN -> Request -> (Response -> IO ()) -> IO ()

data HTTP2ServerConfig = HTTP2ServerConfig
  { qSize :: Natural,
    http2Port :: ServiceName,
    bufferSize :: BufferSize,
    bodyHeadSize :: Int,
    serverSupported :: T.Supported,
    caCertificateFile :: FilePath,
    privateKeyFile :: FilePath,
    certificateFile :: FilePath,
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
getHTTP2Server HTTP2ServerConfig {qSize, http2Port, bufferSize, bodyHeadSize, serverSupported, caCertificateFile, certificateFile, privateKeyFile, transportConfig} = do
  tlsServerParams <- loadSupportedTLSServerParams serverSupported caCertificateFile certificateFile privateKeyFile
  started <- newEmptyTMVarIO
  reqQ <- newTBQueueIO qSize
  action <- async $
    runHTTP2Server started http2Port bufferSize tlsServerParams transportConfig Nothing (const $ pure ()) $ \sessionId sessionALPN r sendResponse -> do
      reqBody <- getHTTP2Body r bodyHeadSize
      atomically $ writeTBQueue reqQ HTTP2Request {sessionId, sessionALPN, request = r, reqBody, sendResponse}
  void . atomically' $ takeTMVar started
  pure HTTP2Server {action, reqQ}

closeHTTP2Server :: HTTP2Server -> IO ()
closeHTTP2Server = uninterruptibleCancel . action

runHTTP2Server :: TMVar Bool -> ServiceName -> BufferSize -> T.ServerParams -> TransportServerConfig -> Maybe ExpirationConfig -> (SessionId -> IO ()) -> HTTP2ServerFunc -> IO ()
runHTTP2Server started port bufferSize serverParams transportConfig expCfg_ clientFinished = runHTTP2ServerWith_ expCfg_ clientFinished bufferSize setup
  where
    setup = runTransportServer started port serverParams transportConfig

runHTTP2ServerWith :: BufferSize -> ((TLS -> IO ()) -> a) -> HTTP2ServerFunc -> a
runHTTP2ServerWith = runHTTP2ServerWith_ Nothing (\_sessId -> pure ())

runHTTP2ServerWith_ :: Maybe ExpirationConfig -> (SessionId -> IO ()) -> BufferSize -> ((TLS -> IO ()) -> a) -> HTTP2ServerFunc -> a
runHTTP2ServerWith_ expCfg_ clientFinished bufferSize setup http2Server = setup $ \tls -> do
  activeAt <- newTVarIO =<< getSystemTime
  tid_ <- mapM (forkIO . expireInactiveClient tls activeAt) expCfg_
  withHTTP2 bufferSize (run tls activeAt) (clientFinished $ tlsUniq tls) tls `finally` mapM_ killThread tid_
  where
    run tls activeAt cfg = H.run cfg $ \req _aux sendResp -> do
      getSystemTime >>= atomically . writeTVar activeAt
      http2Server (tlsUniq tls) (tlsALPN tls) req (`sendResp` [])
    expireInactiveClient tls activeAt expCfg = loop
      where
        loop = do
          threadDelay' $ checkInterval expCfg * 1000000
          old <- expireBeforeEpoch expCfg
          ts <- readTVarIO activeAt
          if systemSeconds ts < old
            then closeConnection tls
            else loop
