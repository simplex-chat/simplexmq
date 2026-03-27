{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

module Report
  ( Snapshot (..),
    takeSnapshot,
    printSummary,
    writeTimeSeriesHeader,
    appendTimeSeries,
  )
where

import Control.Concurrent (threadDelay)
import Data.List (foldl')
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as T
import Data.Time.Clock (UTCTime, getCurrentTime)
import Data.Time.Format.ISO8601 (iso8601Show)
import Data.Word (Word32, Word64)
import GHC.Stats (RTSStats (..), GCDetails (..), getRTSStats)
import System.IO (Handle, IOMode (..), hFlush, hSetBuffering, BufferMode (..), withFile)
import System.Mem (performMajorGC)

data Snapshot = Snapshot
  { snapTime :: UTCTime,
    snapPhase :: Text,
    snapLive :: Word64,
    snapHeap :: Word64,
    snapLarge :: Word64,
    snapFrag :: Word64,
    snapGCs :: Word32,
    snapClients :: Int
  }

takeSnapshot :: Text -> Int -> IO Snapshot
takeSnapshot phase clients = do
  performMajorGC
  threadDelay 1_000_000
  rts <- getRTSStats
  ts <- getCurrentTime
  let GCDetails {gcdetails_live_bytes, gcdetails_mem_in_use_bytes, gcdetails_large_objects_bytes, gcdetails_block_fragmentation_bytes} = gc rts
  pure
    Snapshot
      { snapTime = ts,
        snapPhase = phase,
        snapLive = gcdetails_live_bytes,
        snapHeap = gcdetails_mem_in_use_bytes,
        snapLarge = gcdetails_large_objects_bytes,
        snapFrag = gcdetails_block_fragmentation_bytes,
        snapGCs = gcs rts,
        snapClients = clients
      }

printSummary :: [Snapshot] -> IO ()
printSummary [] = putStrLn "No snapshots collected."
printSummary snaps = do
  putStrLn ""
  putStrLn hdr
  putStrLn $ replicate (length hdr) '-'
  mapM_ printRow (zip (Snapshot {snapLive = 0, snapHeap = 0, snapLarge = 0, snapFrag = 0, snapGCs = 0, snapClients = 0, snapPhase = "", snapTime = snapTime (head snaps)} : snaps) snaps)
  where
    hdr = padR 20 "Phase" <> padL 12 "live_MB" <> padL 12 "large_MB" <> padL 12 "frag_MB" <> padL 12 "heap_MB" <> padL 10 "clients" <> padL 14 "d_live_MB" <> padL 14 "d_large_MB" <> padL 14 "KB/client"
    printRow (prev, cur) =
      putStrLn $
        padR 20 (T.unpack $ snapPhase cur)
          <> padL 12 (showMB $ snapLive cur)
          <> padL 12 (showMB $ snapLarge cur)
          <> padL 12 (showMB $ snapFrag cur)
          <> padL 12 (showMB $ snapHeap cur)
          <> padL 10 (show $ snapClients cur)
          <> padL 14 (showDeltaMB (snapLive cur) (snapLive prev))
          <> padL 14 (showDeltaMB (snapLarge cur) (snapLarge prev))
          <> padL 14 (perClient cur)
    showMB w = show (w `div` (1024 * 1024))
    showDeltaMB a b
      | a >= b = "+" <> show ((a - b) `div` (1024 * 1024))
      | otherwise = "-" <> show ((b - a) `div` (1024 * 1024))
    perClient Snapshot {snapClients, snapLive}
      | snapClients > 0 = show (snapLive `div` fromIntegral snapClients `div` 1024)
      | otherwise = "-"
    padR n s = s <> replicate (max 0 (n - length s)) ' '
    padL n s = replicate (max 0 (n - length s)) ' ' <> s

csvHeader :: Text
csvHeader = "timestamp,phase,rts_live,rts_heap,rts_large,rts_frag,rts_gc,clients"

snapshotCsv :: Snapshot -> Text
snapshotCsv Snapshot {snapTime, snapPhase, snapLive, snapHeap, snapLarge, snapFrag, snapGCs, snapClients} =
  T.intercalate
    ","
    [ T.pack $ iso8601Show snapTime,
      snapPhase,
      tshow snapLive,
      tshow snapHeap,
      tshow snapLarge,
      tshow snapFrag,
      tshow snapGCs,
      tshow snapClients
    ]

writeTimeSeriesHeader :: FilePath -> IO ()
writeTimeSeriesHeader path = T.writeFile path (csvHeader <> "\n")

appendTimeSeries :: FilePath -> Snapshot -> IO ()
appendTimeSeries path snap =
  withFile path AppendMode $ \h -> do
    hSetBuffering h LineBuffering
    T.hPutStrLn h $ snapshotCsv snap

tshow :: Show a => a -> Text
tshow = T.pack . show
