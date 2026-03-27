{-# LANGUAGE CPP #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# OPTIONS_GHC -fno-warn-ambiguous-fields #-}

module Main where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, cancel, forConcurrently_, mapConcurrently, mapConcurrently_)
import Control.Concurrent.STM
import Control.Monad (forever, forM_, void, when)
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.IORef
import Data.List (unfoldr)
import Data.Time.Clock (getCurrentTime, utctDayTime)
import Network.Socket (ServiceName)
import System.Environment (getArgs)
import System.IO (hFlush, stdout)

import ClientSim
import Report

import Crypto.Random (ChaChaDRG)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Server (runSMPServerBlocking)
import Simplex.Messaging.Server.Env.STM as Env
import Simplex.Messaging.Server.Expiration (ExpirationConfig (..))
import Simplex.Messaging.Server.MsgStore.Postgres (PostgresMsgStore)
import Simplex.Messaging.Server.QueueStore.Postgres.Config (PostgresStoreCfg (..))
import Simplex.Messaging.Agent.Store.Postgres.Options (DBOpts (..))
import Simplex.Messaging.Agent.Store.Shared (MigrationConfirmation (..))
import Simplex.Messaging.Client.Agent (SMPClientAgentConfig (..), defaultSMPClientAgentConfig)
import Simplex.Messaging.Transport
import Simplex.Messaging.Transport.Server (ServerCredentials (..), mkTransportServerConfig)
import Simplex.Messaging.Version
import UnliftIO.Exception (bracket)

import Control.Logger.Simple (logInfo, withGlobalLogging, LogConfig (..), setLogLevel, LogLevel (..))

data BenchConfig = BenchConfig
  { numClients :: Int,
    sustainedMinutes :: Int,
    pgConnStr :: ByteString,
    serverPort :: ServiceName,
    timeSeriesFile :: FilePath
  }

defaultBenchConfig :: BenchConfig
defaultBenchConfig =
  BenchConfig
    { numClients = 5000,
      sustainedMinutes = 5,
      pgConnStr = "postgresql://smp@localhost:15432/smp_bench",
      serverPort = "15001",
      timeSeriesFile = "bench-timeseries.csv"
    }

parseArgs :: IO BenchConfig
parseArgs = do
  args <- getArgs
  pure $ go args defaultBenchConfig
  where
    go [] c = c
    go ("--clients" : n : rest) c = go rest c {numClients = read n}
    go ("--minutes" : n : rest) c = go rest c {sustainedMinutes = read n}
    go ("--pg" : s : rest) c = go rest c {pgConnStr = B.pack s}
    go ("--port" : p : rest) c = go rest c {serverPort = p}
    go ("--timeseries" : f : rest) c = go rest c {timeSeriesFile = f}
    go (x : _) _ = error $ "Unknown argument: " <> x

main :: IO ()
main = withGlobalLogging LogConfig {lc_file = Nothing, lc_stderr = True} $ do
  setLogLevel LogInfo
  bc@BenchConfig {numClients, sustainedMinutes, serverPort, timeSeriesFile, pgConnStr} <- parseArgs
  putStrLn $ "SMP Server Memory Benchmark"
  putStrLn $ "  clients:  " <> show numClients
  putStrLn $ "  sustain:  " <> show sustainedMinutes <> " min"
  putStrLn $ "  pg:       " <> B.unpack pgConnStr
  putStrLn $ "  port:     " <> serverPort
  putStrLn ""

  snapshotsRef <- newIORef []

  let snap phase clients = do
        s <- takeSnapshot phase clients
        modifyIORef' snapshotsRef (s :)
        putStrLn $ "  [" <> show phase <> "] live=" <> show (snapLive s `div` (1024 * 1024)) <> "MB large=" <> show (snapLarge s `div` (1024 * 1024)) <> "MB"
        hFlush stdout

  withBenchServer bc $ do
    putStrLn "Phase 1: Baseline (no clients)"
    snap "baseline" 0

    putStrLn $ "Phase 2: Connecting " <> show numClients <> " TLS clients..."
    handles <- connectN numClients "localhost" serverPort
    putStrLn $ "  Connected " <> show (length handles) <> " clients"
    snap "tls_connect" (length handles)

    putStrLn "Phase 3: Creating queues (NEW + KEY)..."
    simClients <- mapConcurrently createQueue handles
    putStrLn $ "  Created " <> show (length simClients) <> " queues"
    snap "queue_create" (length simClients)

    putStrLn "Phase 4: Subscribing (SUB)..."
    mapConcurrently_ subscribeQueue simClients
    snap "subscribe" (length simClients)

    -- Pair up clients: first half sends to second half
    let halfN = length simClients `div` 2
        senders = take halfN simClients
        receivers = drop halfN simClients
        pairs = zip senders receivers

    putStrLn $ "Phase 5: Sending " <> show halfN <> " messages..."
    g <- C.newRandom
    forConcurrently_ pairs $ \(sender, receiver) -> do
      (_, sKey) <- atomically $ C.generateAuthKeyPair C.SEd25519 g
      sendMessage (scHandle sender) sKey (scSndId receiver) "benchmark test message payload 1234567890"
    snap "msg_send" (length simClients)

    putStrLn "Phase 6: Receiving and ACKing messages..."
    forConcurrently_ receivers receiveAndAck
    snap "msg_recv" (length simClients)

    putStrLn $ "Phase 7: Sustained load (" <> show sustainedMinutes <> " min)..."
    writeTimeSeriesHeader timeSeriesFile
    -- Logger thread: snapshot every 10s
    logger <- async $ forever $ do
      threadDelay 10_000_000
      s <- takeSnapshot "sustained" (length simClients)
      appendTimeSeries timeSeriesFile s
    -- Worker threads: continuous send/receive
    let loopDurationUs = sustainedMinutes * 60 * 1_000_000
    workersDone <- newTVarIO False
    workers <- async $ do
      deadline <- (+ loopDurationUs) <$> getMonotonicTimeUs
      sustainedLoop g pairs deadline
      atomically $ writeTVar workersDone True
    -- Wait for workers
    void $ atomically $ readTVar workersDone >>= \done -> when (not done) retry
    cancel logger
    cancel workers
    snap "sustained_end" (length simClients)

  snapshots <- reverse <$> readIORef snapshotsRef
  printSummary snapshots
  putStrLn $ "\nTime-series written to: " <> timeSeriesFile

