{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StrictData #-}

-- | Public-namespace resolver. Each RSLV becomes one HTTP GET to the
-- configured names resolver service (the Python REST resolver in PR #1795
-- by default), bounded by resolverTimeoutMs and the maximum response size.
-- The resolver_endpoint URL is operator-supplied; the contract field on the
-- RSLV wire format is parsed for forward-compatibility but ignored — the
-- Python service is the source of truth for which on-chain registries are
-- queried per TLD.
--
-- HTTP details (URL building, redirects disabled, body cap, auth header)
-- live in Names.HttpResolver.
module Simplex.Messaging.Server.Names
  ( NamesConfig (..),
    RpcAuth (..),
    NamesEnv (..),
    ResolverCall,
    ResolverCallKind (..),
    ResolveError (..),
    newNamesEnv,
    newNamesEnvWith,
    closeNamesEnv,
    pingEndpoint,
    resolveName,
    parseName,
  )
where

import qualified Control.Exception as E
import Control.Logger.Simple (logError)
import qualified Data.Aeson as J
import qualified Data.Aeson.Types as JT
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (encodeUtf8)
import Simplex.Messaging.Encoding.String (strDecode)
import Simplex.Messaging.Protocol (NameRecord, RslvRequest (..))
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

data ResolveError
  = NotFound -- name not registered, unknown TLD, or malformed name (404 / 400)
  | ResolverError -- upstream RPC failure (502) or transport error
  | ResolverDecodeErr -- response was not a valid NameRecord JSON
  | TimedOut
  deriving (Eq, Show)

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

-- | Parse the client-supplied name. The wire-format `contract` field is
-- parsed by the protocol layer but ignored here: the resolver service
-- selects which registry to query based on the TLD. Returns the parsed
-- domain, or `Nothing` if the name is not a valid SimplexNameDomain (the
-- handler maps `Nothing` to `ERR AUTH` and increments `rslvBadName`).
parseName :: RslvRequest -> Maybe SimplexNameDomain
parseName RslvRequest {name} = either (const Nothing) Just $ strDecode (encodeUtf8 name)

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
resolveName :: NamesEnv -> SimplexNameDomain -> IO (Either ResolveError NameRecord)
resolveName env d = do
  r <- E.try (timeout (resolverTimeoutMs (config env) * 1000) (fetch env d))
  case r of
    Right result -> pure (maybe (Left TimedOut) id result)
    Left e
      | Just (_ :: E.SomeAsyncException) <- E.fromException e -> E.throwIO e
      | otherwise -> do
          logError $ "[NAMES] resolver fetch raised " <> T.pack (E.displayException e)
          pure (Left ResolverError)

fetch :: NamesEnv -> SimplexNameDomain -> IO (Either ResolveError NameRecord)
fetch NamesEnv {resolverCall} d =
  resolverCall (ResolverFetch (fullDomainName d)) >>= \case
    Left e -> pure (Left (mapResolverError e))
    Right v -> case JT.parseEither J.parseJSON v of
      Right nr -> pure (Right nr)
      Left _ -> pure (Left ResolverDecodeErr)

-- | Collapse the HTTP-layer error space into the resolver's public error
-- space. 404 / 400 both map to NotFound (name not registered, unknown TLD,
-- or malformed name — indistinguishable from the client's point of view).
-- Everything else collapses to ResolverError; the response body is not
-- inspected because adversarial endpoints could embed arbitrary content.
mapResolverError :: ResolverError -> ResolveError
mapResolverError = \case
  HttpStatusErr 404 -> NotFound
  HttpStatusErr 400 -> NotFound
  HttpStatusErr _ -> ResolverError
  HttpFailure _ -> ResolverError
  BodyTooLarge -> ResolverError
  InvalidJson _ -> ResolverDecodeErr
