{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}

module Bench.TRcvQueues where

import Control.Monad (replicateM, unless)
import Crypto.Random
import Data.Bifunctor (bimap)
import Data.ByteString (ByteString)
import Data.Hashable (hash)
import qualified Data.Set as S
import GHC.IO (unsafePerformIO)
import Simplex.Messaging.Agent.Protocol (ConnId, QueueStatus (..), UserId)
import Simplex.Messaging.Agent.Store (DBQueueId (..), RcvQueue, StoredRcvQueue (..))
import qualified Simplex.Messaging.Agent.TRcvQueues as Current
import qualified Simplex.Messaging.Agent.TRcvQueues.Master as Master
import qualified Simplex.Messaging.Agent.TRcvQueues.Master.RS as MasterRS
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Protocol (ProtocolServer (..), SMPServer, SProtocolType (..))
import Simplex.Messaging.Transport.Client (TransportHost (..))
import Test.Hspec
import Test.Tasty.Bench
import Test.Tasty.Hspec (testSpec)
import UnliftIO
import qualified Data.Map.Strict as M

benchTRcvQueues :: [Benchmark]
benchTRcvQueues =
  [ bgroup
      "addQueue"
      [ bench "aq-master" $ nfIO prepareMaster,
        bcompare "aq-master" . bench "aq-current" $ nfIO prepareCurrent
      ],
    bgroup "getDelSessQueues" benchGDS,
    bgroup "removeSubs" benchRS,
    bgroup "resubscribe" benchResubscribe
  ]

benchGDS :: [Benchmark]
benchGDS =
  [ env prepareMaster $ bench "gds-master" . nfAppIO (fmap length . benchGDSMaster),
    env prepareCurrent $ bcompare "gds-master" . bench "gds-current" . nfAppIO (fmap (bimap length length) . benchGDSCurrent),
    unsafePerformIO $ testSpec "gds-equiv" testGDSequivalent
  ]
  where
    benchGDSMaster (tSess, qs) = atomically $ Master.getDelSessQueuesFlip tSess qs
    benchGDSCurrent (tSess, qs) = atomically $ Current.getDelSessQueues tSess qs
    testGDSequivalent = it "same" $ do
      m@(mKey, _) <- prepareMaster
      c@(cKey, _) <- prepareCurrent
      mKey `shouldBe` cKey
      qsMaster <- benchGDSMaster m
      (qsCurrent, _connIds) <- benchGDSCurrent c
      length qsMaster `shouldNotBe` 0
      length qsMaster `shouldBe` length qsCurrent
      qsMaster `shouldBe` qsCurrent

benchRS :: [Benchmark]
benchRS =
  [ env prepareMaster $ bench "rs-master" . nfAppIO (fmap (bimap length length) . benchRSMaster),
    env prepareMaster $ bcompare "rs-master" . bench "rs-set-building" . nfAppIO (fmap (bimap length length) . benchRSMasterSetBuilding),
    env prepareMaster $ bcompare "rs-master" . bench "rs-same-module" . nfAppIO (fmap (bimap length length) . benchRSMasterSameModule),
    env prepareCurrent $ bcompare "rs-master" . bench "rs-current" . nfAppIO (fmap (bimap length length) . benchRSCurrent),
    unsafePerformIO $ testSpec "rs-equiv" testRSequivalent
  ]
  where
    benchRSMaster (tSess, qs) = atomically $ Master.empty >>= MasterRS.removeSubs tSess qs
    benchRSMasterSetBuilding (tSess, qs) = atomically $ Master.empty >>= MasterRS.removeSubsSet tSess qs
    benchRSMasterSameModule (tSess, qs) = atomically $ Master.empty >>= Master.removeSubs tSess qs
    benchRSCurrent (tSess, qs) = atomically $ Current.empty >>= Current.removeSubs tSess qs
    testRSequivalent = it "same" $ do
      m <- prepareMaster
      c <- prepareCurrent
      (qsMaster, connsMaster) <- benchRSMaster m
      (qsCurrent, connsCurrent) <- benchRSCurrent c
      length qsMaster `shouldNotBe` 0
      length qsMaster `shouldBe` length qsCurrent
      length connsMaster `shouldBe` length connsCurrent
      qsMaster `shouldBe` qsCurrent

benchResubscribe :: [Benchmark]
benchResubscribe =
  [ env (prepareMaster >>= pickActiveMaster 1.0) $ bench "resub-master-full" . nfAppIO benchResubMaster, -- worst case
    env (prepareMaster >>= pickActiveMaster 0.5) $ bench "resub-master-half" . nfAppIO benchResubMaster,
    env (prepareMaster >>= pickActiveMaster 0.0) $ bench "resub-master-none" . nfAppIO benchResubMaster,
    env (prepareCurrent >>= pickActiveCurrent 1.0) $ bcompare "resub-master-full" . bench "resub-current-full" . nfAppIO benchResubCurrent,
    env (prepareCurrent >>= pickActiveCurrent 0.5) $ bcompare "resub-master-half" . bench "resub-current-half" . nfAppIO benchResubCurrent,
    env (prepareCurrent >>= pickActiveCurrent 0.0) $ bcompare "resub-master-none" . bench "resub-current-none" . nfAppIO benchResubCurrent
  ]
  where
    pickActiveMaster rOk (_tsess, activeSubs) = do
      ok <- atomically $ Master.getConns activeSubs
      let num = fromIntegral (S.size ok) * rOk :: Float
      let ok' = take (round num) $ S.toList ok
      pure (ok', activeSubs)
    benchResubMaster (okConns, activeSubs) = do
      cs <- atomically $ Master.getConns activeSubs
      let conns = filter (`S.notMember` cs) okConns
      unless (null conns) $ pure ()

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
    nQueues = 50000

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
