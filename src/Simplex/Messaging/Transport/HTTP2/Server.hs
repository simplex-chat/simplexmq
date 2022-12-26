{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module Simplex.Messaging.Transport.HTTP2.Server where

import Control.Concurrent.Async (Async, async, uninterruptibleCancel)
import Control.Concurrent.STM
import Control.Monad
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as B
import Network.HPACK (HeaderTable)
import Network.HTTP2.Server (Aux, PushPromise, Request, Response)
import qualified Network.HTTP2.Server as H
import Network.Socket
import qualified Network.TLS as T
import Numeric.Natural (Natural)
import Simplex.Messaging.Transport.HTTP2 (withTlsConfig)
import Simplex.Messaging.Transport.Server (loadSupportedTLSServerParams, runTransportServer)

type HTTP2ServerFunc = (Request -> (Response -> IO ()) -> IO ())

data HTTP2ServerConfig = HTTP2ServerConfig
  { qSize :: Natural,
    http2Port :: ServiceName,
    serverSupported :: T.Supported,
    caCertificateFile :: FilePath,
    privateKeyFile :: FilePath,
    certificateFile :: FilePath,
    logTLSErrors :: Bool
  }
  deriving (Show)

data HTTP2Request = HTTP2Request
  { request :: Request,
    reqBody :: ByteString,
    reqTrailers :: Maybe HeaderTable,
    sendResponse :: Response -> IO ()
  }

data HTTP2Server = HTTP2Server
  { action :: Async (),
    reqQ :: TBQueue HTTP2Request
  }

getHTTP2Server :: HTTP2ServerConfig -> IO HTTP2Server
getHTTP2Server HTTP2ServerConfig {qSize, http2Port, serverSupported, caCertificateFile, certificateFile, privateKeyFile, logTLSErrors} = do
  tlsServerParams <- loadSupportedTLSServerParams serverSupported caCertificateFile certificateFile privateKeyFile
  started <- newEmptyTMVarIO
  reqQ <- newTBQueueIO qSize
  action <- async $
    runHTTP2Server started http2Port tlsServerParams logTLSErrors $ \r sendResponse -> do
      reqBody <- getRequestBody r ""
      reqTrailers <- H.getRequestTrailers r
      atomically $ writeTBQueue reqQ HTTP2Request {request = r, reqBody, reqTrailers, sendResponse}
  void . atomically $ takeTMVar started
  pure HTTP2Server {action, reqQ}
  where
    getRequestBody :: Request -> ByteString -> IO ByteString
    getRequestBody r s =
      H.getRequestBodyChunk r >>= \chunk ->
        if B.null chunk then pure s else getRequestBody r $ s <> chunk

closeHTTP2Server :: HTTP2Server -> IO ()
closeHTTP2Server = uninterruptibleCancel . action

runHTTP2Server :: TMVar Bool -> ServiceName -> T.ServerParams -> Bool -> HTTP2ServerFunc -> IO ()
runHTTP2Server started port serverParams logTLSErrors http2Server =
  runTransportServer started port serverParams logTLSErrors $ \c -> withTlsConfig c 16384 (`H.run` server)
  where
    server :: Request -> Aux -> (Response -> [PushPromise] -> IO ()) -> IO ()
    server req _aux sendResp = http2Server req (`sendResp` [])
