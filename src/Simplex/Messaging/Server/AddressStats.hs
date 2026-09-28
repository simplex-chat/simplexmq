{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}

module Simplex.Messaging.Server.AddressStats
  ( AddrKey (..),
    AddrCounter (..),
    AddrStats (..),
    AddrStatsMap,
    AddrHistogram (..),
    ServerAddrStats (..),
    AddressStatsConfig (..),
    defaultAddressStatsPeriod,
    countBounds,
    kilobyteBounds,
    addrKey,
    addrKeyText,
    counterByName,
    newServerAddrStats,
    withAddrStats,
    openAddrStats,
    closeAddrStats,
    incAddrCounter,
    addAddrCounter,
    rolloverAddrStats,
    addressStatsThread,
    topAddresses,
    printTopAddresses,
    addressesArgsP,
    addressesArgs,
    addrHistogramMetrics,
  )
where

import Control.Applicative (optional)
import Control.Monad
import Control.Monad.IO.Unlift
import qualified Data.Attoparsec.ByteString.Char8 as A
import Data.Bits (shiftL, shiftR, (.&.), (.|.))
import Data.ByteString.Char8 (ByteString)
import Data.IORef
import Data.Int (Int64)
import qualified Data.IntMap.Strict as IM
import Data.List (find, foldl', sortOn)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe)
import Data.Ord (Down (..))
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (encodeUtf8)
import qualified Data.Text.IO as T
import Data.Word (Word32, Word64)
import Network.Socket (SockAddr (..), Socket, getPeerName, hostAddress6ToTuple, hostAddressToTuple)
import Numeric (showHex)
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Util (atomicModifyIORef'_, bshow, labelMyThread, safeDecodeUtf8, threadDelay', tshow, whenM, (<$$>))
import System.IO (Handle, hPutStrLn)
import UnliftIO.Exception (finally, tryAny)
import UnliftIO.STM

data AddrKey
  = AKIPv4 Word32
  | AKIPv6 Word64
  deriving (Eq, Ord, Show)

class (Ord c, Enum c, Bounded c) => AddrCounter c where
  counterName :: c -> Text
  counterBounds :: c -> [Int]
  counterBounds _ = countBounds
  connectionsCounter :: c

data AddrStats c = AddrStats
  { connectionsCount :: TVar Int,
    current :: Map c (IORef Int),
    previous :: Map c (IORef Int)
  }

type AddrStatsMap c = TMap AddrKey (AddrStats c)

data AddrHistogram = AddrHistogram
  { bucketCounts :: [Int],
    countSum :: Int,
    addressCount :: Int,
    periodMax :: Int
  }
  deriving (Eq, Show)

data ServerAddrStats c = ServerAddrStats
  { addrStatsMap :: AddrStatsMap c,
    addrHistograms :: IORef (Map c AddrHistogram)
  }

newtype AddressStatsConfig = AddressStatsConfig
  { period :: Int64
  }
  deriving (Show)

defaultAddressStatsPeriod :: Int64
defaultAddressStatsPeriod = 300

countBounds :: [Int]
countBounds = r10Bounds 5

kilobyteBounds :: [Int]
kilobyteBounds = r10Bounds 7

r10Bounds :: Int -> [Int]
r10Bounds decades =
  [1 .. 9]
    <> [(r * 10 ^ d + 50) `div` 100 | d <- [1 .. decades], r <- [100, 125, 160, 200, 250, 315, 400, 500, 630, 800]]
    <> [10 ^ (decades + 1)]

addrKey :: SockAddr -> Maybe AddrKey
addrKey = \case
  SockAddrInet _ a ->
    let (b1, b2, b3, b4) = hostAddressToTuple a
     in Just $ AKIPv4 $ foldl' (\acc b -> acc `shiftL` 8 .|. fromIntegral b) 0 [b1, b2, b3, b4]
  SockAddrInet6 _ _ a _ -> Just $ case hostAddress6ToTuple a of
    (0, 0, 0, 0, 0, 0xffff, w1, w2) -> AKIPv4 $ fromIntegral w1 `shiftL` 16 .|. fromIntegral w2
    (w1, w2, w3, w4, _, _, _, _) -> AKIPv6 $ foldl' (\acc w -> acc `shiftL` 16 .|. fromIntegral w) 0 [w1, w2, w3, w4]
  _ -> Nothing

addrKeyText :: AddrKey -> Text
addrKeyText = \case
  AKIPv4 a -> T.intercalate "." $ map (\s -> tshow $ (a `shiftR` s) .&. 0xff) [24, 16, 8, 0]
  AKIPv6 p -> T.intercalate ":" (map (\s -> T.pack $ showHex ((p `shiftR` s) .&. 0xffff) "") [48, 32, 16, 0]) <> "::/64"

counterByName :: AddrCounter c => Text -> Maybe c
counterByName name = find ((name ==) . counterName) [minBound .. maxBound]

newServerAddrStats :: AddrCounter c => IO (ServerAddrStats c)
newServerAddrStats = ServerAddrStats <$> TM.emptyIO <*> newIORef (M.fromList $ map (\c -> (c, emptyHistogram c)) [minBound .. maxBound])
  where
    emptyHistogram c = AddrHistogram {bucketCounts = map (const 0) (counterBounds c), countSum = 0, addressCount = 0, periodMax = 0}

newAddrStats :: AddrCounter c => IO (AddrStats c)
newAddrStats = AddrStats <$> newTVarIO 0 <*> newCells <*> newCells
  where
    newCells = M.fromList <$> mapM (\c -> (c,) <$> newIORef 0) [minBound .. maxBound]

withAddrStats :: (AddrCounter c, MonadUnliftIO m) => Maybe (AddrStatsMap c) -> Socket -> (Maybe (AddrStats c) -> m a) -> m a
withAddrStats m_ sock action = case m_ of
  Just m ->
    liftIO (addrKey <$$> tryAny (getPeerName sock)) >>= \case
      Right (Just k) -> do
        s <- liftIO $ openAddrStats m k
        action (Just s) `finally` liftIO (closeAddrStats s)
      _ -> action Nothing
  Nothing -> action Nothing

openAddrStats :: AddrCounter c => AddrStatsMap c -> AddrKey -> IO (AddrStats c)
openAddrStats m k = do
  new <- maybe newAddrStats pure =<< TM.lookupIO k m
  s <- atomically $ TM.lookup k m >>= maybe (new <$ TM.insert k new m) pure >>= \entry -> entry <$ modifyTVar' (connectionsCount entry) (+ 1)
  s <$ incAddrCounter s connectionsCounter

closeAddrStats :: AddrStats c -> IO ()
closeAddrStats AddrStats {connectionsCount} = atomically $ modifyTVar' connectionsCount (subtract 1)

incAddrCounter :: AddrCounter c => AddrStats c -> c -> IO ()
incAddrCounter s c = addAddrCounter s c 1

addAddrCounter :: AddrCounter c => AddrStats c -> c -> Int -> IO ()
addAddrCounter AddrStats {current} c n = forM_ (M.lookup c current) $ \cell -> atomicModifyIORef'_ cell (+ n)

rolloverAddrStats :: AddrCounter c => ServerAddrStats c -> IO ()
rolloverAddrStats ServerAddrStats {addrStatsMap, addrHistograms} = do
  entries <- M.toList <$> readTVarIO addrStatsMap
  closingCounts <- forM entries $ \(k, s) -> do
    counts <- closePeriod s
    when (all (== 0) counts) $ atomically $ deleteIdle k s
    pure counts
  let periodCounts = M.unionsWith (<>) $ map (M.map (: []) . M.filter (> 0)) closingCounts
  atomicModifyIORef'_ addrHistograms $ M.mapWithKey $ \c -> addPeriodCounts (counterBounds c) (M.findWithDefault [] c periodCounts)
  where
    closePeriod AddrStats {current, previous} = M.traverseWithKey closeCell current
      where
        closeCell c cell = do
          n <- atomicModifyIORef' cell (0,)
          forM_ (M.lookup c previous) (`writeIORef` n)
          pure n
    deleteIdle k AddrStats {connectionsCount} =
      whenM ((0 ==) <$> readTVar connectionsCount) $ TM.delete k addrStatsMap

addPeriodCounts :: [Int] -> [Int] -> AddrHistogram -> AddrHistogram
addPeriodCounts bounds ns AddrHistogram {bucketCounts, countSum, addressCount} =
  AddrHistogram
    { bucketCounts = zipWith (+) bucketCounts $ scanl1 (+) $ map (\i -> IM.findWithDefault 0 i boundCounts) [0 .. length bounds - 1],
      countSum = countSum + sum ns,
      addressCount = addressCount + length ns,
      periodMax = maximum (0 : ns)
    }
  where
    boundCounts = IM.fromListWith (+) $ map (\n -> (length $ takeWhile (< n) bounds, 1)) ns

addressStatsThread :: AddrCounter c => AddressStatsConfig -> ServerAddrStats c -> IO ()
addressStatsThread AddressStatsConfig {period} stats = do
  labelMyThread "addressStatsThread"
  forever $ threadDelay' (period * 1000000) >> rolloverAddrStats stats

topAddresses :: AddrCounter c => AddrStatsMap c -> c -> Int -> IO [(AddrKey, Int, Int)]
topAddresses m c n = do
  entries <- M.toList <$> readTVarIO m
  counts <- forM entries $ \(k, AddrStats {previous, current}) -> (k,,) <$> cellValue previous <*> cellValue current
  pure $ take n $ sortOn (\(_, p, cur) -> Down (p + cur)) $ filter (\(_, p, cur) -> p + cur > 0) counts
  where
    cellValue = maybe (pure 0) readIORef . M.lookup c

printTopAddresses :: AddrCounter c => Handle -> Maybe (AddrStatsMap c) -> Text -> Maybe Int -> IO ()
printTopAddresses h m_ name n_ = case m_ of
  Just m -> case counterByName name of
    Just c -> do
      rows <- topAddresses m c (fromMaybe 10 n_)
      hPutStrLn h "address,previous,current"
      forM_ rows $ \(k, p, cur) -> T.hPutStrLn h $ addrKeyText k <> "," <> tshow p <> "," <> tshow cur
    Nothing -> hPutStrLn h "error: unknown counter"
  Nothing -> hPutStrLn h "error: address statistics are off"

addressesArgsP :: A.Parser (Text, Maybe Int)
addressesArgsP = (,) <$> (A.space *> (safeDecodeUtf8 <$> A.takeTill (== ' '))) <*> optional (A.space *> A.decimal)

addressesArgs :: Text -> Maybe Int -> ByteString
addressesArgs name n_ = encodeUtf8 name <> maybe "" ((" " <>) . bshow) n_

addrHistogramMetrics :: AddrCounter c => Text -> Text -> Map c AddrHistogram -> Text
addrHistogramMetrics prefix tsEpoch histograms =
  "# Client addresses\n\
  \# ----------------\n\
  \\n"
    <> "# HELP " <> countMetric <> " Counts of client addresses per period\n"
    <> "# TYPE " <> countMetric <> " histogram\n"
    <> T.concat (map countLines hs)
    <> "\n# HELP " <> maxMetric <> " Maximum count of a client address in the last period\n"
    <> "# TYPE " <> maxMetric <> " gauge\n"
    <> T.concat (map (\(c, AddrHistogram {periodMax}) -> sample maxMetric c [] periodMax) hs)
    <> "\n"
  where
    hs = M.toList histograms
    countMetric = prefix <> "_client_address_period_count"
    maxMetric = prefix <> "_client_address_period_max"
    countLines (c, AddrHistogram {bucketCounts, countSum, addressCount}) =
      T.concat (zipWith (\b cnt -> sample (countMetric <> "_bucket") c [("le", tshow b)] cnt) (counterBounds c) bucketCounts)
        <> sample (countMetric <> "_bucket") c [("le", "+Inf")] addressCount
        <> sample (countMetric <> "_sum") c [] countSum
        <> sample (countMetric <> "_count") c [] addressCount
    sample metric c labels v =
      metric <> "{" <> T.intercalate "," (map (\(l, lv) -> l <> "=\"" <> lv <> "\"") (("counter", counterName c) : labels)) <> "} " <> tshow v <> " " <> tsEpoch <> "\n"
