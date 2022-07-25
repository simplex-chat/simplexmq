{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Simplex.Messaging.Transport.HTTP2.Client where

import Control.Concurrent.Async
import Control.Exception (IOException)
import qualified Control.Exception as E
import Control.Monad.Except
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Maybe (isNothing)
import qualified Data.X509.CertificateStore as XS
import Network.HPACK (HeaderTable)
import Network.HTTP2.Client (ClientConfig (..), Request, Response)
import qualified Network.HTTP2.Client as H
import Network.Socket (HostName, ServiceName)
import qualified Network.TLS as T
import Numeric.Natural (Natural)
import Simplex.Messaging.Transport.Client (TransportHost (..), runTLSTransportClient)
import Simplex.Messaging.Transport.HTTP2 (http2TLSParams, withTlsConfig)
import Simplex.Messaging.Transport.KeepAlive (KeepAliveOpts)
import UnliftIO.STM
import UnliftIO.Timeout

data HTTP2Client = HTTP2Client
  { action :: Async (),
    connected :: TVar Bool,
    host :: HostName,
    port :: ServiceName,
    config :: HTTP2ClientConfig,
    reqQ :: TBQueue (Request, TMVar HTTP2Response)
  }

data HTTP2Response = HTTP2Response
  { response :: Response,
    respBody :: ByteString,
    respTrailers :: Maybe HeaderTable
  }

data HTTP2ClientConfig = HTTP2ClientConfig
  { qSize :: Natural,
    connTimeout :: Int,
    tcpKeepAlive :: Maybe KeepAliveOpts,
    caStoreFile :: FilePath,
    suportedTLSParams :: T.Supported
  }
  deriving (Show)

defaultHTTP2ClientConfig :: HTTP2ClientConfig
defaultHTTP2ClientConfig =
  HTTP2ClientConfig
    { qSize = 64,
      connTimeout = 10000000,
      tcpKeepAlive = Nothing,
      caStoreFile = "/etc/ssl/cert.pem",
      suportedTLSParams = http2TLSParams
    }

data HTTP2ClientError = HCResponseTimeout | HCNetworkError | HCNetworkError1 | HCIOError IOException
  deriving (Show)

getHTTP2Client :: HostName -> ServiceName -> HTTP2ClientConfig -> IO () -> IO (Either HTTP2ClientError HTTP2Client)
getHTTP2Client host port config@HTTP2ClientConfig {tcpKeepAlive, connTimeout, caStoreFile, suportedTLSParams} disconnected =
  (atomically mkHTTPS2Client >>= runClient)
    `E.catch` \(e :: IOException) -> pure . Left $ HCIOError e
  where
    mkHTTPS2Client :: STM HTTP2Client
    mkHTTPS2Client = do
      connected <- newTVar False
      reqQ <- newTBQueue $ qSize config
      pure HTTP2Client {action = undefined, connected, host, port, config, reqQ}

    runClient :: HTTP2Client -> IO (Either HTTP2ClientError HTTP2Client)
    runClient c = do
      cVar <- newEmptyTMVarIO
      caStore <- XS.readCertificateStore caStoreFile
      when (isNothing caStore) . putStrLn $ "Error loading CertificateStore from " <> caStoreFile
      action <-
        async $
          runHTTP2Client suportedTLSParams caStore host port tcpKeepAlive (client c cVar)
            `E.finally` atomically (putTMVar cVar $ Left HCNetworkError)
      conn_ <- connTimeout `timeout` atomically (takeTMVar cVar)
      pure $ case conn_ of
        Just (Right ()) -> Right c {action}
        Just (Left e) -> Left e
        Nothing -> Left HCNetworkError1

    client :: HTTP2Client -> TMVar (Either HTTP2ClientError ()) -> (Request -> (Response -> IO ()) -> IO ()) -> IO ()
    client c cVar sendReq = do
      atomically $ do
        writeTVar (connected c) True
        putTMVar cVar $ Right ()
      process c sendReq `E.finally` disconnected

    process :: HTTP2Client -> (Request -> (Response -> IO ()) -> IO ()) -> IO ()
    process HTTP2Client {reqQ} sendReq = forever $ do
      (req, respVar) <- atomically $ readTBQueue reqQ
      sendReq req $ \r -> do
        let writeResp respBody respTrailers = atomically $ putTMVar respVar HTTP2Response {response = r, respBody, respTrailers}
        respBody <- getResponseBody r ""
        respTrailers <- H.getResponseTrailers r
        writeResp respBody respTrailers

    getResponseBody :: Response -> ByteString -> IO ByteString
    getResponseBody r s =
      H.getResponseBodyChunk r >>= \chunk ->
        if B.null chunk then pure s else getResponseBody r $ s <> chunk

-- | Disconnects client from the server and terminates client threads.
closeHTTP2Client :: HTTP2Client -> IO ()
-- TODO disconnect
closeHTTP2Client = uninterruptibleCancel . action

sendRequest :: HTTP2Client -> Request -> IO (Either HTTP2ClientError HTTP2Response)
sendRequest HTTP2Client {reqQ, config} req = do
  resp <- newEmptyTMVarIO
  atomically $ writeTBQueue reqQ (req, resp)
  maybe (Left HCResponseTimeout) Right <$> (connTimeout config `timeout` atomically (takeTMVar resp))

runHTTP2Client :: T.Supported -> Maybe XS.CertificateStore -> HostName -> ServiceName -> Maybe KeepAliveOpts -> ((Request -> (Response -> IO ()) -> IO ()) -> IO ()) -> IO ()
runHTTP2Client tlsParams caStore host port keepAliveOpts client =
  runTLSTransportClient tlsParams caStore Nothing [THDomainName host] port Nothing keepAliveOpts $ \c ->
    withTlsConfig c 16384 (`run` client)
  where
    run = H.run $ ClientConfig "https" (B.pack host) 20
