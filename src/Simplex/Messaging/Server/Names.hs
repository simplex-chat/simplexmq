{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StrictData #-}

-- | Public-namespace resolver. Each RSLV becomes one eth_call to the
-- configured Ethereum endpoint, bounded by rpcMaxConcurrency and
-- rpcTimeoutMs. Zero-owner / expired records map to NotFound.
--
-- Transport details live in Names.Eth.RPC (HTTP + JSON-RPC + auth);
-- Keccak-256 namehash and SNRC ABI decoder live in Names.Eth.SNRC.
module Simplex.Messaging.Server.Names
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

import Control.Monad (when, unless)
import qualified Control.Exception as E
import Control.Logger.Simple (logError)
import Data.ByteString.Char8 (ByteString)
import Data.IORef (IORef, atomicModifyIORef', newIORef)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock.POSIX (getPOSIXTime)
import Simplex.Messaging.Protocol (NameOwner, NameRecord (..), unNameOwner)
import Simplex.Messaging.Server.Names.Eth.RPC (EthRpcEnv, EthRpcError (..), RpcAuth (..), closeEthRpcEnv, ethCallReal, newEthRpcEnv)
import Simplex.Messaging.Server.Names.Eth.SNRC (decodeAddress, decodeGetRecord, encodeGetRecord, isZeroOwner, namehash)
import System.Timeout (timeout)

data NamesConfig = NamesConfig
  { ethereumEndpoint :: Text,
    snrcAddress :: NameOwner,
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

-- | Reach the configured endpoint with a harmless probe call to confirm
-- network reachability. Returns Left only on transport-level failures;
-- JSON-RPC errors (misconfigured snrc_address etc.) are treated as
-- "endpoint reachable" — that distinction surfaces later via rslvEthErrs.
pingEndpoint :: NamesEnv -> IO (Either EthRpcError ())
pingEndpoint NamesEnv {ethCall, config} =
  ethCall (unNameOwner (snrcAddress config)) (encodeGetRecord (namehash "")) >>= \case
    Left e@(HttpFailure _) -> pure (Left e)
    Left e@(HttpStatusErr _) -> pure (Left e)
    _ -> pure (Right ())

-- | Resolve a lookup key with an rpcTimeoutMs ceiling. Synchronous
-- exceptions are caught and logged; async exceptions propagate.
resolveName :: NamesEnv -> ByteString -> IO (Either ResolveError NameRecord)
resolveName env key = do
  r <- E.try (timeout (rpcTimeoutMs (config env) * 1000) (fetch env key))
  case r of
    Right result -> pure (fromMaybe (Left TimedOut) result)
    Left e
      | Just (_ :: E.SomeAsyncException) <- E.fromException e -> E.throwIO e
      | otherwise -> do
          logError $ "[NAMES] resolver fetch raised " <> T.pack (E.displayException e)
          pure (Left EthHttpErr)

fetch :: NamesEnv -> ByteString -> IO (Either ResolveError NameRecord)
fetch env@NamesEnv {ethCall, config} key =
  ethCall (unNameOwner (snrcAddress config)) (encodeGetRecord (namehash key)) >>= \case
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
      pure $ if nrExpiry rec /= 0 && nrExpiry rec < nowSec
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
