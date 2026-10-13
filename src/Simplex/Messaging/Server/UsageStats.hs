{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}

module Simplex.Messaging.Server.UsageStats
  ( ClientAddr (..),
    UsageCounter (..),
    ClientCounts (..),
    ClientUsage (..),
    UsageHistogram (..),
    UsageStats (..),
    defaultUsagePeriod,
    countBounds,
    kilobyteBounds,
    clientAddr,
    clientAddrText,
    counterByName,
    newUsageStats,
    clientConnected,
    incUsage,
    addUsage,
    closeUsagePeriod,
    usagePeriodThread,
    topClients,
    printTopClients,
    usageMetrics,
  )
where

import Control.Monad
import Data.Functor ((<&>))
import Data.IORef
import Data.IP (AddrRange, IP (..), IPv4, IPv6, fromIPv6w, fromSockAddr, makeAddrRange, toIPv4w)
import Data.Int (Int64)
import qualified Data.IntMap.Strict as IM
import Data.List (find, sortOn)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Ord (Down (..))
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as T
import Network.Socket (SockAddr, Socket, getPeerName)
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Util (atomicModifyIORef'_, labelMyThread, threadDelay', tshow, ($>>=))
import System.IO (Handle, hPutStrLn)
import UnliftIO.Exception (tryAny)
import UnliftIO.STM

data ClientAddr
  = ClientIPv4 IPv4
  | ClientIPv6 (AddrRange IPv6)
  deriving (Eq, Ord, Show)

class (Ord c, Enum c, Bounded c) => UsageCounter c where
  counterName :: c -> Text
  counterBounds :: c -> [Int]
  counterBounds _ = countBounds
  connectionsCounter :: c

data ClientCounts c = ClientCounts
  { current :: TMap c (TVar Int),
    previous :: TVar (Map c Int)
  }

data ClientUsage c = ClientUsage (UsageStats c) ClientAddr

data UsageHistogram = UsageHistogram
  { bucketCounts :: IM.IntMap Int,
    usageSum :: Int,
    lastPeriodMax :: Int
  }
  deriving (Eq, Show)

data UsageStats c = UsageStats
  { clientCounts :: TMap ClientAddr (ClientCounts c),
    histograms :: IORef (Map c UsageHistogram)
  }

defaultUsagePeriod :: Int64
defaultUsagePeriod = 300

countBounds :: [Int]
countBounds = r10Bounds 5

kilobyteBounds :: [Int]
kilobyteBounds = r10Bounds 7

r10Bounds :: Int -> [Int]
r10Bounds decades =
  [1 .. 9]
    <> [(r * 10 ^ d + 50) `div` 100 | d <- [1 .. decades], r <- [100, 125, 160, 200, 250, 315, 400, 500, 630, 800]]
    <> [10 ^ (decades + 1)]

clientAddr :: SockAddr -> Maybe ClientAddr
clientAddr sa =
  fromSockAddr sa <&> \case
    (IPv4 a, _) -> ClientIPv4 a
    (IPv6 a, _) -> case fromIPv6w a of
      (0, 0, 0xffff, a4) -> ClientIPv4 $ toIPv4w a4
      _ -> ClientIPv6 $ makeAddrRange a 64

clientAddrText :: ClientAddr -> Text
clientAddrText = \case
  ClientIPv4 a -> tshow a
  ClientIPv6 r -> tshow r

counterByName :: UsageCounter c => Text -> Maybe c
counterByName name = find ((name ==) . counterName) [minBound .. maxBound]

newUsageStats :: UsageCounter c => IO (UsageStats c)
newUsageStats = UsageStats <$> TM.emptyIO <*> newIORef (M.fromList $ map (,emptyHistogram) [minBound .. maxBound])
  where
    emptyHistogram = UsageHistogram {bucketCounts = IM.empty, usageSum = 0, lastPeriodMax = 0}

clientConnected :: UsageCounter c => Socket -> Maybe (UsageStats c) -> IO (Maybe (ClientUsage c))
clientConnected sock stats_ =
  pure stats_ $>>= \stats ->
    tryAny (getPeerName sock) >>= \case
      Right sa | Just addr <- clientAddr sa -> do
        let usage = ClientUsage stats addr
        Just usage <$ incUsage usage connectionsCounter
      _ -> pure Nothing

incUsage :: UsageCounter c => ClientUsage c -> c -> IO ()
incUsage usage c = addUsage usage c 1

addUsage :: UsageCounter c => ClientUsage c -> c -> Int -> IO ()
addUsage (ClientUsage UsageStats {clientCounts} addr) c n = do
  ClientCounts {current} <- TM.lookupIO addr clientCounts >>= maybe newCounts pure
  TM.lookupIO c current >>= atomically . maybe (newCount current) add
  where
    add v = modifyTVar' v (+ n)
    newCount current = TM.lookup c current >>= maybe (TM.insertM c (newTVar $! n) current) add
    newCounts = do
      counts <- ClientCounts <$> TM.emptyIO <*> newTVarIO M.empty
      atomically $ TM.lookup addr clientCounts >>= maybe (counts <$ TM.insert addr counts clientCounts) pure

