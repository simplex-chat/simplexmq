{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Simplex.Messaging.Transport.HTTP2.Client where

import Control.Concurrent.Async
import Control.Exception (IOException, try)
import qualified Control.Exception as E
import Control.Monad
import Data.ByteString.Char8 (ByteString)
import Data.Functor (($>))
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
import Simplex.Messaging.Transport (SessionId, TLS)
import Simplex.Messaging.Transport.Client (TransportClientConfig (..), TransportHost (..), runTLSTransportClient)
import Simplex.Messaging.Transport.HTTP2
import UnliftIO.STM
import UnliftIO.Timeout

data HTTP2Client = HTTP2Client
  { action :: Maybe (Async HTTP2Response),
    sessionId :: SessionId,
    sessionTs :: UTCTime,
    sendReq :: Request -> (Response -> IO HTTP2Response) -> IO HTTP2Response,
    client_ :: HClient
  }

data HClient = HClient
  { connected :: TVar Bool,
    disconnected :: IO (),
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
    suportedTLSParams :: T.Supported
  }
  deriving (Show)

defaultHTTP2ClientConfig :: HTTP2ClientConfig
defaultHTTP2ClientConfig =
  HTTP2ClientConfig
    { qSize = 64,
      connTimeout = 10000000,
      transportConfig = TransportClientConfig Nothing Nothing True Nothing,
      bufferSize = defaultHTTP2BufferSize,
      bodyHeadSize = 16384,
      suportedTLSParams = http2TLSParams
    }

data HTTP2ClientError = HCResponseTimeout | HCNetworkError | HCIOError IOException
  deriving (Show)

getHTTP2Client :: HostName -> ServiceName -> Maybe XS.CertificateStore -> HTTP2ClientConfig -> IO () -> IO (Either HTTP2ClientError HTTP2Client)
getHTTP2Client host port = getVerifiedHTTP2Client Nothing (THDomainName host) port Nothing

getVerifiedHTTP2Client :: Maybe ByteString -> TransportHost -> ServiceName -> Maybe C.KeyHash -> Maybe XS.CertificateStore -> HTTP2ClientConfig -> IO () -> IO (Either HTTP2ClientError HTTP2Client)
getVerifiedHTTP2Client proxyUsername host port keyHash caStore config disconnected = getVerifiedHTTP2ClientWith config host port disconnected setup
  where
    setup = runHTTP2Client (suportedTLSParams config) caStore (transportConfig config) (bufferSize config) proxyUsername host port keyHash

attachHTTP2Client :: HTTP2ClientConfig -> TransportHost -> ServiceName -> IO () -> Int -> TLS -> IO (Either HTTP2ClientError HTTP2Client)
attachHTTP2Client config host port disconnected bufferSize tls = getVerifiedHTTP2ClientWith config host port disconnected setup
  where
    setup = runHTTP2ClientWith bufferSize host ($ tls)

getVerifiedHTTP2ClientWith :: HTTP2ClientConfig -> TransportHost -> ServiceName -> IO () -> ((SessionId -> H.Client HTTP2Response) -> IO HTTP2Response) -> IO (Either HTTP2ClientError HTTP2Client)
getVerifiedHTTP2ClientWith config host port disconnected setup =
  (atomically mkHTTPS2Client >>= runClient)
    `E.catch` \(e :: IOException) -> pure . Left $ HCIOError e
  where
    mkHTTPS2Client :: STM HClient
    mkHTTPS2Client = do
      connected <- newTVar False
      reqQ <- newTBQueue $ qSize config
      pure HClient {connected, disconnected, host, port, config, reqQ}

    runClient :: HClient -> IO (Either HTTP2ClientError HTTP2Client)
    runClient c = do
      cVar <- newEmptyTMVarIO
      action <- async $ setup (client c cVar) `E.finally` atomically (putTMVar cVar $ Left HCNetworkError)
      c_ <- connTimeout config `timeout` atomically (takeTMVar cVar)
      pure $ case c_ of
        Just (Right c') -> Right c' {action = Just action}
        Just (Left e) -> Left e
        Nothing -> Left HCNetworkError

    client :: HClient -> TMVar (Either HTTP2ClientError HTTP2Client) -> SessionId -> H.Client HTTP2Response
    client c cVar sessionId sendReq = do
      sessionTs <- getCurrentTime
      let c' = HTTP2Client {action = Nothing, client_ = c, sendReq, sessionId, sessionTs}
      atomically $ do
        writeTVar (connected c) True
        putTMVar cVar (Right c')
      process c' sendReq `E.finally` disconnected

    process :: HTTP2Client -> H.Client HTTP2Response
    process HTTP2Client {client_ = HClient {reqQ}} sendReq = forever $ do
      (req, respVar) <- atomically $ readTBQueue reqQ
      sendReq req $ \r -> do
        respBody <- getHTTP2Body r (bodyHeadSize config)
        let resp = HTTP2Response {response = r, respBody}
        atomically $ putTMVar respVar resp
        pure resp

-- | Disconnects client from the server and terminates client threads.
closeHTTP2Client :: HTTP2Client -> IO ()
closeHTTP2Client = mapM_ uninterruptibleCancel . action

sendRequest :: HTTP2Client -> Request -> Maybe Int -> IO (Either HTTP2ClientError HTTP2Response)
sendRequest HTTP2Client {client_ = HClient {config, reqQ}} req reqTimeout_ = do
  resp <- newEmptyTMVarIO
  atomically $ writeTBQueue reqQ (req, resp)
  let reqTimeout = http2RequestTimeout config reqTimeout_
  maybe (Left HCResponseTimeout) Right <$> (reqTimeout `timeout` atomically (takeTMVar resp))

-- | this function should not be used until HTTP2 is thread safe, use sendRequest
sendRequestDirect :: HTTP2Client -> Request -> Maybe Int -> IO (Either HTTP2ClientError HTTP2Response)
sendRequestDirect HTTP2Client {client_ = HClient {config, disconnected}, sendReq} req reqTimeout_ = do
  let reqTimeout = http2RequestTimeout config reqTimeout_
  reqTimeout `timeout` try (sendReq req process) >>= \case
    Just (Right r) -> pure $ Right r
    Just (Left e) -> disconnected $> Left (HCIOError e)
    Nothing -> pure $ Left HCNetworkError
  where
    process r = do
      respBody <- getHTTP2Body r $ bodyHeadSize config
      pure HTTP2Response {response = r, respBody}

http2RequestTimeout :: HTTP2ClientConfig -> Maybe Int -> Int
http2RequestTimeout HTTP2ClientConfig {connTimeout} = maybe connTimeout (connTimeout +)

runHTTP2Client :: forall a. T.Supported -> Maybe XS.CertificateStore -> TransportClientConfig -> BufferSize -> Maybe ByteString -> TransportHost -> ServiceName -> Maybe C.KeyHash -> (SessionId -> H.Client a) -> IO a
runHTTP2Client tlsParams caStore tcConfig bufferSize proxyUsername host port keyHash = runHTTP2ClientWith bufferSize host setup
  where
    setup = runTLSTransportClient tlsParams caStore tcConfig proxyUsername host port keyHash

runHTTP2ClientWith :: forall a. BufferSize -> TransportHost -> ((TLS -> IO a) -> IO a) -> (SessionId -> H.Client a) -> IO a
runHTTP2ClientWith bufferSize host setup client = setup $ withHTTP2 bufferSize run
  where
    run :: H.Config -> SessionId -> IO a
    run cfg sessId = H.run (ClientConfig "https" (strEncode host) 20) cfg $ client sessId
