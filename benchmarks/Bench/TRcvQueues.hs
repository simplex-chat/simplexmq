{-# LANGUAGE NamedFieldPuns #-}
{-# OPTIONS_GHC -Wno-missing-fields #-}
{-# LANGUAGE TypeApplications #-}

module Bench.TRcvQueues (benchTRcvQueues) where

import Test.Tasty.Bench
import qualified Simplex.Messaging.Agent.TRcvQueues as H
import qualified Simplex.Messaging.Agent.TRcvQueues.Ord as O
import qualified Simplex.Messaging.Agent.TRcvQueues.HAMT as HAMT
import Crypto.Random
import UnliftIO
import Simplex.Messaging.Agent.Store (RcvQueue, StoredRcvQueue(..))
import Simplex.Messaging.Protocol (ProtocolServer(..), SMPServer, SProtocolType(..))
import Simplex.Messaging.Transport.Client (TransportHost(..))
import Control.Monad (replicateM)
import Data.Hashable (hash)
import qualified Simplex.Messaging.Crypto as C
import Data.ByteString (ByteString)

benchTRcvQueues :: [Benchmark]
benchTRcvQueues =
  [ bgroup "getDelSessQueues"
      [ env (prepareOrd nUsers nServers nQueues) $ bench "ord" . nfAppIO (fmap length . benchTRcvQueuesOrd),
        env (prepareHash nUsers nServers nQueues) $ bcompare "ord" . bench "hash" . nfAppIO (fmap length . benchTRcvQueuesHash),
        env (prepareHamt nUsers nServers nQueues) $ bcompare "ord" . bench "hamt" . nfAppIO (fmap length . benchTRcvQueuesHamt)
      ]
  ]
  where
    nUsers = 4
    nServers = 10
    nQueues = 10000

prepareHash :: Int -> Int -> Int -> IO ([SMPServer], H.TRcvQueues)
prepareHash nUsers nServers nQueues = do
  let (servers, gen1) = genServers gen0 nServers
  let (qs, _gen2) = genQueues gen1 servers nUsers nQueues
  atomically $ do
    trqs <- H.empty
    mapM_ (`H.addQueue` trqs) qs
    pure (servers, trqs)

prepareOrd :: Int -> Int -> Int -> IO ([SMPServer], O.TRcvQueues)
prepareOrd nUsers nServers nQueues = do
  let (servers, gen1) = genServers gen0 nServers
  let (qs, _gen2) = genQueues gen1 servers nUsers nQueues
  atomically $ do
    trqs <- O.empty
    mapM_ (`O.addQueue` trqs) qs
    pure (servers, trqs)

prepareHamt :: Int -> Int -> Int -> IO ([SMPServer], HAMT.TRcvQueues)
prepareHamt nUsers nServers nQueues = do
  let (servers, gen1) = genServers gen0 nServers
  let (qs, _gen2) = genQueues gen1 servers nUsers nQueues
  atomically $ do
    trqs <- HAMT.empty
    mapM_ (`HAMT.addQueue` trqs) qs
    pure (servers, trqs)

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
    pure RcvQueue {userId, connId, server}
  where
    nServers = length servers

benchTRcvQueuesHash :: ([SMPServer], H.TRcvQueues) -> IO [RcvQueue]
benchTRcvQueuesHash (servers, qs) = atomically $ H.getDelSessQueues (1, head servers, Nothing) qs

benchTRcvQueuesOrd :: ([SMPServer], O.TRcvQueues) -> IO [RcvQueue]
benchTRcvQueuesOrd (servers, qs) = atomically $ O.getDelSessQueues (1, head servers, Nothing) qs

benchTRcvQueuesHamt :: ([SMPServer], HAMT.TRcvQueues) -> IO [RcvQueue]
benchTRcvQueuesHamt (servers, qs) = atomically $ HAMT.getDelSessQueues (1, head servers, Nothing) qs

gen0 :: ChaChaDRG
gen0 = drgNewSeed (seedFromInteger 100500)
