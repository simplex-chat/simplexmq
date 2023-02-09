{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Simplex.Messaging.Transport.HTTP2.Client where

import Control.Concurrent.Async
import Control.Exception (IOException)
import qualified Control.Exception as E
import Control.Monad.Except
import Data.ByteString.Char8 (ByteString)
import Data.Time (UTCTime, getCurrentTime)
import qualified Data.X509.CertificateStore as XS
import Network.HPACK (BufferSize)
import Network.HTTP2.Client (ClientConfig (..), Request, Response)
import qualified Network.HTTP2.Client as H
import Network.Socket (HostName, ServiceName)
import qualified Network.TLS as T
import Numeric.Natural (Natural)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Transport (SessionId)
import Simplex.Messaging.Transport.Client (TransportClientConfig (..), TransportHost (..), runTLSTransportClient)
import Simplex.Messaging.Transport.HTTP2 (HTTP2Body, getHTTP2Body, http2TLSParams, withHTTP2)
import UnliftIO.STM
import UnliftIO.Timeout

data HTTP2Client = HTTP2Client
  { action :: Maybe (Async ()),
    sessionId :: SessionId,
    sessionTs :: UTCTime,
    client_ :: HClient
  }

data HClient = HClient
  { connected :: TVar Bool,
    host :: TransportHost,
    port :: ServiceName,
    config :: HTTP2ClientConfig,
    reqQ :: TBQueue (Request, TMVar HTTP2Response)
  }

data HTTP2Response = HTTP2Response
  { response :: Response,
    respBody :: HTTP2Body
  }

data HTTP2ClientConfig = HTTP2ClientConfig
  { qSize :: Natural,
    connTimeout :: Int,
    transportConfig :: TransportClientConfig,
    bufferSize :: BufferSize,
    bodyHeadSize :: Int,
    -- maxBodySize :: Int,
    suportedTLSParams :: T.Supported
  }
  deriving (Show)

defaultHTTP2ClientConfig :: HTTP2ClientConfig
defaultHTTP2ClientConfig =
  HTTP2ClientConfig
    { qSize = 64,
      connTimeout = 10000000,
      transportConfig = TransportClientConfig Nothing Nothing True,
      bufferSize = 32768,
      bodyHeadSize = 16384,
      -- maxBodySize = 16793600, -- 16 MB + 16kb
      suportedTLSParams = http2TLSParams
    }

data HTTP2ClientError = HCResponseTimeout | HCNetworkError | HCIOError IOException
  deriving (Show)

getHTTP2Client :: HostName -> ServiceName -> Maybe XS.CertificateStore -> HTTP2ClientConfig -> IO () -> IO (Either HTTP2ClientError HTTP2Client)
getHTTP2Client host port = getVerifiedHTTP2Client Nothing (THDomainName host) port Nothing

getVerifiedHTTP2Client :: Maybe ByteString -> TransportHost -> ServiceName -> Maybe C.KeyHash -> Maybe XS.CertificateStore -> HTTP2ClientConfig -> IO () -> IO (Either HTTP2ClientError HTTP2Client)
getVerifiedHTTP2Client proxyUsername host port keyHash caStore config@HTTP2ClientConfig {transportConfig, bufferSize, bodyHeadSize, connTimeout, suportedTLSParams} disconnected =
  (atomically mkHTTPS2Client >>= runClient)
    `E.catch` \(e :: IOException) -> pure . Left $ HCIOError e
  where
    mkHTTPS2Client :: STM HClient
    mkHTTPS2Client = do
      connected <- newTVar False
      reqQ <- newTBQueue $ qSize config
      pure HClient {connected, host, port, config, reqQ}

    runClient :: HClient -> IO (Either HTTP2ClientError HTTP2Client)
    runClient c = do
      cVar <- newEmptyTMVarIO
      action <-
        async $
          runHTTP2Client suportedTLSParams caStore transportConfig bufferSize proxyUsername host port keyHash (client c cVar)
            `E.finally` atomically (putTMVar cVar $ Left HCNetworkError)
      c_ <- connTimeout `timeout` atomically (takeTMVar cVar)
      pure $ case c_ of
        Just (Right c') -> Right c' {action = Just action}
        Just (Left e) -> Left e
        Nothing -> Left HCNetworkError

    client :: HClient -> TMVar (Either HTTP2ClientError HTTP2Client) -> SessionId -> H.Client ()
    client c cVar sessionId sendReq = do
      sessionTs <- getCurrentTime
      let c' = HTTP2Client {action = Nothing, client_ = c, sessionId, sessionTs}
      atomically $ do
        writeTVar (connected c) True
        putTMVar cVar (Right c')
      process c' sendReq `E.finally` disconnected

    process :: HTTP2Client -> H.Client ()
    process HTTP2Client {client_ = HClient {reqQ}} sendReq = forever $ do
      (req, respVar) <- atomically $ readTBQueue reqQ
      sendReq req $ \r -> do
        respBody <- getHTTP2Body r bodyHeadSize
        atomically $ putTMVar respVar HTTP2Response {response = r, respBody}

-- | Disconnects client from the server and terminates client threads.
closeHTTP2Client :: HTTP2Client -> IO ()
closeHTTP2Client = mapM_ uninterruptibleCancel . action

sendRequest :: HTTP2Client -> Request -> IO (Either HTTP2ClientError HTTP2Response)
sendRequest HTTP2Client {client_ = HClient {config, reqQ}} req = do
  resp <- newEmptyTMVarIO
  atomically $ writeTBQueue reqQ (req, resp)
  maybe (Left HCResponseTimeout) Right <$> (connTimeout config `timeout` atomically (takeTMVar resp))

runHTTP2Client :: T.Supported -> Maybe XS.CertificateStore -> TransportClientConfig -> BufferSize -> Maybe ByteString -> TransportHost -> ServiceName -> Maybe C.KeyHash -> (SessionId -> H.Client ()) -> IO ()
runHTTP2Client tlsParams caStore tcConfig bufferSize proxyUsername host port keyHash client =
  runTLSTransportClient tlsParams caStore tcConfig proxyUsername host port keyHash $ withHTTP2 bufferSize run
  where
    run cfg = H.run (ClientConfig "https" (strEncode host) 20) cfg . client
