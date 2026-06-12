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
    ResolverCall,
    ResolverCallKind (..),
    newNamesEnv,
    newNamesEnvWith,
    closeNamesEnv,
    pingEndpoint,
    resolveName,
  )
where

import qualified Control.Exception as E
import Control.Logger.Simple (logError)
import qualified Data.Aeson as J
import qualified Data.Aeson.Types as JT
import Data.Text (Text)
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
  { resolverEndpoint :: Text,
    resolverAuth :: Maybe RpcAuth,
    resolverTimeoutMs :: Int,
    resolverMaxResponseBytes :: Int
  }
  deriving (Show)

-- | Test seam: a function from URL path -> JSON value or error. Production
-- wires this to resolveHttp / healthHttp on a real `ResolverEnv`; tests
-- substitute a stub returning canned JSON or a chosen error.
--
-- The first argument is the HTTP endpoint to hit: `ResolverFetch` for a
-- name lookup, `ResolverHealth` for the startup probe. Tests use the tag
-- to assert which kind of call the server made.
data ResolverCallKind = ResolverFetch Text | ResolverHealth
  deriving (Eq, Show)

-- Re-export so test seams (which need to match on the kind) can use it
-- without depending on the HttpResolver module.

type ResolverCall = ResolverCallKind -> IO (Either ResolverError J.Value)

data NamesEnv = NamesEnv
  { config :: NamesConfig,
    resolverCall :: ResolverCall,
    resolverEnv :: Maybe ResolverEnv -- Nothing for test stubs
  }

newNamesEnv :: NamesConfig -> IO NamesEnv
newNamesEnv cfg = do
  rEnv <- newResolverEnv (resolverEndpoint cfg) (resolverAuth cfg) (resolverTimeoutMs cfg) (resolverMaxResponseBytes cfg)
  newNamesEnvWith cfg (httpResolverCall rEnv) (Just rEnv)

httpResolverCall :: ResolverEnv -> ResolverCall
httpResolverCall env = \case
  ResolverFetch n -> resolveHttp env n
  ResolverHealth -> healthHttp env

-- | Allocate resolver with an injected `resolverCall` (test seam).
newNamesEnvWith :: NamesConfig -> ResolverCall -> Maybe ResolverEnv -> IO NamesEnv
newNamesEnvWith config resolverCall resolverEnv = pure NamesEnv {config, resolverCall, resolverEnv}

closeNamesEnv :: NamesEnv -> IO ()
closeNamesEnv NamesEnv {resolverEnv} = mapM_ closeResolverEnv resolverEnv

-- | Reach the configured resolver with `GET /health` to confirm reachability
-- at server startup. A non-2xx response or transport failure surfaces as
-- Left so misconfigured deployments fail loudly. Bounded by
-- `resolverTimeoutMs` so a slow-loris endpoint cannot park startup until
-- http-client's default 30 s response timeout fires.
pingEndpoint :: NamesEnv -> IO (Either ResolverError ())
pingEndpoint NamesEnv {resolverCall, config} = do
  r <- timeout (resolverTimeoutMs config * 1000) $ resolverCall ResolverHealth
  pure $ case r of
    Nothing -> Left (HttpStatusErr 0) -- transport-level timeout (0 is not a real HTTP code)
    Just (Left e) -> Left e
    Just (Right _) -> Right ()

-- | Resolve a parsed domain via the configured HTTP resolver, with an
-- `resolverTimeoutMs` ceiling. Synchronous exceptions are caught and
-- logged; async exceptions propagate.
resolveName :: NamesEnv -> SimplexNameDomain -> IO (Either NameErrorType NameRecord)
resolveName env d = do
  r <- E.try (timeout (resolverTimeoutMs (config env) * 1000) (fetch env d))
  case r of
    Right result -> pure (maybe (Left (RESOLVER "timeout")) id result)
    Left e
      | Just (_ :: E.SomeAsyncException) <- E.fromException e -> E.throwIO e
      | otherwise -> do
          logError $ "[NAMES] resolver fetch raised " <> T.pack (E.displayException e)
          pure (Left (RESOLVER "resolver error"))

fetch :: NamesEnv -> SimplexNameDomain -> IO (Either NameErrorType NameRecord)
fetch NamesEnv {resolverCall} d =
  resolverCall (ResolverFetch (fullDomainName d)) >>= \case
    Left e -> pure (Left (mapResolverError e))
    Right v -> case JT.parseEither J.parseJSON v of
      Right nr -> pure (Right nr)
      Left _ -> pure (Left (RESOLVER "invalid response"))

-- | Map the HTTP-layer error space into the protocol NameErrorType. 404 / 400
-- both map to NO_NAME (name not registered, unknown TLD, or malformed name —
-- indistinguishable from the client's point of view). Everything else is a
-- backend failure surfaced as RESOLVER with a SAFE server-generated diagnostic
-- (kind only - the adversarial response body is never echoed).
mapResolverError :: ResolverError -> NameErrorType
mapResolverError = \case
  HttpStatusErr 404 -> NO_NAME
  HttpStatusErr 400 -> NO_NAME
  HttpStatusErr code -> RESOLVER ("HTTP " <> T.pack (show code))
  HttpFailure _ -> RESOLVER "transport failure"
  BodyTooLarge -> RESOLVER "response too large"
  InvalidJson _ -> RESOLVER "invalid response"
