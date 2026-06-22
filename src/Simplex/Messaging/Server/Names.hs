{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StrictData #-}

-- | Public-namespace resolver. Each RSLV becomes one HTTP GET to the
-- configured names resolver service (the Python REST resolver in PR #1795
-- by default), bounded by resolverTimeoutMs and the maximum response size.
-- The resolver_endpoint URL is operator-supplied; the resolver service is the
-- source of truth for which on-chain registries are queried per TLD.
--
-- Resolver outcomes map to the protocol's `NameErrorType` so failures reach the
-- client (as `ERR (NAME ...)` -> ChatErrorAgent) instead of being swallowed.
--
-- HTTP details (URL building, redirects disabled, body cap, auth header)
-- live in Names.HttpResolver.
module Simplex.Messaging.Server.Names
  ( NamesConfig (..),
    RpcAuth (..),
    NamesEnv (..),
    newNamesEnv,
    closeNamesEnv,
    pingEndpoint,
    resolveName,
  )
where

import qualified Control.Exception as E
import Control.Logger.Simple (logError)
import Data.Bifunctor (first)
import Data.Maybe (fromMaybe)
import qualified Data.Text as T
import Simplex.Messaging.Protocol (NameErrorType (..), NameRecord)
import Simplex.Messaging.Server.Names.HttpResolver
  ( ResolverEnv,
    ResolverError (..),
    RpcAuth (..),
    closeResolverEnv,
    healthHttp,
    newResolverEnv,
    resolveHttp,
  )
import Simplex.Messaging.SimplexName (SimplexNameDomain, fullDomainName)
import System.Timeout (timeout)

data NamesConfig = NamesConfig
  { resolverEndpoint :: String,
    resolverAuth :: Maybe RpcAuth,
    resolverTimeoutMs :: Int,
    resolverMaxResponseBytes :: Int
  }
  deriving (Show)

data NamesEnv = NamesEnv
  { config :: NamesConfig,
    resolverEnv :: ResolverEnv
  }

newNamesEnv :: NamesConfig -> IO NamesEnv
newNamesEnv config = do
  resolverEnv <- newResolverEnv (resolverEndpoint config) (resolverAuth config) (resolverTimeoutMs config) (resolverMaxResponseBytes config)
  pure NamesEnv {config, resolverEnv}

closeNamesEnv :: NamesEnv -> IO ()
closeNamesEnv NamesEnv {resolverEnv} = closeResolverEnv resolverEnv

-- | Reach the configured resolver with `GET /health` to confirm reachability
-- at server startup. A non-2xx response or transport failure surfaces as
-- Left so misconfigured deployments fail loudly. Bounded by
-- `resolverTimeoutMs` so a slow-loris endpoint cannot park startup until
-- http-client's default 30 s response timeout fires.
pingEndpoint :: NamesEnv -> IO (Either ResolverError ())
pingEndpoint NamesEnv {resolverEnv, config} =
  fromMaybe (Left ResolverTimeout) <$> timeout (resolverTimeoutMs config * 1000) (healthHttp resolverEnv)

-- | Resolve a parsed domain via the configured HTTP resolver, with an
-- `resolverTimeoutMs` ceiling. Synchronous exceptions are caught and
-- logged; async exceptions propagate.
resolveName :: NamesEnv -> SimplexNameDomain -> IO (Either NameErrorType NameRecord)
resolveName env d = do
  r <- E.try (timeout (resolverTimeoutMs (config env) * 1000) (fetch env d))
  case r of
    Right result -> pure (fromMaybe (Left (RESOLVER "timeout")) result)
    Left e
      | Just (_ :: E.SomeAsyncException) <- E.fromException e -> E.throwIO e
      | otherwise -> do
          logError $ "[NAMES] resolver fetch raised " <> T.pack (E.displayException e)
          pure (Left (RESOLVER "resolver error"))

fetch :: NamesEnv -> SimplexNameDomain -> IO (Either NameErrorType NameRecord)
fetch NamesEnv {resolverEnv} d =
  first mapResolverError <$> resolveHttp resolverEnv (fullDomainName d)

-- | Map the HTTP-layer error space into the protocol NameErrorType. 404 / 400
-- both map to NOT_FOUND (name not registered, unknown TLD, or malformed name —
-- indistinguishable from the client's point of view). Everything else is a
-- backend failure surfaced as RESOLVER with a SAFE server-generated diagnostic
-- (kind only - the adversarial response body is never echoed).
mapResolverError :: ResolverError -> NameErrorType
mapResolverError = \case
  HttpStatusErr 404 -> NOT_FOUND
  HttpStatusErr 400 -> NOT_FOUND
  HttpStatusErr code -> RESOLVER ("HTTP " <> T.pack (show code))
  HttpFailure _ -> RESOLVER "transport failure"
  BodyTooLarge -> RESOLVER "response too large"
  InvalidJson _ -> RESOLVER "invalid response"
  ResolverTimeout -> RESOLVER "timeout"