closeUsagePeriod :: UsageCounter c => UsageStats c -> IO ()
closeUsagePeriod UsageStats {clientCounts, histograms} = do
  closedCounts <- mapM closeClientPeriod . M.toList =<< readTVarIO clientCounts
  atomicModifyIORef'_ histograms $ M.mapWithKey $ \c -> addPeriodCounts (counterBounds c) (mapMaybe (M.lookup c) closedCounts)
  where
    closeClientPeriod (addr, ClientCounts {current, previous}) = do
      counts <- atomically $ do
        counts <- mapM readTVar =<< swapTVar current M.empty
        counts <$ writeTVar previous counts
      when (M.null counts) $ atomically $ TM.delete addr clientCounts
      pure counts

addPeriodCounts :: [Int] -> [Int] -> UsageHistogram -> UsageHistogram
addPeriodCounts bounds ns UsageHistogram {bucketCounts, usageSum} =
  UsageHistogram
    { bucketCounts = IM.unionWith (+) bucketCounts boundCounts,
      usageSum = usageSum + sum ns,
      lastPeriodMax = maximum (0 : ns)
    }
  where
    boundCounts = IM.fromListWith (+) $ map (\n -> (length $ takeWhile (< n) bounds, 1)) ns

usagePeriodThread :: UsageCounter c => Int64 -> UsageStats c -> IO ()
usagePeriodThread period stats = do
  labelMyThread "usagePeriodThread"
  forever $ threadDelay' (period * 1000000) >> closeUsagePeriod stats

topClients :: UsageCounter c => UsageStats c -> c -> Int -> IO [(ClientAddr, Int, Int)]
topClients UsageStats {clientCounts} c n = do
  entries <- M.toList <$> readTVarIO clientCounts
  counts <- forM entries $ \(addr, ClientCounts {previous, current}) -> (addr,,) <$> previousCount previous <*> currentCount current
  pure $ take n $ sortOn (\(_, p, cur) -> Down (p + cur)) $ filter (\(_, p, cur) -> p + cur > 0) counts
  where
    previousCount = fmap (M.findWithDefault 0 c) . readTVarIO
    currentCount = maybe (pure 0) readTVarIO <=< TM.lookupIO c

printTopClients :: UsageCounter c => Handle -> Text -> Maybe Int -> Maybe (UsageStats c) -> IO ()
printTopClients h name n_ = \case
  Just stats -> case counterByName name of
    Just c -> do
      rows <- topClients stats c (fromMaybe 10 n_)
      hPutStrLn h "address,previous,current"
      forM_ rows $ \(addr, p, cur) -> T.hPutStrLn h $ clientAddrText addr <> "," <> tshow p <> "," <> tshow cur
    Nothing -> hPutStrLn h "error: unknown counter"
  Nothing -> hPutStrLn h "error: usage statistics are off"

usageMetrics :: UsageCounter c => Text -> Text -> Map c UsageHistogram -> Text
usageMetrics prefix tsEpoch usageHistograms =
  "# Client usage\n\
  \# ------------\n\
  \\n"
    <> "# HELP " <> usageMetric <> " Clients by usage in a period\n"
    <> "# TYPE " <> usageMetric <> " histogram\n"
    <> T.concat (map histogramLines hs)
    <> "\n# HELP " <> maxMetric <> " Largest usage of one client in the last period\n"
    <> "# TYPE " <> maxMetric <> " gauge\n"
    <> T.concat (map (\(c, UsageHistogram {lastPeriodMax}) -> sample maxMetric c [] lastPeriodMax) hs)
    <> "\n"
  where
    hs = M.toList usageHistograms
    usageMetric = prefix <> "_client_usage"
    maxMetric = prefix <> "_client_usage_max"
    histogramLines (c, UsageHistogram {bucketCounts, usageSum}) =
      T.concat (zipWith (\b cnt -> sample (usageMetric <> "_bucket") c [("le", tshow b)] cnt) (counterBounds c) cumulativeCounts)
        <> sample (usageMetric <> "_bucket") c [("le", "+Inf")] clientCount
        <> sample (usageMetric <> "_sum") c [] usageSum
        <> sample (usageMetric <> "_count") c [] clientCount
      where
        cumulativeCounts = scanl1 (+) $ map (\i -> IM.findWithDefault 0 i bucketCounts) [0 ..]
        clientCount = sum bucketCounts
    sample metric c labels v =
      metric <> "{" <> T.intercalate "," (map (\(l, lv) -> l <> "=\"" <> lv <> "\"") (("counter", counterName c) : labels)) <> "} " <> tshow v <> " " <> tsEpoch <> "\n"
