{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}

module Simplex.Messaging.Transport.WebSockets (WS (..)) where

import qualified Control.Exception as E
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy as BL
import qualified Network.TLS as T
import Network.WebSockets
import Network.WebSockets.Stream (Stream)
import qualified Network.WebSockets.Stream as S
import Simplex.Messaging.Transport
  ( TProxy,
    Transport (..),
    TransportConfig (..),
    TransportError (..),
    TransportPeer (..),
    closeTLS,
    smpBlockSize,
    withTlsUnique,
  )
import Simplex.Messaging.Transport.Buffer (trimCR)

data WS = WS
  { wsPeer :: TransportPeer,
    tlsUniq :: ByteString,
    wsStream :: Stream,
    wsConnection :: Connection,
    wsTransportConfig :: TransportConfig
  }

websocketsOpts :: ConnectionOptions
websocketsOpts =
  defaultConnectionOptions
    { connectionCompressionOptions = NoCompression,
      connectionFramePayloadSizeLimit = SizeLimit $ fromIntegral smpBlockSize,
      connectionMessageDataSizeLimit = SizeLimit 65536
    }

instance Transport WS where
  transportName :: TProxy WS -> String
  transportName _ = "WebSockets"

  transportPeer :: WS -> TransportPeer
  transportPeer = wsPeer

  transportConfig :: WS -> TransportConfig
  transportConfig = wsTransportConfig

  getServerConnection :: TransportConfig -> T.Context -> IO WS
  getServerConnection = getWS TServer

  getClientConnection :: TransportConfig -> T.Context -> IO WS
  getClientConnection = getWS TClient

  tlsUnique :: WS -> ByteString
  tlsUnique = tlsUniq

  closeConnection :: WS -> IO ()
  closeConnection = S.close . wsStream

  cGet :: WS -> Int -> IO ByteString
  cGet c n = do
    s <- receiveData (wsConnection c)
    if B.length s == n
      then pure s
      else E.throwIO TEBadBlock

  cPut :: WS -> ByteString -> IO ()
  cPut = sendBinaryData . wsConnection

  getLn :: WS -> IO ByteString
  getLn c = do
    s <- trimCR <$> receiveData (wsConnection c)
    if B.null s || B.last s /= '\n'
      then E.throwIO TEBadBlock
      else pure $ B.init s

getWS :: TransportPeer -> TransportConfig -> T.Context -> IO WS
getWS wsPeer cfg cxt = withTlsUnique wsPeer cxt connectWS
  where
    connectWS tlsUniq = do
      s <- makeTLSContextStream cxt
      wsConnection <- connectPeer wsPeer s
      pure $ WS {wsPeer, tlsUniq, wsStream = s, wsConnection, wsTransportConfig = cfg}
    connectPeer :: TransportPeer -> Stream -> IO Connection
    connectPeer TServer = acceptClientRequest
    connectPeer TClient = sendClientRequest
    acceptClientRequest s = makePendingConnectionFromStream s websocketsOpts >>= acceptRequest
    sendClientRequest s = newClientConnection s "" "/" websocketsOpts []

makeTLSContextStream :: T.Context -> IO Stream
makeTLSContextStream cxt =
  S.makeStream readStream writeStream
  where
    readStream :: IO (Maybe ByteString)
    readStream =
      (Just <$> T.recvData cxt) `E.catch` \case
        T.Error_EOF -> pure Nothing
        e -> E.throwIO e
    writeStream :: Maybe BL.ByteString -> IO ()
    writeStream = maybe (closeTLS cxt) (T.sendData cxt)
