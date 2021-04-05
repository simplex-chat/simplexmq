{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module SMPClient where

import Control.Monad (void)
import Control.Monad.Except (runExceptT)
import Control.Monad.IO.Unlift
import Crypto.Random
import Data.ByteString.Base64 (encode)
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

testHost :: HostName
testHost = "localhost"

testPort :: ServiceName
testPort = "5000"

teshKeyHashStr :: B.ByteString
teshKeyHashStr = "8Cvd+AYVxLpSsB/glEhVxkKuEzMNBFdAL5yr7p9DGGk="

teshKeyHash :: Maybe C.KeyHash
teshKeyHash = Just "8Cvd+AYVxLpSsB/glEhVxkKuEzMNBFdAL5yr7p9DGGk="

testSMPClient :: MonadUnliftIO m => (THandle -> m a) -> m a
testSMPClient client = do
  threadDelay 250_000 -- TODO hack: thread delay for SMP server to start
  runTCPClient testHost testPort $ \h ->
    liftIO (runExceptT $ clientHandshake h teshKeyHash) >>= \case
      Right th -> client th
      Left e -> error $ show e

cfg :: ServerConfig
cfg =
  ServerConfig
    { tcpPort = testPort,
      tbqSize = 1,
      queueIdBytes = 12,
      msgIdBytes = 6,
      serverKeyPair =
        ( "256,wgJfm+EgMI3MeGdZlNs+KEoMlO0bpvZ2sa7bK4zWGtWGWXoCq1m89gaMk+f+HZavNJbJmflqrviBAoCFtDrA5+xC4+mwGlU6mLWiWtpvxgRBtNBsuHg3l+oJv0giFNCxoscne3P6n4kaCQEbA1T6KdrsdvxcaqyqzbpI7SozLIzhy45gsVywJfzpu6GYHlYNizdBJtoX2r66v6jDQFX7/MVDG4Z84RRa8PzjzT0wXSY+nirwIy5uwD0V5jrwaB0S5re6UnL7aLp51zHLUHPI/C9okBIkjY9kyQg3mAYXOPxb0OlGf3ENWnVdPKG6WqYnC3SBMIEVd4rqqxoH4myTgQ==,DHXxHfufuxfbuReISV9tCNttWXm/EVXTTN//hHkW/1wPLppbpY6aOqW+SZWwGCodIdGvdPSmaY9W8kfftWQY9xCOOcpkrzZwYHppT995xBIoB30vXG01dyruebFr3HjurT+uUbRGnxNYGwZg3AjkcyQtMKmq1pANvOGsOUgeDiU=",
          "256,wgJfm+EgMI3MeGdZlNs+KEoMlO0bpvZ2sa7bK4zWGtWGWXoCq1m89gaMk+f+HZavNJbJmflqrviBAoCFtDrA5+xC4+mwGlU6mLWiWtpvxgRBtNBsuHg3l+oJv0giFNCxoscne3P6n4kaCQEbA1T6KdrsdvxcaqyqzbpI7SozLIzhy45gsVywJfzpu6GYHlYNizdBJtoX2r66v6jDQFX7/MVDG4Z84RRa8PzjzT0wXSY+nirwIy5uwD0V5jrwaB0S5re6UnL7aLp51zHLUHPI/C9okBIkjY9kyQg3mAYXOPxb0OlGf3ENWnVdPKG6WqYnC3SBMIEVd4rqqxoH4myTgQ==,PC6r+lZm5vyVpOl6dS9SXv09iE1PZoav6yeUbqsK+FScwHiOMEOkTY2mUyTHZ99nA4l7grAo4RPS6UOQS07QtgD2siZyj6F6Z3qAiBGesiG3+tb59pQ/prhs+5Q7RBlRMulz5KEwFINUb4Wy9ft4oIL/JJT9iSnYtTuGGirUEjB6YGzLKQeTyhkWA0iN89C5Vx6drB/pHyu3Mu+uc0Rax0UPD47gsNmxPNWUM6xLlkpNAWnSOHcSJZ3SN4QDLLCeBfqkgDLYkE3vbwvz8drt+H2eLi8OzFErEdkkrXg/0VwNjfhpBTt8D4TX00I7XsVksh3b2BRHzLfHTbLGdExLLQ=="
        )
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
  ("", (CorrId corrId, qId, Right cmd)) <- tGet fromServer h
  pure ("", corrId, encode qId, serializeCommand cmd)
