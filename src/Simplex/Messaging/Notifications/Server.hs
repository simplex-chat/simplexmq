{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Simplex.Messaging.Notifications.Server where

import Control.Monad.Except
import Control.Monad.IO.Unlift (MonadUnliftIO)
import Control.Monad.Reader
import Crypto.Random (MonadRandom)
import Data.ByteString.Char8 (ByteString)
import Network.Socket (ServiceName)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Notifications.Protocol
import Simplex.Messaging.Notifications.Server.Env
import Simplex.Messaging.Notifications.Server.Subscriptions
import Simplex.Messaging.Notifications.Transport
import Simplex.Messaging.Protocol (ErrorType (..), Transmission, encodeTransmission, tGet, tPut)
import Simplex.Messaging.Server
import Simplex.Messaging.Transport (ATransport (..), THandle (..), TProxy, Transport)
import Simplex.Messaging.Transport.Server (runTransportServer)
import Simplex.Messaging.Util
import UnliftIO.Exception
import UnliftIO.STM

runNtfServer :: (MonadRandom m, MonadUnliftIO m) => NtfServerConfig -> m ()
runNtfServer cfg = do
  started <- newEmptyTMVarIO
  runNtfServerBlocking started cfg

runNtfServerBlocking :: (MonadRandom m, MonadUnliftIO m) => TMVar Bool -> NtfServerConfig -> m ()
runNtfServerBlocking started cfg@NtfServerConfig {transports} = do
  env <- newNtfServerEnv cfg
  runReaderT ntfServer env
  where
    ntfServer :: (MonadUnliftIO m', MonadReader NtfEnv m') => m' ()
    ntfServer = raceAny_ (map runServer transports)

    runServer :: (MonadUnliftIO m', MonadReader NtfEnv m') => (ServiceName, ATransport) -> m' ()
    runServer (tcpPort, ATransport t) = do
      serverParams <- asks tlsServerParams
      runTransportServer started tcpPort serverParams (runClient t)

    runClient :: (Transport c, MonadUnliftIO m, MonadReader NtfEnv m) => TProxy c -> c -> m ()
    runClient _ h = do
      kh <- asks serverIdentity
      liftIO (runExceptT $ ntfServerHandshake h kh) >>= \case
        Right th -> runNtfClientTransport th
        Left _ -> pure ()

runNtfClientTransport :: (Transport c, MonadUnliftIO m, MonadReader NtfEnv m) => THandle c -> m ()
runNtfClientTransport th@THandle {sessionId} = do
  q <- asks $ tbqSize . config
  c <- atomically $ newNtfServerClient q sessionId
  raceAny_ [send th c, client c, receive th c]
    `finally` clientDisconnected c

clientDisconnected :: MonadUnliftIO m => NtfServerClient -> m ()
clientDisconnected NtfServerClient {connected} = atomically $ writeTVar connected False

receive :: (Transport c, MonadUnliftIO m, MonadReader NtfEnv m) => THandle c -> NtfServerClient -> m ()
receive th NtfServerClient {rcvQ, sndQ} = forever $ do
  (sig, signed, (corrId, queueId, cmdOrError)) <- tGet th
  case cmdOrError of
    Left e -> write sndQ (corrId, queueId, NRErr e)
    Right cmd -> do
      verified <- verifyTransmission sig signed queueId cmd
      if verified
        then write rcvQ (corrId, queueId, cmd)
        else write sndQ (corrId, queueId, NRErr AUTH)
  where
    write q t = atomically $ writeTBQueue q t

send :: (Transport c, MonadUnliftIO m) => THandle c -> NtfServerClient -> m ()
send h NtfServerClient {sndQ, sessionId} = forever $ do
  t <- atomically $ readTBQueue sndQ
  liftIO $ tPut h (Nothing, encodeTransmission sessionId t)

verifyTransmission ::
  forall m. (MonadUnliftIO m, MonadReader NtfEnv m) => Maybe C.ASignature -> ByteString -> NtfSubsciptionId -> NtfCommand -> m Bool
verifyTransmission sig_ signed subId cmd = do
  case cmd of
    NCCreate _ _ k _ -> pure $ verifyCmdSignature sig_ signed k
    _ -> do
      st <- asks store
      verifySubCmd <$> atomically (getNtfSubscription st subId)
  where
    verifySubCmd = \case
      Right sub -> verifyCmdSignature sig_ signed $ subVerifyKey sub
      Left _ -> maybe False (dummyVerifyCmd signed) sig_ `seq` False

client :: forall m. (MonadUnliftIO m, MonadReader NtfEnv m) => NtfServerClient -> m ()
client NtfServerClient {rcvQ, sndQ} =
  forever $
    atomically (readTBQueue rcvQ)
      >>= processCommand
      >>= atomically . writeTBQueue sndQ
  where
    processCommand :: Transmission NtfCommand -> m (Transmission NtfResponse)
    processCommand (corrId, subId, cmd) = case cmd of
      NCCreate _token _smpQueue _verifyKey _dhKey -> do
        pure (corrId, subId, NROk)
      NCCheck -> do
        pure (corrId, subId, NROk)
      NCToken _token -> do
        pure (corrId, subId, NROk)
      NCDelete -> do
        pure (corrId, subId, NROk)
