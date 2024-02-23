{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module Bench.TRcvQueues where -- (benchTRcvQueues) where

import Control.Monad (replicateM)
import Crypto.Random
import Data.ByteString (ByteString)
import Data.HashSet (HashSet)
import Data.Hashable (hash)
import Data.Set (Set)
import Simplex.Messaging.Agent.Protocol (ConnId, QueueStatus (..), UserId)
import Simplex.Messaging.Agent.Store (DBQueueId (..), RcvQueue, StoredRcvQueue (..))
import qualified Simplex.Messaging.Agent.TRcvQueues as H
import qualified Simplex.Messaging.Agent.TRcvQueues.HAMT as HAMT
import qualified Simplex.Messaging.Agent.TRcvQueues.Ord as O
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Protocol (ProtocolServer (..), SMPServer, SProtocolType (..))
import Simplex.Messaging.Transport.Client (TransportHost (..))
import Test.Tasty.Bench
import UnliftIO

benchTRcvQueues :: [Benchmark]
benchTRcvQueues =
  [ bgroup
      "addQueue"
      [ bench "aq-ord" $ whnfIO (prepareOrd nUsers nServers nQueues),
        bcompare "aq-ord" . bench "aq-hash" $ whnfIO (prepareHash nUsers nServers nQueues),
        bcompare "aq-ord" . bench "aq-hamt" $ whnfIO (prepareHamt nUsers nServers nQueues)
      ],
    bgroup
      "getDelSessQueues"
      [ env (prepareOrd nUsers nServers nQueues) $ bench "gds-ord" . nfAppIO (fmap length . benchTRcvQueuesOrd),
        env (prepareOrd nUsers nServers nQueues) $ bcompare "gds-ord" . bench "gds-flip" . nfAppIO (fmap length . benchTRcvQueuesOrdFlip),
        env (prepareHash nUsers nServers nQueues) $ bcompare "gds-ord" . bench "gds-hash" . nfAppIO (fmap length . benchTRcvQueuesHash),
        env (prepareHash nUsers nServers nQueues) $ bcompare "gds-ord" . bench "gds-hash-flip" . nfAppIO (fmap length . benchTRcvQueuesHashFlip),
        env (prepareHamt nUsers nServers nQueues) $ bcompare "gds-ord" . bench "gds-hamt" . nfAppIO (fmap length . benchTRcvQueuesHamt)
      ],
    bgroup
      "getConns"
      [ env (prepareOrd nUsers nServers nQueues) $ bench "gc-Set" . nfAppIO (benchTRcvQueuesSet . snd),
        env (prepareOrd nUsers nServers nQueues) $ bcompare "gc-Set" . bench "gc-LeftFold" . nfAppIO (benchTRcvQueuesLeftFold . snd),
        env (prepareHash nUsers nServers nQueues) $ bcompare "gc-Set" . bench "gc-HashSet" . nfAppIO (benchTRcvQueuesHashSet . snd)
      ]
  ]
  where
    nUsers = 4
    nServers = 10
    nQueues = 10000

benchTRcvQueuesHash :: (TSessKey, H.TRcvQueues) -> IO [RcvQueue]
benchTRcvQueuesHash (tSess, qs) = atomically $ H.getDelSessQueues tSess qs

benchTRcvQueuesHashFlip :: (TSessKey, H.TRcvQueues) -> IO [RcvQueue]
benchTRcvQueuesHashFlip (tSess, qs) = atomically $ H.getDelSessQueuesFlip tSess qs

benchTRcvQueuesOrd :: (TSessKey, O.TRcvQueues) -> IO [RcvQueue]
benchTRcvQueuesOrd (tSess, qs) = atomically $ O.getDelSessQueues tSess qs

benchTRcvQueuesOrdFlip :: (TSessKey, O.TRcvQueues) -> IO [RcvQueue]
benchTRcvQueuesOrdFlip (tSess, qs) = atomically $ O.getDelSessQueuesFlip tSess qs

benchTRcvQueuesHamt :: (TSessKey, HAMT.TRcvQueues) -> IO [RcvQueue]
benchTRcvQueuesHamt (tSess, qs) = atomically $ HAMT.getDelSessQueues tSess qs

benchTRcvQueuesSet :: O.TRcvQueues -> IO (Set ConnId)
benchTRcvQueuesSet = atomically . O.getConns

benchTRcvQueuesLeftFold :: O.TRcvQueues -> IO (Set ConnId)
benchTRcvQueuesLeftFold = atomically . O.getConnsL

benchTRcvQueuesHashSet :: H.TRcvQueues -> IO (HashSet ConnId)
benchTRcvQueuesHashSet = atomically . H.getConnsHS

type TSessKey = (UserId, SMPServer, Maybe ConnId)

prepareHash :: Int -> Int -> Int -> IO (TSessKey, H.TRcvQueues)
prepareHash nUsers nServers nQueues = do
  let (servers, gen1) = genServers gen0 nServers
  let (qs, _gen2) = genQueues gen1 servers nUsers nQueues
  atomically $ do
    trqs <- H.empty
    mapM_ (`H.addQueue` trqs) qs
    pure (fmap (const Nothing) . H.qKey $ head qs, trqs)

prepareOrd :: Int -> Int -> Int -> IO (TSessKey, O.TRcvQueues)
prepareOrd nUsers nServers nQueues = do
  let (servers, gen1) = genServers gen0 nServers
  let (qs, _gen2) = genQueues gen1 servers nUsers nQueues
  atomically $ do
    trqs <- O.empty
    mapM_ (`O.addQueue` trqs) qs
    pure (fmap (const Nothing) . O.qKey $ head qs, trqs)

prepareHamt :: Int -> Int -> Int -> IO (TSessKey, HAMT.TRcvQueues)
prepareHamt nUsers nServers nQueues = do
  let (servers, gen1) = genServers gen0 nServers
  let (qs, _gen2) = genQueues gen1 servers nUsers nQueues
  atomically $ do
    trqs <- HAMT.empty
    mapM_ (`HAMT.addQueue` trqs) qs
    pure (fmap (const Nothing) . HAMT.qKey $ head qs, trqs)

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
