{-# LANGUAGE NamedFieldPuns #-}

module Simplex.Messaging.Transport.HTTP2 where

import Control.Concurrent.STM
import qualified Control.Exception as E
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Default (def)
import Data.Maybe (fromMaybe)
import Foreign (mallocBytes)
import Network.HPACK (BufferSize)
import Network.HTTP2.Client (Config (..), defaultPositionReadMaker, freeSimpleConfig)
import qualified Network.HTTP2.Client as HC
import qualified Network.HTTP2.Server as HS
import qualified Network.TLS as T
import qualified Network.TLS.Extra as TE
import Simplex.Messaging.Transport (SessionId, TLS (tlsUniq), Transport (cGet, cPut))
import Simplex.Messaging.Transport.Buffer
import qualified System.TimeManager as TI

defaultHTTP2BufferSize :: BufferSize
defaultHTTP2BufferSize = 32768

withHTTP2 :: BufferSize -> (Config -> SessionId -> IO ()) -> TLS -> IO ()
withHTTP2 sz run c = E.bracket (allocHTTP2Config c sz) freeSimpleConfig (`run` tlsUniq c)

allocHTTP2Config :: TLS -> BufferSize -> IO Config
allocHTTP2Config c sz = do
  buf <- mallocBytes sz
  tm <- TI.initialize $ 30 * 1000000
  pure
    Config
      { confWriteBuffer = buf,
        confBufferSize = sz,
        confSendAll = cPut c,
        confReadN = cGet c,
        confPositionReadMaker = defaultPositionReadMaker,
        confTimeoutManager = tm
      }

http2TLSParams :: T.Supported
http2TLSParams =
  def
    { T.supportedVersions = [T.TLS13, T.TLS12],
      T.supportedCiphers = TE.ciphersuite_strong_det,
      T.supportedSecureRenegotiation = False
    }

data HTTP2Body = HTTP2Body
  { bodyHead :: ByteString,
    bodySize :: Int,
    bodyPart :: Maybe (Int -> IO ByteString),
    bodyBuffer :: TBuffer
  }

class HTTP2BodyChunk a where
  getBodyChunk :: a -> IO ByteString
  getBodeSize :: a -> Maybe Int

instance HTTP2BodyChunk HC.Response where
  getBodyChunk = HC.getResponseBodyChunk
  {-# INLINE getBodyChunk #-}
  getBodeSize = HC.responseBodySize
  {-# INLINE getBodeSize #-}

instance HTTP2BodyChunk HS.Request where
  getBodyChunk = HS.getRequestBodyChunk
  {-# INLINE getBodyChunk #-}
  getBodeSize = HS.requestBodySize
  {-# INLINE getBodeSize #-}

getHTTP2Body :: HTTP2BodyChunk a => a -> Int -> IO HTTP2Body
getHTTP2Body r n = do
  bodyBuffer <- atomically newTBuffer
  let getPart n' = getBuffered bodyBuffer n' $ getBodyChunk r
  bodyHead <- getPart n
  let bodySize = fromMaybe 0 $ getBodeSize r
      bodyPart = if bodySize > n && B.length bodyHead == n then Just getPart else Nothing
  pure HTTP2Body {bodyHead, bodySize, bodyPart, bodyBuffer}
