{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Simplex.Messaging.Agent.Server
  ( -- * SMP agent over TCP
    runSMPAgent,
    runSMPAgentBlocking,
  )
where

import Control.Logger.Simple (logInfo)
import Control.Monad
import Control.Monad.IO.Unlift (MonadUnliftIO)
import Control.Monad.Reader
import Crypto.Random (MonadRandom)
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Text.Encoding (decodeUtf8)
import Simplex.Messaging.Agent
import Simplex.Messaging.Agent.Env.SQLite
import Simplex.Messaging.Agent.Protocol
import Simplex.Messaging.Agent.Store.SQLite (SQLiteStore)
import Simplex.Messaging.Transport (ATransport (..), TProxy, Transport (..), simplexMQVersion)
import Simplex.Messaging.Transport.Server (defaultTransportServerConfig, loadTLSServerParams, runTransportServer)
import Simplex.Messaging.Util (bshow)
import UnliftIO.Async (race_)
import qualified UnliftIO.Exception as E
import UnliftIO.STM

-- | Runs an SMP agent as a TCP service using passed configuration.
--
-- See a full agent executable here: https://github.com/simplex-chat/simplexmq/blob/master/apps/smp-agent/Main.hs
runSMPAgent :: (MonadRandom m, MonadUnliftIO m) => ATransport -> AgentConfig -> InitialAgentServers -> SQLiteStore -> m ()
runSMPAgent t cfg initServers store =
  runSMPAgentBlocking t cfg initServers store =<< newEmptyTMVarIO

-- | Runs an SMP agent as a TCP service using passed configuration with signalling.
--
-- This function uses passed TMVar to signal when the server is ready to accept TCP requests (True)
-- and when it is disconnected from the TCP socket once the server thread is killed (False).
runSMPAgentBlocking :: (MonadRandom m, MonadUnliftIO m) => ATransport -> AgentConfig -> InitialAgentServers -> SQLiteStore -> TMVar Bool -> m ()
runSMPAgentBlocking (ATransport t) cfg@AgentConfig {tcpPort, caCertificateFile, certificateFile, privateKeyFile} initServers store started = do
  liftIO (newSMPAgentEnv cfg store) >>= runReaderT (smpAgent t)
  where
    smpAgent :: forall c m'. (Transport c, MonadUnliftIO m', MonadReader Env m') => TProxy c -> m' ()
    smpAgent _ = do
      -- tlsServerParams is not in Env to avoid breaking functional API w/t key and certificate generation
      tlsServerParams <- liftIO $ loadTLSServerParams caCertificateFile certificateFile privateKeyFile
      runTransportServer started tcpPort tlsServerParams defaultTransportServerConfig $ \(h :: c) -> do
        liftIO . putLn h $ "Welcome to SMP agent v" <> B.pack simplexMQVersion
        c <- getAgentClient initServers
        logConnection c True
        race_ (connectClient h c) (runAgentClient c)
          `E.finally` disconnectAgentClient c

connectClient :: Transport c => MonadUnliftIO m => c -> AgentClient -> m ()
connectClient h c = race_ (send h c) (receive h c)

receive :: forall c m. (Transport c, MonadUnliftIO m) => c -> AgentClient -> m ()
receive h c@AgentClient {rcvQ, subQ} = forever $ do
  (corrId, entId, cmdOrErr) <- tGet SClient h
  case cmdOrErr of
    Right cmd -> write rcvQ (corrId, entId, cmd)
    Left e -> write subQ (corrId, entId, APC SAEConn $ ERR e)
  where
    write :: TBQueue (ATransmission p) -> ATransmission p -> m ()
    write q t = do
      logClient c "-->" t
      atomically $ writeTBQueue q t

send :: (Transport c, MonadUnliftIO m) => c -> AgentClient -> m ()
send h c@AgentClient {subQ} = forever $ do
  t <- atomically $ readTBQueue subQ
  tPut h t
  logClient c "<--" t

logClient :: MonadUnliftIO m => AgentClient -> ByteString -> ATransmission a -> m ()
logClient AgentClient {clientId} dir (corrId, connId, APC _ cmd) = do
  logInfo . decodeUtf8 $ B.unwords [bshow clientId, dir, "A :", corrId, connId, B.takeWhile (/= ' ') $ serializeCommand cmd]
