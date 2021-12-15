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
import Simplex.Messaging.Transport (TLS (..), TProxy, Transport (..), TransportError (..), closeTLS, trimCR)

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

  getServerConnection :: TLS -> IO WS
  getServerConnection TLS {tlsContext} = do
    s <- websocketsStream tlsContext
    WS s <$> acceptClientRequest s
    where
      acceptClientRequest :: Stream -> IO Connection
      acceptClientRequest s = makePendingConnectionFromStream s websocketsOpts >>= acceptRequest

  getClientConnection :: TLS -> IO WS
  getClientConnection TLS {tlsContext} = do
    s <- websocketsStream tlsContext
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

websocketsStream :: T.Context -> IO S.Stream
websocketsStream tlsContext =
  S.makeStream readStream writeStream
  where
    readStream :: IO (Maybe ByteString)
    readStream =
      (Just <$> T.recvData tlsContext) `E.catch` \case
        T.Error_EOF -> pure Nothing
        e -> E.throwIO e
    writeStream :: Maybe BL.ByteString -> IO ()
    writeStream = \case
      Nothing -> closeTLS tlsContext
      Just bs -> T.sendData tlsContext bs
