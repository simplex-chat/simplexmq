{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module Bench.TRcvQueues where -- (benchTRcvQueues) where

import Control.Monad (replicateM, unless)
import Crypto.Random
import Data.Bifunctor (bimap)
import Data.ByteString (ByteString)
import Data.HashSet (HashSet)
import Data.Hashable (hash)
import Data.Set (Set)
import GHC.IO (unsafePerformIO)
import Simplex.Messaging.Agent.Protocol (ConnId, QueueStatus (..), UserId)
import Simplex.Messaging.Agent.Store (DBQueueId (..), RcvQueue, StoredRcvQueue (..))
import qualified Simplex.Messaging.Agent.TRcvQueues as Current
import qualified Simplex.Messaging.Agent.TRcvQueues.Master as Master
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Protocol (ProtocolServer (..), SMPServer, SProtocolType (..))
import Simplex.Messaging.Transport.Client (TransportHost (..))
import Test.Hspec
import Test.Tasty.Bench
import Test.Tasty.Hspec (testSpec)
import UnliftIO

benchTRcvQueues :: [Benchmark]
benchTRcvQueues =
  [ bgroup
      "addQueue"
      [ bench "aq-master" $ nfIO prepareMaster,
        bcompare "aq-master" . bench "aq-current" $ nfIO prepareCurrent
      ],
    bgroup
      "getDelSessQueues"
      [ env prepareMaster $ bench "gds-master" . nfAppIO (fmap length . benchGDSMaster),
        env prepareCurrent $ bcompare "gds-master" . bench "gds-current" . nfAppIO (fmap (bimap length length) . benchGDSCurrent),
        unsafePerformIO $ testSpec "gds-equiv" testGDSequivalent
      ]
  ]

testGDSequivalent :: Spec
testGDSequivalent = it "same" $ do
  m@(mKey, master) <- prepareMaster
  c@(cKey, current) <- prepareCurrent
  mKey `shouldBe` cKey
  qsMaster <- benchGDSMaster m
  (qsCurrent, _connIds) <- benchGDSCurrent c
  length qsMaster `shouldBe` length qsCurrent
  qsMaster `shouldBe` qsCurrent

benchGDSMaster :: (TSessKey, Master.TRcvQueues) -> IO [RcvQueue]
benchGDSMaster (tSess, qs) = atomically $ Master.getDelSessQueues tSess qs

benchGDSCurrent :: (TSessKey, Current.TRcvQueues) -> IO ([RcvQueue], [ConnId])
benchGDSCurrent (tSess, qs) = atomically $ Current.getDelSessQueues tSess qs

type TSessKey = (UserId, SMPServer, Maybe ConnId)

prepareMaster :: IO (TSessKey, Master.TRcvQueues)
prepareMaster = prepareWith Master.empty Master.addQueue

prepareCurrent :: IO (TSessKey, Current.TRcvQueues)
prepareCurrent = prepareWith Current.empty Current.addQueue

prepareWith :: STM qs -> (RcvQueue -> qs -> STM ()) -> IO (TSessKey, qs)
prepareWith initQS addQueue = do
  let (servers, gen1) = genServers gen0 nServers
  let (qs, _gen2) = genQueues gen1 servers nUsers nQueues
  atomically $ do
    trqs <- initQS
    mapM_ (`addQueue` trqs) qs
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
          rcvPrivateKey = C.APrivateSignKey C.SEd25519 "MC4CAQAwBQYDK2VwBCIEIDfEfevydXXfKajz3sRkcQ7RPvfWUPoq6pu1TYHV1DEe", -- C.APrivateAuthKey C.SEd25519 "MC4CAQAwBQYDK2VwBCIEIDfEfevydXXfKajz3sRkcQ7RPvfWUPoq6pu1TYHV1DEe",
          rcvDhSecret = "01234567890123456789012345678901",
          e2ePrivKey = "MC4CAQAwBQYDK2VuBCIEINCzbVFaCiYHoYncxNY8tSIfn0pXcIAhLBfFc0m+gOpk",
          e2eDhSecret = Nothing,
          sndId = "",
          status = New,
          dbQueueId = DBQueueId 0,
          primary = True,
          dbReplaceQueueId = Nothing,
          rcvSwchStatus = Nothing,
          smpClientVersion = 123,
          clientNtfCreds = Nothing,
          deleteErrors = 0
        }
  where
    nServers = length servers

gen0 :: ChaChaDRG
gen0 = drgNewSeed (seedFromInteger 100500)
