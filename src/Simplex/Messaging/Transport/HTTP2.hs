module Simplex.Messaging.Transport.HTTP2 where

import qualified Control.Exception as E
import Data.Default (def)
import Foreign (mallocBytes)
import Network.HPACK (BufferSize)
import Network.HTTP2.Client (Config (..), defaultPositionReadMaker, freeSimpleConfig)
import qualified Network.TLS as T
import qualified Network.TLS.Extra as TE
import Simplex.Messaging.Transport (TLS, Transport (cGet, cPut))
import qualified System.TimeManager as TI

withTlsConfig :: TLS -> BufferSize -> (Config -> IO ()) -> IO ()
withTlsConfig c sz = E.bracket (allocTlsConfig c sz) freeSimpleConfig

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
