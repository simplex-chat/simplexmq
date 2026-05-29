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
    pingEndpoint,
    resolveName,
  )
where

import Control.Concurrent.STM
import qualified Control.Exception as E
import Control.Logger.Simple (logError)
import Data.ByteString.Char8 (ByteString)
import qualified Data.HashPSQ as PSQ
import Data.IORef (IORef)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Word (Word64)
import Data.Time.Clock.POSIX (getPOSIXTime)
import GHC.Clock (getMonotonicTimeNSec)
import qualified Data.ByteString.Char8 as B
import qualified Data.Text.Encoding as T
import Simplex.Messaging.Protocol (NameLink, NameOwner, NameRecord (..), unNameLink, unNameOwner)
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
    rpcMaxConcurrency :: Int
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

-- | Cache value bundles a result (NameRecord or NotFound sentinel) with
-- its insertion-time byte cost and per-entry TTL (NotFound expires faster
-- than positive results so newly-registered names become visible quickly
-- while still preventing DoS via unique-name spam).
data CacheEntry = CacheEntry
  { ceResult :: Maybe NameRecord, -- Nothing = NotFound; Just = Found
    ceBytes :: Int,
    ceTtlNs :: Word64
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

-- | Reach the configured endpoint with a harmless probe call to confirm
-- network reachability and basic config sanity. Returns Left only on
-- transport-level failures (DNS, TLS, refused) — a JSON-RPC error (e.g.
-- a misconfigured snrc_address) is treated as "endpoint reachable",
-- because the operator-friendly signal we want is "is the eth host alive,
-- not is your contract address right." That distinction surfaces later
-- via the rslvEthErrs counter.
pingEndpoint :: NamesEnv -> IO (Either EthRpcError ())
pingEndpoint NamesEnv {ethCall, config} = do
  let to = unNameOwner (snrcAddress config)
      -- Use the ENS-style root node (32 zero bytes) — always a valid
      -- bytes32 input that costs the contract nothing to look up.
      callData = encodeGetRecord (namehash "")
  ethCall to callData >>= \case
    Left e@(HttpFailure _) -> pure (Left e)
    Left e@(HttpStatusErr _) -> pure (Left e)
    _ -> pure (Right ())

-- | Resolve a lookup key. Coalesces concurrent identical requests, caches
-- results for cacheSeconds, and bounds RPCs by rpcTimeoutMs.
resolveName :: NamesEnv -> ByteString -> IO (Either ResolveError NameRecord)
resolveName env key = do
  now <- getMonotonicTimeNSec
  cacheLookup env key now >>= \case
    Just result -> do
      atomicModifyIORef'_ (cacheHitsRef env) (+ 1)
      pure $ maybe (Left NotFound) Right result
    Nothing -> do
      atomicModifyIORef'_ (cacheMissRef env) (+ 1)
      coalesce env key now

-- | Look up the key in cache. Returns:
--   Nothing                 — cache miss (or expired entry, which is evicted)
--   Just Nothing            — cache hit for NotFound
--   Just (Just rec)         — cache hit for a NameRecord
cacheLookup :: NamesEnv -> ByteString -> Word64 -> IO (Maybe (Maybe NameRecord))
cacheLookup NamesEnv {cache} key now = atomically $ do
  (psq, totalBytes) <- readTVar cache
  case PSQ.lookup key psq of
    Just (insertedAt, ce)
      | now < insertedAt + ceTtlNs ce -> pure (Just (ceResult ce))
      | otherwise -> do
          -- Expired: evict and signal miss.
          writeTVar cache (PSQ.delete key psq, totalBytes - ceBytes ce)
          pure Nothing
    Nothing -> pure Nothing

ttlFoundNs :: NamesConfig -> Word64
ttlFoundNs cfg = fromIntegral (cacheSeconds cfg) * 1000000000

-- | NotFound cache TTL — short enough that a newly-registered name becomes
-- visible within seconds, long enough to absorb a unique-name DoS burst.
-- Bounded by cacheSeconds in case the operator deliberately ran a tiny TTL.
ttlNotFoundNs :: NamesConfig -> Word64
ttlNotFoundNs cfg = min (ttlFoundNs cfg) (30 * 1000000000)

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
      -- Run the fetch with sync-only catching: async exceptions (cancel,
      -- killThread) must propagate after we've completed the STM cleanup
      -- so waiters never block on an orphan TMVar.
      r <-
        E.try (restore (fetchOnceTimed env key)) >>= \case
          Right ok -> pure ok
          Left e
            | Just (_ :: E.SomeAsyncException) <- E.fromException e -> do
                -- Tell waiters the lookup failed, then rethrow.
                atomically $ do
                  putTMVar mv (Left EthHttpErr)
                  modifyTVar' inflight (PSQ.delete key)
                E.throwIO e
            | otherwise -> do
                logError $ "[NAMES] resolver fetch raised " <> T.pack (E.displayException e)
                pure (Left EthHttpErr)
      atomically $ do
        putTMVar mv r
        modifyTVar' inflight (PSQ.delete key)
      case r of
        Right rec -> cacheInsert env key now (Just rec) (ttlFoundNs (config env))
        Left NotFound -> cacheInsert env key now Nothing (ttlNotFoundNs (config env))
        Left _ -> pure () -- transient errors (HTTP, decode, timeout) are not cached
      pure r

fetchOnceTimed :: NamesEnv -> ByteString -> IO (Either ResolveError NameRecord)
fetchOnceTimed env key =
  timeout (rpcTimeoutMs (config env) * 1000) (fetchOnce env key) >>= \case
    Just r -> pure r
    Nothing -> pure (Left TimedOut)

fetchOnce :: NamesEnv -> ByteString -> IO (Either ResolveError NameRecord)
fetchOnce NamesEnv {ethCall, config} key =
  ethCall (unNameOwner (snrcAddress config)) (encodeGetRecord (namehash key)) >>= \case
    Left e -> pure (Left (mapEthRpcError e))
    Right ret -> case decodeGetRecord ret of
      Right Nothing -> pure (Left NotFound)
      Right (Just rec) -> checkExpiry rec
      Left _ -> pure (Left EthDecodeErr)
  where
    -- Defense in depth: the SNRC contract should already return the
    -- zero-owner sentinel for expired records, but a buggy / pre-upgrade
    -- contract might not. nrExpiry == 0 means "never expires" (reserved
    -- names); any positive expiry in the past is treated as NotFound.
    checkExpiry rec = do
      nowSec <- floor <$> getPOSIXTime
      pure $ if nrExpiry rec /= 0 && nrExpiry rec < nowSec
        then Left NotFound
        else Right rec

-- | Collapse the JSON-RPC transport-layer error space into the resolver's
-- public error space. Reused by fetchOnce and pingEndpoint.
mapEthRpcError :: EthRpcError -> ResolveError
mapEthRpcError = \case
  HttpFailure _ -> EthHttpErr
  HttpStatusErr _ -> EthHttpErr
  BodyTooLarge -> EthDecodeErr
  InvalidJson _ -> EthDecodeErr
  JsonRpcErr c m -> EthRpcErr {rpcCode = c, rpcMessage = m}

cacheInsert :: NamesEnv -> ByteString -> Word64 -> Maybe NameRecord -> Word64 -> IO ()
cacheInsert NamesEnv {config, cache} key now result ttl = atomically $ do
  (psq, totalBytes) <- readTVar cache
  let entryBytes = maybe notFoundOverhead estimateBytes result
      (psq', totalBytes') = evictWhile psq totalBytes
      evictWhile p tb
        | PSQ.size p > cacheMaxEntries config || tb + entryBytes > cacheMaxBytes config =
            case PSQ.minView p of
              Just (_, _, ce, rest) -> evictWhile rest (tb - ceBytes ce)
              Nothing -> (p, tb)
        | otherwise = (p, tb)
      ce = CacheEntry {ceResult = result, ceBytes = entryBytes, ceTtlNs = ttl}
  writeTVar cache (PSQ.insert key now ce psq', totalBytes' + entryBytes)
  where
    notFoundOverhead = 128 -- PSQ node + key copy + small constant for the Nothing sentinel

-- | Approximate byte cost of a cached NameRecord. Counts the user-controlled
-- variable-length content plus a fixed per-entry overhead for the wrapper
-- (TVar/PSQ node + ByteString headers + IORef). Tighter than a constant upper
-- bound so cacheMaxBytes is a meaningful cap.
estimateBytes :: NameRecord -> Int
estimateBytes NameRecord {nrDisplayName, nrChannelLinks, nrContactLinks, nrAdminAddress, nrAdminEmail} =
  perEntryOverhead
    + utf8Len nrDisplayName
    + 20 -- nrOwner
    + sum (map nameLinkBytes nrChannelLinks)
    + sum (map nameLinkBytes nrContactLinks)
    + maybe 0 utf8Len nrAdminAddress
    + maybe 0 utf8Len nrAdminEmail
  where
    perEntryOverhead = 256 -- PSQ node + key copy + ByteString headers
    utf8Len = B.length . T.encodeUtf8
    nameLinkBytes :: NameLink -> Int
    nameLinkBytes = utf8Len . unNameLink
