{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StrictData #-}

-- | Public-namespace resolver: TTL+FIFO cache, in-flight coalescing,
-- timeout-bounded RPC, and zero-owner → NotFound mapping.
module Simplex.Messaging.Server.Names.Resolver
  ( NamesConfig (..),
    RpcAuth (..),
    NamesEnv (..),
    EthCall,
    ResolveError (..),
    newNamesEnv,
    newNamesEnvWith,
    closeNamesEnv,
    resolveName,
  )
where

import Control.Concurrent.STM
import qualified Control.Exception as E
import Data.ByteString.Char8 (ByteString)
import qualified Data.HashPSQ as PSQ
import Data.IORef (IORef)
import Data.Text (Text)
import Data.Word (Word64)
import GHC.Clock (getMonotonicTimeNSec)
import Simplex.Messaging.Protocol (NameOwner, NameRecord, unNameOwner)
import Simplex.Messaging.Server.Names.Eth.RPC (EthRpcEnv, EthRpcError (..), RpcAuth (..), closeEthRpcEnv, ethCallReal, newEthRpcEnv)
import Simplex.Messaging.Server.Names.Eth.SNRC (decodeGetRecord, encodeGetRecord, namehash)
import Simplex.Messaging.Util (atomicModifyIORef'_)
import System.Timeout (timeout)

-- | Public-namespace resolver configuration.
data NamesConfig = NamesConfig
  { ethereumEndpoint :: Text,
    snrcAddress :: NameOwner,
    rpcAuth :: Maybe RpcAuth,
    cacheSeconds :: Int,
    cacheMaxEntries :: Int,
    cacheMaxBytes :: Int,
    rpcTimeoutMs :: Int,
    rpcMaxResponseBytes :: Int,
    rpcMaxConcurrency :: Int,
    dangerousColocation :: Bool
  }
  deriving (Show)

data ResolveError
  = NotFound
  | EthHttpErr
  | EthRpcErr {rpcCode :: Int, rpcMessage :: Text}
  | EthDecodeErr
  | TimedOut
  deriving (Eq, Show)

-- | Test seam: a function from (to, data) -> raw return bytes or error.
-- Production wires this to ethCallReal; tests substitute a stub.
type EthCall = ByteString -> ByteString -> IO (Either EthRpcError ByteString)

-- | Cache value bundles a NameRecord with its insertion-time byte cost
-- so eviction can keep total cache bytes under cacheMaxBytes.
data CacheEntry = CacheEntry
  { ceRecord :: NameRecord,
    ceBytes :: Int
  }

-- | Cache state: (PSQ keyed by LookupKey, priority = insert time in ns, total bytes).
-- PSQ minView returns lowest-priority element → FIFO eviction by insertion order.
type CacheState = (PSQ.HashPSQ ByteString Word64 CacheEntry, Int)

data NamesEnv = NamesEnv
  { config :: NamesConfig,
    ethCall :: EthCall,
    cache :: TVar CacheState,
    inflight :: TVar (PSQ.HashPSQ ByteString Word64 (TMVar (Either ResolveError NameRecord))),
    rpcEnv :: Maybe EthRpcEnv, -- Nothing for test stubs
    cacheHitsRef :: IORef Int, -- shared with ServerStats.rslvStats.rslvCacheHits
    cacheMissRef :: IORef Int -- shared with ServerStats.rslvStats.rslvCacheMiss
  }

-- | Allocate resolver with real HTTP transport.
-- `cacheHitsRef` and `cacheMissRef` are shared with ServerStats.rslvStats so
-- the periodic CSV / Prometheus exporter sees per-request cache outcomes.
newNamesEnv :: NamesConfig -> IORef Int -> IORef Int -> IO NamesEnv
newNamesEnv cfg cacheHitsRef cacheMissRef = do
  rpc <- newEthRpcEnv (ethereumEndpoint cfg) (rpcAuth cfg) (rpcMaxResponseBytes cfg) (rpcMaxConcurrency cfg)
  let call to dat = ethCallReal rpc to dat
  newNamesEnvWith cfg call (Just rpc) cacheHitsRef cacheMissRef

-- | Allocate resolver with an injected ethCall (test seam).
newNamesEnvWith :: NamesConfig -> EthCall -> Maybe EthRpcEnv -> IORef Int -> IORef Int -> IO NamesEnv
newNamesEnvWith config ethCall rpcEnv cacheHitsRef cacheMissRef = do
  cache <- newTVarIO (PSQ.empty, 0)
  inflight <- newTVarIO PSQ.empty
  pure NamesEnv {config, ethCall, cache, inflight, rpcEnv, cacheHitsRef, cacheMissRef}

closeNamesEnv :: NamesEnv -> IO ()
closeNamesEnv NamesEnv {rpcEnv} = maybe (pure ()) closeEthRpcEnv rpcEnv

-- | Resolve a lookup key. Coalesces concurrent identical requests, caches
-- results for cacheSeconds, and bounds RPCs by rpcTimeoutMs.
resolveName :: NamesEnv -> ByteString -> IO (Either ResolveError NameRecord)
resolveName env key = do
  now <- getMonotonicTimeNSec
  cacheLookup env key now >>= \case
    Just rec -> do
      atomicModifyIORef'_ (cacheHitsRef env) (+ 1)
      pure (Right rec)
    Nothing -> do
      atomicModifyIORef'_ (cacheMissRef env) (+ 1)
      coalesce env key now

cacheLookup :: NamesEnv -> ByteString -> Word64 -> IO (Maybe NameRecord)
cacheLookup NamesEnv {config, cache} key now = atomically $ do
  (psq, totalBytes) <- readTVar cache
  case PSQ.lookup key psq of
    Just (insertedAt, ce)
      | now < insertedAt + ttlNs config -> pure (Just (ceRecord ce))
      | otherwise -> do
          -- Expired: evict and signal miss.
          writeTVar cache (PSQ.delete key psq, totalBytes - ceBytes ce)
          pure Nothing
    Nothing -> pure Nothing

ttlNs :: NamesConfig -> Word64
ttlNs cfg = fromIntegral (cacheSeconds cfg) * 1000000000

-- | Leader/waiter coalescing. Leader runs the RPC under E.mask; waiters
-- block on the leader's TMVar. Cleanup runs even on async exception.
coalesce :: NamesEnv -> ByteString -> Word64 -> IO (Either ResolveError NameRecord)
coalesce env@NamesEnv {inflight} key now = do
  ticket <- atomically $ do
    flight <- readTVar inflight
    case PSQ.lookup key flight of
      Just (_, mv) -> pure (Right mv)
      Nothing -> do
        mv <- newEmptyTMVar
        writeTVar inflight (PSQ.insert key now mv flight)
        pure (Left mv)
  case ticket of
    Right mv -> atomically (readTMVar mv) -- waiter
    Left mv -> E.mask $ \restore -> do
      r <-
        restore (fetchOnceTimed env key)
          `E.catch` \(e :: E.SomeException) -> pure (Left (mapEthExn e))
      atomically $ do
        putTMVar mv r
        modifyTVar' inflight (PSQ.delete key)
      case r of
        Right rec -> cacheInsert env key now rec
        Left _ -> pure ()
      pure r

mapEthExn :: E.SomeException -> ResolveError
mapEthExn _ = EthHttpErr

fetchOnceTimed :: NamesEnv -> ByteString -> IO (Either ResolveError NameRecord)
fetchOnceTimed env key =
  timeout (rpcTimeoutMs (config env) * 1000) (fetchOnce env key) >>= \case
    Just r -> pure r
    Nothing -> pure (Left TimedOut)

fetchOnce :: NamesEnv -> ByteString -> IO (Either ResolveError NameRecord)
fetchOnce env@NamesEnv {ethCall, config} key = do
  let node = namehash key
      callData = encodeGetRecord node
      to = unNameOwner (snrcAddress config)
  ethCall to callData >>= \case
    Left (HttpFailure _) -> pure (Left EthHttpErr)
    Left (HttpStatusErr _) -> pure (Left EthHttpErr)
    Left BodyTooLarge -> pure (Left EthDecodeErr)
    Left (InvalidJson _) -> pure (Left EthDecodeErr)
    Left (JsonRpcErr c m) -> pure (Left EthRpcErr {rpcCode = c, rpcMessage = m})
    Right ret -> case decodeGetRecord ret of
      Right Nothing -> pure (Left NotFound)
      Right (Just rec) -> pure (Right rec)
      Left _ -> pure (Left EthDecodeErr)

cacheInsert :: NamesEnv -> ByteString -> Word64 -> NameRecord -> IO ()
cacheInsert NamesEnv {config, cache} key now rec = atomically $ do
  (psq, totalBytes) <- readTVar cache
  let entryBytes = estimateBytes rec
      (psq', totalBytes') = evictWhile psq totalBytes
      evictWhile p tb
        | PSQ.size p > cacheMaxEntries config || tb + entryBytes > cacheMaxBytes config =
            case PSQ.minView p of
              Just (_, _, ce, rest) -> evictWhile rest (tb - ceBytes ce)
              Nothing -> (p, tb)
        | otherwise = (p, tb)
      ce = CacheEntry {ceRecord = rec, ceBytes = entryBytes}
  writeTVar cache (PSQ.insert key now ce psq', totalBytes' + entryBytes)

-- | Approximate byte cost of a cached NameRecord (overhead + content).
-- Tight enough that cacheMaxBytes bounds real memory; not byte-exact.
estimateBytes :: NameRecord -> Int
estimateBytes _ = 4096 -- conservative upper bound per NameRecord