sustainedLoop :: TVar ChaChaDRG -> [(SimClient, SimClient)] -> Int -> IO ()
sustainedLoop g pairs deadline = go
  where
    go = do
      now <- getMonotonicTimeUs
      when (now < deadline) $ do
        forConcurrently_ pairs $ \(sender, receiver) -> do
          (_, sKey) <- atomically $ C.generateAuthKeyPair C.SEd25519 g
          sendMessage (scHandle sender) sKey (scSndId receiver) "sustained load message payload"
        forConcurrently_ (map snd pairs) receiveAndAck
        go

getMonotonicTimeUs :: IO Int
getMonotonicTimeUs = do
  t <- getCurrentTime
  pure $ round (utctDayTime t * 1_000_000)

withBenchServer :: BenchConfig -> IO a -> IO a
withBenchServer BenchConfig {pgConnStr, serverPort} action = do
  started <- newEmptyTMVarIO
  let srvCfg = benchServerConfig pgConnStr serverPort
  bracket
    (async $ runSMPServerBlocking started srvCfg Nothing)
    cancel
    (\_ -> waitForServer started >> action)
  where
    waitForServer started = do
      r <- atomically $ takeTMVar started
      if r
        then putStrLn $ "Server started on port " <> serverPort
        else error "Server failed to start"

benchServerConfig :: ByteString -> ServiceName -> ServerConfig PostgresMsgStore
benchServerConfig pgConn port =
  let storeCfg = PostgresStoreCfg
        { dbOpts = DBOpts {connstr = pgConn, schema = "smp_server", poolSize = 10, createSchema = True},
          dbStoreLogPath = Nothing,
          confirmMigrations = MCYesUp,
          deletedTTL = 86400
        }
   in ServerConfig
        { transports = [(port, transport @TLS, False)],
          smpHandshakeTimeout = 120_000_000,
          tbqSize = 128,
          msgQueueQuota = 128,
          maxJournalMsgCount = 256,
          maxJournalStateLines = 16,
          queueIdBytes = 24,
          msgIdBytes = 24,
          serverStoreCfg = SSCDatabase storeCfg,
          storeNtfsFile = Nothing,
          allowNewQueues = True,
          newQueueBasicAuth = Nothing,
          controlPortUserAuth = Nothing,
          controlPortAdminAuth = Nothing,
          dailyBlockQueueQuota = 20,
          messageExpiration = Just defaultMessageExpiration,
          expireMessagesOnStart = False,
          expireMessagesOnSend = False,
          idleQueueInterval = 14400,
          notificationExpiration = defaultNtfExpiration,
          inactiveClientExpiration = Nothing,
          logStatsInterval = Nothing,
          logStatsStartTime = 0,
          serverStatsLogFile = "bench/tmp/stats.log",
          serverStatsBackupFile = Nothing,
          prometheusInterval = Nothing,
          prometheusMetricsFile = "bench/tmp/metrics.txt",
          pendingENDInterval = 500_000,
          ntfDeliveryInterval = 200_000,
          smpCredentials =
            ServerCredentials
              { caCertificateFile = Just "tests/fixtures/ca.crt",
                privateKeyFile = "tests/fixtures/server.key",
                certificateFile = "tests/fixtures/server.crt"
              },
          httpCredentials = Nothing,
          smpServerVRange = supportedServerSMPRelayVRange,
          Env.transportConfig = mkTransportServerConfig True (Just alpnSupportedSMPHandshakes) True,
          controlPort = Nothing,
          smpAgentCfg = defaultSMPClientAgentConfig {persistErrorInterval = 1},
          allowSMPProxy = False,
          serverClientConcurrency = 16,
          information = Nothing,
          startOptions = StartOptions {maintenance = False, compactLog = False, logLevel = LogInfo, skipWarnings = True, confirmMigrations = MCYesUp}
        }

