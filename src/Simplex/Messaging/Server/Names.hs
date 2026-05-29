{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StrictData #-}

-- | Public-namespace resolver. Each RSLV becomes one eth_call to the
-- Ethereum endpoint with the contract address selected by the requested
-- TLD, bounded by rpcMaxConcurrency and rpcTimeoutMs. Zero-owner / expired
-- records map to NotFound.
--
-- Transport details live in Names.Eth.RPC (HTTP + JSON-RPC + auth);
-- Keccak-256 namehash and SNRC ABI decoder live in Names.Eth.SNRC.
module Simplex.Messaging.Server.Names
  ( NamesConfig (..),
    TldRegistries (..),
    RpcAuth (..),
    NamesEnv (..),
    EthCall,
    ResolveError (..),
    newNamesEnv,
    newNamesEnvWith,
    closeNamesEnv,
    lookupTldAddress,
    pingEndpoint,
    resolveName,
    verifyRslv,
  )
where

import Control.Applicative ((<|>))
import Control.Monad (guard, unless, when)
import qualified Control.Exception as E
import Control.Logger.Simple (logError)
import Data.ByteString.Char8 (ByteString)
import Data.IORef (IORef, atomicModifyIORef', newIORef)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (encodeUtf8)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Simplex.Messaging.Encoding.String (strDecode)
import Simplex.Messaging.Protocol (NameOwner, NameRecord (..), RslvRequest (..), unNameOwner)
import Simplex.Messaging.Server.Names.Eth.RPC (EthRpcEnv, EthRpcError (..), RpcAuth (..), closeEthRpcEnv, ethCallReal, newEthRpcEnv)
import Simplex.Messaging.Server.Names.Eth.SNRC (decodeAddress, decodeGetRecord, encodeGetRecord, isZeroOwner, namehash)
import Simplex.Messaging.SimplexName (SimplexNameDomain (..), SimplexTLD (..), fullDomainName)
import System.Timeout (timeout)

-- | TLD-keyed SNRC contract whitelist. Each RSLV carries the contract
-- address the client wants queried; the server only accepts it if it
-- matches the address configured for that TLD (or `tldAll` as catch-all).
-- This lets one names router host multiple TLDs (each backed by its own
-- SNRC contract) and reject clients pointing at a contract the operator
-- doesn't run.
data TldRegistries = TldRegistries
  { tldSimplex :: Maybe NameOwner,
    tldTesting :: Maybe NameOwner,
    tldAll :: Maybe NameOwner
  }
  deriving (Show)

data NamesConfig = NamesConfig
  { ethereumEndpoint :: Text,
    tldRegistries :: TldRegistries,
    rpcAuth :: Maybe RpcAuth,
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

data NamesEnv = NamesEnv
  { config :: NamesConfig,
    ethCall :: EthCall,
    rpcEnv :: Maybe EthRpcEnv, -- Nothing for test stubs
    -- One-shot guard so the placeholder-decoder warning logs once per process,
    -- not once per RSLV.
    placeholderWarned :: IORef Bool
  }

newNamesEnv :: NamesConfig -> IO NamesEnv
newNamesEnv cfg = do
  rpc <- newEthRpcEnv (ethereumEndpoint cfg) (rpcAuth cfg) (rpcMaxResponseBytes cfg) (rpcMaxConcurrency cfg)
  newNamesEnvWith cfg (ethCallReal rpc) (Just rpc)

-- | Allocate resolver with an injected ethCall (test seam).
newNamesEnvWith :: NamesConfig -> EthCall -> Maybe EthRpcEnv -> IO NamesEnv
newNamesEnvWith config ethCall rpcEnv = do
  placeholderWarned <- newIORef False
  pure NamesEnv {config, ethCall, rpcEnv, placeholderWarned}

closeNamesEnv :: NamesEnv -> IO ()
closeNamesEnv NamesEnv {rpcEnv} = mapM_ closeEthRpcEnv rpcEnv

-- | Look up the expected SNRC contract address for a TLD. TLD-specific
-- entry takes precedence; `tldAll` is the catch-all. `TLDWeb` has no
-- TLD-specific entry — it always resolves through `tldAll` if set.
lookupTldAddress :: TldRegistries -> SimplexTLD -> Maybe NameOwner
lookupTldAddress TldRegistries {tldSimplex, tldTesting, tldAll} = \case
  TLDSimplex -> tldSimplex <|> tldAll
  TLDTesting -> tldTesting <|> tldAll
  TLDWeb -> tldAll

-- | Parse the client-supplied domain, look up the TLD's expected contract,
-- and verify the client-supplied contract matches. Returns the verified
-- (address, parsed-domain) pair, or `Nothing` if any check fails — the
-- handler maps this to `ERR AUTH` and increments `rslvBadName`.
verifyRslv :: NamesEnv -> RslvRequest -> Maybe (NameOwner, SimplexNameDomain)
verifyRslv NamesEnv {config} RslvRequest {name, contract} = case strDecode (encodeUtf8 name) of
  Left _ -> Nothing
  Right d -> do
    expected <- lookupTldAddress (tldRegistries config) (nameTLD d)
    guard (expected == contract)
    pure (expected, d)

-- | Reach the configured endpoint with a harmless probe call to confirm
-- network reachability. Uses any configured contract address (the parser
-- guarantees at least one is set). Returns Left only on transport-level
-- failures; JSON-RPC errors (misconfigured address etc.) are treated as
-- "endpoint reachable" — that distinction surfaces later via rslvEthErrs.
pingEndpoint :: NamesEnv -> IO (Either EthRpcError ())
pingEndpoint NamesEnv {ethCall, config} = case anyAddress (tldRegistries config) of
  Nothing -> pure (Right ())
  Just addr ->
    ethCall (unNameOwner addr) (encodeGetRecord (namehash "")) >>= \case
      Left e@(HttpFailure _) -> pure (Left e)
      Left e@(HttpStatusErr _) -> pure (Left e)
      _ -> pure (Right ())
  where
    anyAddress TldRegistries {tldSimplex, tldTesting, tldAll} =
      tldSimplex <|> tldTesting <|> tldAll

-- | Resolve a verified (contract, domain) pair with an rpcTimeoutMs
-- ceiling. Synchronous exceptions are caught and logged; async exceptions
-- propagate.
resolveName :: NamesEnv -> NameOwner -> SimplexNameDomain -> IO (Either ResolveError NameRecord)
resolveName env contract d = do
  r <- E.try (timeout (rpcTimeoutMs (config env) * 1000) (fetch env contract d))
  case r of
    Right result -> pure (fromMaybe (Left TimedOut) result)
    Left e
      | Just (_ :: E.SomeAsyncException) <- E.fromException e -> E.throwIO e
      | otherwise -> do
          logError $ "[NAMES] resolver fetch raised " <> T.pack (E.displayException e)
          pure (Left EthHttpErr)

fetch :: NamesEnv -> NameOwner -> SimplexNameDomain -> IO (Either ResolveError NameRecord)
fetch env@NamesEnv {ethCall} contract d =
  ethCall (unNameOwner contract) (encodeGetRecord (namehash (encodeUtf8 (fullDomainName d)))) >>= \case
    Left e -> pure (Left (mapEthRpcError e))
    Right ret -> case decodeGetRecord ret of
      Right Nothing -> notFoundWithPlaceholderWarn ret
      Right (Just rec) -> checkExpiry rec
      Left _ -> pure (Left EthDecodeErr)
  where
    -- decodeGetRecord is currently a placeholder: it returns Right Nothing
    -- for BOTH "zero-owner sentinel" (real NotFound) and "non-zero owner
    -- with real data but no ABI decoder yet". Inspect the owner slot
    -- directly to distinguish, and surface the latter once per process so
    -- an operator who enables [NAMES] against a working SNRC contract sees
    -- the resolver is functionally stubbed.
    notFoundWithPlaceholderWarn ret = do
      case decodeAddress 32 ret of
        Right owner -> unless (isZeroOwner owner) (warnPlaceholderOnce env)
        Left _ -> pure ()
      pure (Left NotFound)
    -- Defense in depth: the SNRC contract should already return the
    -- zero-owner sentinel for expired records, but a buggy / pre-upgrade
    -- contract might not. nrExpiry == 0 means "never expires" (reserved
    -- names); any positive expiry in the past is treated as NotFound.
    checkExpiry rec = do
      nowSec <- floor <$> getPOSIXTime
      pure $
        if nrExpiry rec /= 0 && nrExpiry rec < nowSec
          then Left NotFound
          else Right rec

warnPlaceholderOnce :: NamesEnv -> IO ()
warnPlaceholderOnce NamesEnv {placeholderWarned} = do
  first <- atomicModifyIORef' placeholderWarned (\w -> (True, not w))
  when first $
    logError
      "[NAMES] decodeGetRecord placeholder hit — SNRC ABI codec not finalised; \
      \every non-zero-owner record returns NotFound until the decoder ships"

-- | Collapse the JSON-RPC transport-layer error space into the resolver's
-- public error space.
mapEthRpcError :: EthRpcError -> ResolveError
mapEthRpcError = \case
  HttpFailure _ -> EthHttpErr
  HttpStatusErr _ -> EthHttpErr
  BodyTooLarge -> EthDecodeErr
  InvalidJson _ -> EthDecodeErr
  JsonRpcErr c m -> EthRpcErr {rpcCode = c, rpcMessage = m}
