{-# LANGUAGE GADTs #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module Simplex.Messaging.Transport.WebSockets (WS (..)) where

import qualified Control.Exception as E
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy as LB
import qualified Data.X509 as X
import qualified Network.TLS as T
import Network.WebSockets
import Network.WebSockets.Stream (Stream)
import qualified Network.WebSockets.Stream as S
import Simplex.Messaging.Transport
  ( ALPN,
    Transport (..),
    TransportConfig (..),
    TransportError (..),
    TransportPeer (..),
    STransportPeer (..),
    TransportPeerI (..),
    closeTLS,
    smpBlockSize,
    withTlsUnique,
  )
import Simplex.Messaging.Transport.Buffer (trimCR)
import System.IO.Error (isEOFError)

data WS (p :: TransportPeer) = WS
  { tlsUniq :: ByteString,
    wsALPN :: Maybe ALPN,
    wsStream :: Stream,
    wsConnection :: Connection,
    wsTransportConfig :: TransportConfig,
    wsPeerCert :: X.CertificateChain
  }

websocketsOpts :: ConnectionOptions
websocketsOpts =
  defaultConnectionOptions
    { connectionCompressionOptions = NoCompression,
      connectionFramePayloadSizeLimit = SizeLimit $ fromIntegral smpBlockSize,
      connectionMessageDataSizeLimit = SizeLimit 65536
    }

instance Transport WS where
  transportName _ = "WebSockets"
  {-# INLINE transportName #-}
  transportConfig = wsTransportConfig
  {-# INLINE transportConfig #-}
  getTransportConnection = getWS
  {-# INLINE getTransportConnection #-}
  getPeerCertChain = wsPeerCert
  {-# INLINE getPeerCertChain #-}
  getSessionALPN = wsALPN
  {-# INLINE getSessionALPN #-}
  tlsUnique = tlsUniq
  {-# INLINE tlsUnique #-}
  closeConnection = S.close . wsStream
  {-# INLINE closeConnection #-}

  cGet :: WS p -> Int -> IO ByteString
  cGet c n = do
    s <- receiveData (wsConnection c)
    if B.length s == n
      then pure s
      else E.throwIO TEBadBlock

  cPut :: WS p -> ByteString -> IO ()
  cPut = sendBinaryData . wsConnection

  getLn :: WS p -> IO ByteString
  getLn c = do
    s <- trimCR <$> receiveData (wsConnection c)
    if B.null s || B.last s /= '\n'
      then E.throwIO TEBadBlock
      else pure $ B.init s

getWS :: forall p. TransportPeerI p => TransportConfig -> X.CertificateChain -> T.Context -> IO (WS p)
getWS cfg wsPeerCert cxt = withTlsUnique @WS @p cxt connectWS
  where
    connectWS tlsUniq = do
      s <- makeTLSContextStream cxt
      wsConnection <- connectPeer s
      wsALPN <- T.getNegotiatedProtocol cxt
      pure $ WS {tlsUniq, wsALPN, wsStream = s, wsConnection, wsTransportConfig = cfg, wsPeerCert}
    connectPeer :: Stream -> IO Connection
    connectPeer = case sTransportPeer @p of
      STServer -> acceptClientRequest
      STClient -> sendClientRequest
    acceptClientRequest s = makePendingConnectionFromStream s websocketsOpts >>= acceptRequest
    sendClientRequest s = newClientConnection s "" "/" websocketsOpts []

makeTLSContextStream :: T.Context -> IO Stream
makeTLSContextStream cxt =
  S.makeStream readStream writeStream
  where
    readStream :: IO (Maybe ByteString)
    readStream = (Just <$> T.recvData cxt) `E.catches` [E.Handler handleTlsEOF, E.Handler handleEOF]
      where
        handleTlsEOF = \case
          T.PostHandshake T.Error_EOF -> pure Nothing
          e -> E.throwIO e
        handleEOF e = if isEOFError e then pure Nothing else E.throwIO e
    writeStream :: Maybe LB.ByteString -> IO ()
    writeStream = maybe (closeTLS cxt) (T.sendData cxt)
