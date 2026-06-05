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
    RpcAuth (..),
    NamesEnv (..),
    EthCall,
    ResolveError (..),
    newNamesEnv,
    newNamesEnvWith,
    closeNamesEnv,
    pingEndpoint,
    resolveName,
    verifyRslv,
  )
where

import Control.Monad (guard)
import qualified Control.Exception as E
import Control.Logger.Simple (logError)
import Data.ByteString.Char8 (ByteString)
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (encodeUtf8)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Simplex.Messaging.Encoding.String (strDecode)
import Simplex.Messaging.Protocol (NameOwner, NameRecord, RslvRequest (..), unNameOwner)
import Simplex.Messaging.Server.Names.Eth.RPC (EthRpcEnv, EthRpcError (..), RpcAuth (..), closeEthRpcEnv, ethCallReal, newEthRpcEnv)
import Simplex.Messaging.Server.Names.Eth.SNRC (decodeGetRecord, encodeGetRecord, namehash)
import Simplex.Messaging.SimplexName (SimplexNameDomain (..), SimplexTLD (..), fullDomainName)
import Simplex.Messaging.SimplexName.Contracts (tldContract)
import System.Timeout (timeout)

data NamesConfig = NamesConfig
  { ethereumEndpoint :: Text,
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
    rpcEnv :: Maybe EthRpcEnv -- Nothing for test stubs
  }

newNamesEnv :: NamesConfig -> IO NamesEnv
newNamesEnv cfg = do
  rpc <- newEthRpcEnv (ethereumEndpoint cfg) (rpcAuth cfg) (rpcMaxResponseBytes cfg) (rpcMaxConcurrency cfg)
  newNamesEnvWith cfg (ethCallReal rpc) (Just rpc)

-- | Allocate resolver with an injected ethCall (test seam).
newNamesEnvWith :: NamesConfig -> EthCall -> Maybe EthRpcEnv -> IO NamesEnv
newNamesEnvWith config ethCall rpcEnv = pure NamesEnv {config, ethCall, rpcEnv}

closeNamesEnv :: NamesEnv -> IO ()
closeNamesEnv NamesEnv {rpcEnv} = mapM_ closeEthRpcEnv rpcEnv

-- | Parse the client-supplied domain, look up the TLD's expected contract,
-- and verify the client-supplied contract matches. Returns the verified
-- (address, parsed-domain) pair, or `Nothing` if any check fails — the
-- handler maps this to `ERR AUTH` and increments `rslvBadName`.
verifyRslv :: NamesEnv -> RslvRequest -> Maybe (NameOwner, SimplexNameDomain)
verifyRslv _ RslvRequest {name, contract} = case strDecode (encodeUtf8 name) of
  Left _ -> Nothing
  Right d -> do
    expected <- tldContract (nameTLD d)
    guard (expected == contract)
    pure (expected, d)

-- | Reach the configured endpoint with a harmless probe call to confirm
-- network reachability. Uses any configured contract address (the static
-- TLD->contract mapping guarantees at least one is set; TLDWeb has none by
-- design). A JSON-RPC error (e.g. unknown contract on a healthy node) is
-- treated as "endpoint reachable". HTTP transport failures, oversized
-- responses, and non-JSON bodies (operator pointing at the wrong service)
-- all surface as Left so startup fails loudly rather than every RSLV
-- silently incrementing rslvEthErrs.
pingEndpoint :: NamesEnv -> IO (Either EthRpcError ())
pingEndpoint NamesEnv {ethCall, config} = case mapMaybe tldContract [TLDSimplex, TLDTesting] of
  [] -> pure (Right ())
  addr : _ -> do
    -- Bound the probe by the same rpcTimeoutMs that resolveName uses, so a
    -- slow-loris endpoint can't park startup until http-client's default
    -- 30 s response timeout fires.
    r <- timeout (rpcTimeoutMs config * 1000) $
      ethCall (unNameOwner addr) (encodeGetRecord (namehash ""))
    pure $ case r of
      Nothing -> Left ProbeTimedOut
      Just (Left JsonRpcErr {}) -> Right () -- node answered, just doesn't know this contract
      Just (Left e) -> Left e
      Just (Right _) -> Right ()

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
fetch NamesEnv {ethCall} contract d = do
  nowSec <- floor <$> getPOSIXTime
  ethCall (unNameOwner contract) (encodeGetRecord (namehash (encodeUtf8 (fullDomainName d)))) >>= \case
    Left e -> pure (Left (mapEthRpcError e))
    Right ret -> case decodeGetRecord contract nowSec ret of
      Right Nothing -> pure (Left NotFound)
      Right (Just rec) -> pure (Right rec)
      Left _ -> pure (Left EthDecodeErr)

-- | Collapse the JSON-RPC transport-layer error space into the resolver's
-- public error space.
mapEthRpcError :: EthRpcError -> ResolveError
mapEthRpcError = \case
  HttpFailure _ -> EthHttpErr
  HttpStatusErr _ -> EthHttpErr
  BodyTooLarge -> EthHttpErr -- transport-side cap, not a decoder failure
  InvalidJson _ -> EthDecodeErr
  JsonRpcErr c m -> EthRpcErr {rpcCode = c, rpcMessage = m}
  ProbeTimedOut -> EthHttpErr -- pingEndpoint-only; never raised by ethCallReal in the resolve path
