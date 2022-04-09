{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Simplex.Messaging.Transport.Client.HTTP2 where

import Control.Concurrent.Async
import Control.Exception (IOException, catch, finally)
import qualified Control.Exception as E
import Control.Monad.Except
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Default (def)
import Data.Maybe (isNothing)
import qualified Data.X509.CertificateStore as XS
import Foreign (mallocBytes)
import Network.HPACK (BufferSize, HeaderTable)
import Network.HTTP2.Client (ClientConfig (..), Config (..), Request, Response)
import qualified Network.HTTP2.Client as H
import Network.Socket (HostName, ServiceName)
import qualified Network.TLS as T
import qualified Network.TLS.Extra as TE
import Numeric.Natural (Natural)
import Simplex.Messaging.Transport (TLS, Transport (cGet, cPut))
import Simplex.Messaging.Transport.Client (runTLSTransportClient)
import Simplex.Messaging.Transport.KeepAlive (KeepAliveOpts)
import qualified System.TimeManager as TI
import UnliftIO.STM
import UnliftIO.Timeout

data HTTPS2Client = HTTPS2Client
  { action :: Async (),
    connected :: TVar Bool,
    host :: HostName,
    port :: ServiceName,
    config :: HTTP2SClientConfig,
    reqQ :: TBQueue (Request, TMVar HTTP2Response)
  }

data HTTP2Response = HTTP2Response
  { response :: Response,
    respBody :: Maybe ByteString,
    respTrailers :: Maybe HeaderTable
  }

data HTTP2SClientConfig = HTTP2SClientConfig
  { qSize :: Natural,
    maxBody :: Int,
    connTimeout :: Int,
    tcpKeepAlive :: Maybe KeepAliveOpts,
    caStoreFile :: FilePath,
    suportedTLSParams :: T.Supported
  }
  deriving (Show)

defaultHTTP2SClientConfig :: HTTP2SClientConfig
defaultHTTP2SClientConfig =
  HTTP2SClientConfig
    { qSize = 64,
      maxBody = 500000,
      connTimeout = 5000000,
      tcpKeepAlive = Nothing,
      caStoreFile = "/etc/ssl/cert.pem",
      suportedTLSParams =
        def
          { T.supportedVersions = [T.TLS13, T.TLS12],
            T.supportedCiphers = TE.ciphersuite_strong_det,
            T.supportedSecureRenegotiation = False
          }
    }

data HTTPS2ClientError = HCResponseTimeout | HCNetworkError | HCIOError IOException
  deriving (Show)

getHTTPS2Client :: HostName -> ServiceName -> HTTP2SClientConfig -> IO () -> IO (Either HTTPS2ClientError HTTPS2Client)
getHTTPS2Client host port config@HTTP2SClientConfig {tcpKeepAlive, connTimeout, caStoreFile, suportedTLSParams} disconnected =
  (atomically mkHTTPS2Client >>= runClient)
    `catch` \(e :: IOException) -> pure . Left $ HCIOError e
  where
    mkHTTPS2Client :: STM HTTPS2Client
    mkHTTPS2Client = do
      connected <- newTVar False
      reqQ <- newTBQueue $ qSize config
      pure HTTPS2Client {action = undefined, connected, host, port, config, reqQ}

    runClient :: HTTPS2Client -> IO (Either HTTPS2ClientError HTTPS2Client)
    runClient c = do
      cVar <- newEmptyTMVarIO
      caStore <- XS.readCertificateStore caStoreFile
      when (isNothing caStore) . putStrLn $ "Error loading CertificateStore from " <> caStoreFile
      action <-
        async $
          runHTTPS2Client suportedTLSParams caStore host port tcpKeepAlive (client c cVar)
            `finally` atomically (putTMVar cVar $ Left HCNetworkError)
      conn_ <- connTimeout `timeout` atomically (takeTMVar cVar)
      pure $ case conn_ of
        Just (Right ()) -> Right c {action}
        Just (Left e) -> Left e
        Nothing -> Left HCNetworkError

    client :: HTTPS2Client -> TMVar (Either HTTPS2ClientError ()) -> (Request -> (Response -> IO ()) -> IO ()) -> IO ()
    client c cVar sendReq = do
      atomically $ do
        writeTVar (connected c) True
        putTMVar cVar $ Right ()
      process c sendReq `finally` disconnected

    process :: HTTPS2Client -> (Request -> (Response -> IO ()) -> IO ()) -> IO ()
    process HTTPS2Client {reqQ} sendReq = forever $ do
      (req, respVar) <- atomically $ readTBQueue reqQ
      sendReq req $ \r -> do
        let writeResp respBody respTrailers = atomically $ putTMVar respVar HTTP2Response {response = r, respBody, respTrailers}
        case H.responseBodySize r of
          Just sz ->
            if sz <= maxBody config
              then do
                respBody <- getResponseBody r "" sz
                respTrailers <- join <$> mapM (const $ H.getResponseTrailers r) respBody
                writeResp respBody respTrailers
              else writeResp Nothing Nothing
          _ -> writeResp Nothing Nothing

    getResponseBody :: Response -> ByteString -> Int -> IO (Maybe ByteString)
    getResponseBody r s sz =
      H.getResponseBodyChunk r >>= \chunk -> do
        if chunk == ""
          then pure (if B.length s == sz then Just s else Nothing)
          else do
            let s' = s <> chunk
            if B.length s' > sz then pure Nothing else getResponseBody r s' sz

-- | Disconnects client from the server and terminates client threads.
closeHTTPS2Client :: HTTPS2Client -> IO ()
closeHTTPS2Client = uninterruptibleCancel . action

sendRequest :: HTTPS2Client -> Request -> IO (Either HTTPS2ClientError HTTP2Response)
sendRequest HTTPS2Client {reqQ, config} req = do
  resp <- newEmptyTMVarIO
  atomically $ writeTBQueue reqQ (req, resp)
  maybe (Left HCResponseTimeout) Right <$> (connTimeout config `timeout` atomically (takeTMVar resp))

runHTTPS2Client :: T.Supported -> Maybe XS.CertificateStore -> HostName -> ServiceName -> Maybe KeepAliveOpts -> ((Request -> (Response -> IO ()) -> IO ()) -> IO ()) -> IO ()
runHTTPS2Client tlsParams caStore host port keepAliveOpts client =
  runTLSTransportClient tlsParams caStore host port Nothing keepAliveOpts https2Client
  where
    cfg = ClientConfig "https" (B.pack host) 20
    https2Client :: TLS -> IO ()
    https2Client c =
      E.bracket
        (allocTlsConfig c 16384)
        H.freeSimpleConfig
        (\conf -> H.run cfg conf client)

    allocTlsConfig :: TLS -> BufferSize -> IO Config
    allocTlsConfig c sz = do
      buf <- mallocBytes sz
      tm <- TI.initialize $ 30 * 1000000
      pure
        Config
          { confWriteBuffer = buf,
            confBufferSize = sz,
            confSendAll = cPut c,
            confReadN = cGet c,
            confPositionReadMaker = H.defaultPositionReadMaker,
            confTimeoutManager = tm
          }
