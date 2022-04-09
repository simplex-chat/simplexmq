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
import Foreign (mallocBytes)
import Network.HPACK (BufferSize, HeaderTable)
import Network.HTTP2.Client (ClientConfig (..), Config (..), Request, Response)
import qualified Network.HTTP2.Client as H
import Network.Socket (HostName, ServiceName)
import Numeric.Natural (Natural)
import Simplex.Messaging.Transport (TLS, Transport (cGet, cPut))
import Simplex.Messaging.Transport.Client (runTransportClient)
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
    tcpKeepAlive :: Maybe KeepAliveOpts
  }

data HTTPS2ClientError = HCResponseTimeout | HCNetworkError | HCIOError IOException

getHTTPS2Client :: HostName -> ServiceName -> HTTP2SClientConfig -> IO () -> IO (Either HTTPS2ClientError HTTPS2Client)
getHTTPS2Client host port config@HTTP2SClientConfig {tcpKeepAlive, connTimeout} disconnected =
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
      action <-
        async $
          runHTTPS2Client host port tcpKeepAlive (client c cVar)
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

runHTTPS2Client :: HostName -> ServiceName -> Maybe KeepAliveOpts -> ((Request -> (Response -> IO ()) -> IO ()) -> IO ()) -> IO ()
runHTTPS2Client host port keepAliveOpts client = runTransportClient host port Nothing keepAliveOpts https2Client
  where
    cfg = ClientConfig "https" (B.pack host) 20
    https2Client :: TLS -> IO ()
    https2Client c =
      E.bracket
        (allocTlsConfig c 16384)
        H.freeSimpleConfig
        (\conf -> H.run cfg conf client)
    -- client_ :: UnliftIO m -> ((Request -> (Response -> IO ()) -> IO ()) -> IO ())
    -- client_ u sendReq_ = do
    --   unliftIO u $ client sendReq
    --   where
    --     sendReq :: Request -> (Response -> m ()) -> m ()
    --     sendReq req handle = liftIO . sendReq_ req $ unliftIO u . handle

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

-- main :: IO ()
-- main = runTCPClient serverName "80" runHTTP2Client
--   where
--     cliconf = ClientConfig "http" (B.pack serverName) 20
--     runHTTP2Client :: Socket -> IO ()
--     runHTTP2Client s =
--       E.bracket
--         (allocSimpleConfig s 4096)
--         freeSimpleConfig
--         (\conf -> run cliconf conf client)
--     client :: ((Request -> (Response -> IO ()) -> IO ()) -> IO ())
--     client sendRequest = do
--       let req = requestNoBody methodGet "/" []
--       _ <- forkIO $
--         sendRequest req $ \rsp -> do
--           print rsp
--           getResponseBodyChunk rsp >>= B.putStrLn
--       sendRequest req $ \rsp -> do
--         threadDelay 100000
--         print rsp
--         getResponseBodyChunk rsp >>= B.putStrLn
