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
import Control.Monad.Reader
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Text.Encoding (decodeUtf8)
import Network.Socket (ServiceName)
import Simplex.Messaging.Agent
import Simplex.Messaging.Agent.Client (newAgentClient)
import Simplex.Messaging.Agent.Env.SQLite
import Simplex.Messaging.Agent.Protocol
import Simplex.Messaging.Agent.Store.SQLite (SQLiteStore)
import Simplex.Messaging.Transport (ATransport (..), TProxy, Transport (..), simplexMQVersion)
import Simplex.Messaging.Transport.Server (defaultTransportServerConfig, loadTLSServerParams, runTransportServer)
import Simplex.Messaging.Util (bshow, atomically')
import UnliftIO.Async (race_)
import qualified UnliftIO.Exception as E
import UnliftIO.STM

-- | Runs an SMP agent as a TCP service using passed configuration.
--
-- See a full agent executable here: https://github.com/simplex-chat/simplexmq/blob/master/apps/smp-agent/Main.hs
runSMPAgent :: ATransport -> AgentConfig -> InitialAgentServers -> SQLiteStore -> IO ()
runSMPAgent t cfg initServers store =
  runSMPAgentBlocking t cfg initServers store 0 =<< newEmptyTMVarIO

-- | Runs an SMP agent as a TCP service using passed configuration with signalling.
--
-- This function uses passed TMVar to signal when the server is ready to accept TCP requests (True)
-- and when it is disconnected from the TCP socket once the server thread is killed (False).
runSMPAgentBlocking :: ATransport -> AgentConfig -> InitialAgentServers -> SQLiteStore -> Int -> TMVar Bool -> IO ()
runSMPAgentBlocking (ATransport t) cfg@AgentConfig {tcpPort, caCertificateFile, certificateFile, privateKeyFile} initServers store initClientId started =
  case tcpPort of
    Just port -> newSMPAgentEnv cfg store >>= smpAgent t port
    Nothing -> E.throwIO $ userError "no agent port"
  where
    smpAgent :: forall c. Transport c => TProxy c -> ServiceName -> Env -> IO ()
    smpAgent _ port env = do
      -- tlsServerParams is not in Env to avoid breaking functional API w/t key and certificate generation
      tlsServerParams <- loadTLSServerParams caCertificateFile certificateFile privateKeyFile
      clientId <- newTVarIO initClientId
      runTransportServer started port tlsServerParams defaultTransportServerConfig $ \(h :: c) -> do
        putLn h $ "Welcome to SMP agent v" <> B.pack simplexMQVersion
        cId <- atomically $ stateTVar clientId $ \i -> (i + 1, i + 1)
        c <- atomically $ newAgentClient cId initServers env
        logConnection c True
        race_ (connectClient h c) (runAgentClient c `runReaderT` env)
          `E.finally` (disconnectAgentClient c)

connectClient :: Transport c => c -> AgentClient -> IO ()
connectClient h c = race_ (send h c) (receive h c)

receive :: forall c. Transport c => c -> AgentClient -> IO ()
receive h c@AgentClient {rcvQ, subQ} = forever $ do
  (corrId, entId, cmdOrErr) <- tGet SClient h
  case cmdOrErr of
    Right cmd -> write rcvQ (corrId, entId, cmd)
    Left e -> write subQ (corrId, entId, APC SAEConn $ ERR e)
  where
    write :: TBQueue (ATransmission p) -> ATransmission p -> IO ()
    write q t = do
      logClient c "-->" t
      atomically $ writeTBQueue q t

send :: Transport c => c -> AgentClient -> IO ()
send h c@AgentClient {subQ} = forever $ do
  t <- atomically' $ readTBQueue subQ
  tPut h t
  logClient c "<--" t

logClient :: AgentClient -> ByteString -> ATransmission a -> IO ()
logClient AgentClient {clientId} dir (corrId, connId, APC _ cmd) = do
  logInfo . decodeUtf8 $ B.unwords [bshow clientId, dir, "A :", corrId, connId, B.takeWhile (/= ' ') $ serializeCommand cmd]
