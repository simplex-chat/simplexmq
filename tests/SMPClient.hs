{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module SMPClient where

import Control.Monad (void)
import Control.Monad.IO.Unlift
import Crypto.Random
import qualified Data.ByteString.Char8 as B
import Network.Socket
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Protocol
import Simplex.Messaging.Server
import Simplex.Messaging.Server.Env.STM
import Simplex.Messaging.Transport
import Test.Hspec
import UnliftIO.Concurrent
import qualified UnliftIO.Exception as E
import UnliftIO.STM

testHost :: HostName
testHost = "localhost"

testPort :: ServiceName
testPort = "5000"

testSMPClient :: MonadUnliftIO m => (THandle -> m a) -> m a
testSMPClient client = do
  threadDelay 250_000 -- TODO hack: thread delay for SMP server to start
  runTCPClient testHost testPort $ \h -> do
    sndCounter <- newTVarIO 0
    rcvCounter <- newTVarIO 0
    let th =
          THandle
            { handle = h,
              sendKey =
                TransportKey
                  { aesKey = C.Key "\206@T\153\238\&7[\EOT\224GI\227N\128t\246+L\182{\226\227\EM?\ESC\DLE\196\158\150\188~\\",
                    baseIV = C.IV "\DC4\191(UlYy\212\170si\STX\170(\t{",
                    counter = sndCounter
                  },
              receiveKey =
                TransportKey
                  { aesKey = C.Key "\131\137\ETX\SO\FS\169,\178\251\207\CAN\RS\227\202N*\201\245\216\227cq\DC3U\"\150\128\240r\166\246\&9",
                    baseIV = C.IV "o\254\a\170i>\250\130\237\153\225\227v\243\DC1i",
                    counter = rcvCounter
                  },
              blockSize = 8192
            }
    client th

cfg :: ServerConfig
cfg =
  ServerConfig
    { tcpPort = testPort,
      tbqSize = 1,
      queueIdBytes = 12,
      msgIdBytes = 6
    }

withSmpServerThreadOn :: (MonadUnliftIO m, MonadRandom m) => ServiceName -> (ThreadId -> m a) -> m a
withSmpServerThreadOn port =
  E.bracket
    (forkIOWithUnmask ($ runSMPServer cfg {tcpPort = port}))
    (liftIO . killThread)

withSmpServerOn :: (MonadUnliftIO m, MonadRandom m) => ServiceName -> m a -> m a
withSmpServerOn port = withSmpServerThreadOn port . const

withSmpServer :: (MonadUnliftIO m, MonadRandom m) => m a -> m a
withSmpServer = withSmpServerOn testPort

runSmpTest :: (MonadUnliftIO m, MonadRandom m) => (THandle -> m a) -> m a
runSmpTest test = withSmpServer $ testSMPClient test

runSmpTestN :: forall m a. (MonadUnliftIO m, MonadRandom m) => Int -> ([THandle] -> m a) -> m a
runSmpTestN nClients test = withSmpServer $ run nClients []
  where
    run :: Int -> [THandle] -> m a
    run 0 hs = test hs
    run n hs = testSMPClient $ \h -> run (n - 1) (h : hs)

smpServerTest :: RawTransmission -> IO RawTransmission
smpServerTest cmd = runSmpTest $ \h -> tPutRaw h cmd >> tGetRaw h

smpTest :: (THandle -> IO ()) -> Expectation
smpTest test' = runSmpTest test' `shouldReturn` ()

smpTestN :: Int -> ([THandle] -> IO ()) -> Expectation
smpTestN n test' = runSmpTestN n test' `shouldReturn` ()

smpTest2 :: (THandle -> THandle -> IO ()) -> Expectation
smpTest2 test' = smpTestN 2 _test
  where
    _test [h1, h2] = test' h1 h2
    _test _ = error "expected 2 handles"

smpTest3 :: (THandle -> THandle -> THandle -> IO ()) -> Expectation
smpTest3 test' = smpTestN 3 _test
  where
    _test [h1, h2, h3] = test' h1 h2 h3
    _test _ = error "expected 3 handles"

tPutRaw :: THandle -> RawTransmission -> IO ()
tPutRaw h (sig, corrId, queueId, command) = do
  let t = B.intercalate " " [corrId, queueId, command]
  void $ tPut h (C.Signature sig, t)

tGetRaw :: THandle -> IO RawTransmission
tGetRaw h = do
  Right t <- tGetEncrypted h
  return t
