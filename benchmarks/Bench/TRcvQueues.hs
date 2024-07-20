{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module Bench.TRcvQueues where

import Control.Monad (replicateM, unless)
import Crypto.Random
import Data.Bifunctor (bimap)
import Data.ByteString (ByteString)
import Data.Hashable (hash)
import Simplex.Messaging.Agent.Protocol (ConnId, QueueStatus (..), UserId)
import Simplex.Messaging.Agent.Store (DBQueueId (..), RcvQueue, StoredRcvQueue (..))
import qualified Simplex.Messaging.Agent.TRcvQueues as Current
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Protocol (ProtocolServer (..), SMPServer, SProtocolType (..), currentSMPClientVersion)
import Simplex.Messaging.Transport.Client (TransportHost (..))
import Test.Tasty.Bench
import qualified Data.Map.Strict as M
import UnliftIO

-- For quick equivalence tests
-- import GHC.IO (unsafePerformIO)
-- import Test.Hspec
-- import Test.Tasty.Hspec (testSpec)


benchTRcvQueues :: [Benchmark]
benchTRcvQueues =
  [ bgroup
      "addQueue"
      [ bench "aq-current" $ nfIO prepareCurrent,
        bcompare "aq-current" . bench "aq-batch" $ nfIO prepareCurrentBatch
      ],
    bgroup "getDelSessQueues" benchGDS,
    bgroup "resubscribe" benchResubscribe
  ]

benchGDS :: [Benchmark]
benchGDS =
  [ env prepareCurrent $ bench "gds-current" . nfAppIO (fmap (bimap length length) . benchGDSCurrent)
  -- unsafePerformIO $ testSpec "gds-equiv" testGDSequivalent
  ]
  where
    benchGDSCurrent (tSess, qs) = atomically $ Current.getDelSessQueues tSess qs

-- testGDSequivalent = it "same" $ do
--   m@(mKey, _) <- prepareMaster
--   c@(cKey, _) <- prepareCurrent
--   mKey `shouldBe` cKey
--   qsMaster <- benchGDSMaster m
--   (qsCurrent, _connIds) <- benchGDSCurrent c
--   length qsMaster `shouldNotBe` 0
--   length qsMaster `shouldBe` length qsCurrent
--   qsMaster `shouldBe` qsCurrent

benchResubscribe :: [Benchmark]
benchResubscribe =
  [ env (prepareCurrent >>= pickActiveCurrent 1.0) $ bench "resub-current-full" . nfAppIO benchResubCurrent,
    env (prepareCurrent >>= pickActiveCurrent 0.5) $ bench "resub-current-half" . nfAppIO benchResubCurrent,
    env (prepareCurrent >>= pickActiveCurrent 0.0) $ bench "resub-current-none" . nfAppIO benchResubCurrent
  ]
  where
    pickActiveCurrent rOk (_tsess, activeSubs) = do
      ok <- readTVarIO $ Current.getConnections activeSubs
      let num = fromIntegral (M.size ok) * rOk :: Float
      let ok' = take (round num) $ M.keys ok
      pure (ok', activeSubs)
    benchResubCurrent (okConns, activeSubs) = do
      cs <- readTVarIO $ Current.getConnections activeSubs
      let conns = filter (`M.notMember` cs) okConns
      unless (null conns) $ pure ()

type TSessKey = (UserId, SMPServer, Maybe ConnId)

prepareCurrent :: IO (TSessKey, Current.TRcvQueues)
prepareCurrent = prepareWith Current.empty Current.addQueue

prepareCurrentBatch :: IO (TSessKey, Current.TRcvQueues)
prepareCurrentBatch = prepareQueues Current.empty Current.batchAddQueues

prepareWith :: STM qs -> (RcvQueue -> qs -> STM ()) -> IO (TSessKey, qs)
prepareWith initQS addQueue = prepareQueues initQS (\trqs qs -> mapM_ (`addQueue` trqs) qs)

prepareQueues :: STM qs -> (qs -> [RcvQueue] -> STM ()) -> IO (TSessKey, qs)
prepareQueues initQS addQueues = do
  let (servers, gen1) = genServers gen0 nServers
  let (qs, _gen2) = genQueues gen1 servers nUsers nQueues
  atomically $ do
    trqs <- initQS
    addQueues trqs qs
    pure (fmap (const Nothing) . Current.qKey $ head qs, trqs)
  where
    nUsers = 4
    nServers = 10
    nQueues = 10000

genServers :: ChaChaDRG -> Int -> ([SMPServer], ChaChaDRG)
genServers random nServers =
  withDRG random . replicateM nServers $ do
    host <- THOnionHost <$> getRandomBytes 32
    keyHash <- C.KeyHash <$> getRandomBytes 64
    pure ProtocolServer {scheme = SPSMP, host = pure host, port = "12345", keyHash}

genQueues :: ChaChaDRG -> [SMPServer] -> Int -> Int -> ([RcvQueue], ChaChaDRG)
genQueues random servers nUsers nQueues =
  withDRG random . replicateM nQueues $ do
    userRandom <- hash @ByteString <$> getRandomBytes 8
    let userId = fromIntegral $ userRandom `mod` nUsers
    connId <- getRandomBytes 10
    serverRandom <- hash @ByteString <$> getRandomBytes 8
    let server = servers !! (serverRandom `mod` nServers)
    pure
      RcvQueue
        { userId,
          connId,
          server,
          rcvId = "",
          rcvPrivateKey = C.APrivateAuthKey C.SEd25519 "MC4CAQAwBQYDK2VwBCIEIDfEfevydXXfKajz3sRkcQ7RPvfWUPoq6pu1TYHV1DEe",
          rcvDhSecret = "01234567890123456789012345678901",
          e2ePrivKey = "MC4CAQAwBQYDK2VuBCIEINCzbVFaCiYHoYncxNY8tSIfn0pXcIAhLBfFc0m+gOpk",
          e2eDhSecret = Nothing,
          sndId = "",
          sndSecure = False,
          status = New,
          dbQueueId = DBQueueId 0,
          primary = True,
          dbReplaceQueueId = Nothing,
          rcvSwchStatus = Nothing,
          smpClientVersion = currentSMPClientVersion,
          clientNtfCreds = Nothing,
          deleteErrors = 0
        }
  where
    nServers = length servers

gen0 :: ChaChaDRG
gen0 = drgNewSeed (seedFromInteger 100500)
