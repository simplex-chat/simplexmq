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
import qualified Simplex.Messaging.Agent.TRcvQueues as Base
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Protocol (ProtocolServer (..), SMPServer, SProtocolType (..))
import Simplex.Messaging.Transport.Client (TransportHost (..))
import Test.Tasty.Bench
import UnliftIO

benchTRcvQueues :: [Benchmark]
benchTRcvQueues =
  [ bgroup
      "getDelSessQueues"
      [ bench "baseline" $ whnfIO (pure ())
      ]
      --   bgroup
      --     "getDelSessQueues"
      --     [ env (prepareOrd nUsers nServers nQueues) $ bench "gds-ord" . nfAppIO (fmap length . benchTRcvQueuesOrd),
      --       env (prepareOrd nUsers nServers nQueues) $ bcompare "gds-ord" . bench "gds-flip" . nfAppIO (fmap length . benchTRcvQueuesOrdFlip)
      --     ]
  ]
  where
    nUsers = 4
    nServers = 10
    nQueues = 10000

-- benchTRcvQueuesHash :: (TSessKey, H.TRcvQueues) -> IO [RcvQueue]
-- benchTRcvQueuesHash (tSess, qs) = atomically $ H.getDelSessQueues tSess qs

type TSessKey = (UserId, SMPServer, Maybe ConnId)

prepareWith :: Int -> Int -> Int -> STM qs -> (qs -> RcvQueue -> STM ()) -> IO (TSessKey, qs)
prepareWith nUsers nServers nQueues initQS addQueue = do
  let (servers, gen1) = genServers gen0 nServers
  let (qs, _gen2) = genQueues gen1 servers nUsers nQueues
  atomically $ do
    trqs <- initQS
    mapM_ (addQueue trqs) qs
    pure (fmap (const Nothing) . Base.qKey $ head qs, trqs)

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
