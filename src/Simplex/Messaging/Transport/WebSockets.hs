{-# LANGUAGE InstanceSigs #-}

module Simplex.Messaging.Transport.WebSockets (WS (..)) where

import qualified Control.Exception as E
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Network.Socket (Socket)
import Network.WebSockets
import Network.WebSockets.Stream (Stream)
import qualified Network.WebSockets.Stream as S
import Simplex.Messaging.Transport (TProxy, Transport (..), TransportError (..), trimCR)

data WS = WS {wsStream :: Stream, wsConnection :: Connection}

websocketsOpts :: ConnectionOptions
websocketsOpts =
  defaultConnectionOptions
    { connectionCompressionOptions = NoCompression,
      connectionFramePayloadSizeLimit = SizeLimit 8192,
      connectionMessageDataSizeLimit = SizeLimit 65536
    }

instance Transport WS where
  transportName :: TProxy WS -> String
  transportName _ = "WebSockets"

  getServerConnection :: Socket -> IO WS
  getServerConnection sock = do
    s <- S.makeSocketStream sock
    WS s <$> acceptClientRequest s
    where
      acceptClientRequest :: Stream -> IO Connection
      acceptClientRequest s = makePendingConnectionFromStream s websocketsOpts >>= acceptRequest

  getClientConnection :: Socket -> IO WS
  getClientConnection sock = do
    s <- S.makeSocketStream sock
    WS s <$> sendClientRequest s
    where
      sendClientRequest :: Stream -> IO Connection
      sendClientRequest s = newClientConnection s "" "/" websocketsOpts []

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
