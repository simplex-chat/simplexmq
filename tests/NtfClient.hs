{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module NtfClient where

import Control.Monad.Except (runExceptT)
import Control.Monad.IO.Unlift
import Crypto.Random
import Data.ByteString.Char8 (ByteString)
import Network.Socket
import Simplex.Messaging.Client.Agent (defaultSMPClientAgentConfig)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding
import Simplex.Messaging.Notifications.Server (runNtfServerBlocking)
import Simplex.Messaging.Notifications.Server.Env
import Simplex.Messaging.Notifications.Transport
import Simplex.Messaging.Protocol
import Simplex.Messaging.Transport
import Simplex.Messaging.Transport.Client
import Simplex.Messaging.Transport.KeepAlive
import UnliftIO.Concurrent
import qualified UnliftIO.Exception as E
import UnliftIO.STM (TMVar, atomically, newEmptyTMVarIO, takeTMVar)
import UnliftIO.Timeout (timeout)

testHost :: HostName
testHost = "localhost"

testPort :: ServiceName
testPort = "6001"

testKeyHash :: C.KeyHash
testKeyHash = "LcJUMfVhwD8yxjAiSaDzzGF3-kLG4Uh0Fl_ZIjrRwjI="

testNtfClient :: (Transport c, MonadUnliftIO m) => (THandle c -> m a) -> m a
testNtfClient client =
  runTransportClient testHost testPort testKeyHash (Just defaultKeepAliveOpts) $ \h ->
    liftIO (runExceptT $ ntfClientHandshake h testKeyHash) >>= \case
      Right th -> client th
      Left e -> error $ show e

cfg :: NtfServerConfig
cfg =
  NtfServerConfig
    { transports = undefined,
      subIdBytes = 24,
      regCodeBytes = 32,
      clientQSize = 1,
      subQSize = 1,
      pushQSize = 1,
      smpAgentCfg = defaultSMPClientAgentConfig,
      -- CA certificate private key is not needed for initialization
      caCertificateFile = "tests/fixtures/ca.crt",
      privateKeyFile = "tests/fixtures/server.key",
      certificateFile = "tests/fixtures/server.crt"
    }

withNtfServerThreadOn :: (MonadUnliftIO m, MonadRandom m) => ATransport -> ServiceName -> (ThreadId -> m a) -> m a
withNtfServerThreadOn t port' =
  serverBracket
    (\started -> runNtfServerBlocking started cfg {transports = [(port', t)]})
    (pure ())

serverBracket :: MonadUnliftIO m => (TMVar Bool -> m ()) -> m () -> (ThreadId -> m a) -> m a
serverBracket process afterProcess f = do
  started <- newEmptyTMVarIO
  E.bracket
    (forkIOWithUnmask ($ process started))
    (\t -> killThread t >> afterProcess >> waitFor started "stop")
    (\t -> waitFor started "start" >> f t)
  where
    waitFor started s =
      5_000_000 `timeout` atomically (takeTMVar started) >>= \case
        Nothing -> error $ "server did not " <> s
        _ -> pure ()

withNtfServerOn :: (MonadUnliftIO m, MonadRandom m) => ATransport -> ServiceName -> m a -> m a
withNtfServerOn t port' = withNtfServerThreadOn t port' . const

withNtfServer :: (MonadUnliftIO m, MonadRandom m) => ATransport -> m a -> m a
withNtfServer t = withNtfServerOn t testPort

runNtfTest :: forall c m a. (Transport c, MonadUnliftIO m, MonadRandom m) => (THandle c -> m a) -> m a
runNtfTest test = withNtfServer (transport @c) $ testNtfClient test

ntfServerTest ::
  forall c smp.
  (Transport c, Encoding smp) =>
  TProxy c ->
  (Maybe C.ASignature, ByteString, ByteString, smp) ->
  IO (Maybe C.ASignature, ByteString, ByteString, BrokerMsg)
ntfServerTest _ t = runNtfTest $ \h -> tPut' h t >> tGet' h
  where
    tPut' h (sig, corrId, queueId, smp) = do
      let t' = smpEncode (sessionId (h :: THandle c), corrId, queueId, smp)
      Right () <- tPut h (sig, t')
      pure ()
    tGet' h = do
      (Nothing, _, (CorrId corrId, qId, Right cmd)) <- tGet h
      pure (Nothing, corrId, qId, cmd)