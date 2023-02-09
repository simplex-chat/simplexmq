module Simplex.Messaging.Transport.HTTP2 where

import qualified Control.Exception as E
import Data.Default (def)
import Foreign (mallocBytes)
import Network.HPACK (BufferSize)
import Network.HTTP2.Client (Config (..), defaultPositionReadMaker, freeSimpleConfig)
import qualified Network.TLS as T
import qualified Network.TLS.Extra as TE
import Simplex.Messaging.Transport (SessionId, TLS (tlsUniq), Transport (cGet, cPut))
import qualified System.TimeManager as TI

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
