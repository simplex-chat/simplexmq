{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StrictData #-}

module Simplex.Messaging.Server.Names
  ( NamesConfig (..),
    RpcAuth (..),
    NamesEnv (..),
    newNamesEnv,
    closeNamesEnv,
    pingEndpoint,
    getNameAvailability,
    resolveName,
  )
where

import qualified Control.Exception as E
import Control.Logger.Simple (logError)
import Data.Bifunctor (first)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Simplex.Messaging.Protocol (NameAvailability (..), NameErrorType (..), NameRecord, NameReservedReason (..))
import Simplex.Messaging.Server.Names.HttpResolver
  ( NameStatusResp (..),
    ResolverEnv,
    ResolverError (..),
    RpcAuth (..),
    availabilityHttp,
    closeResolverEnv,
    healthHttp,
    newResolverEnv,
    resolveHttp,
  )
import Simplex.Messaging.SimplexName (SimplexDomain, fullDomainName)
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

pingEndpoint :: NamesEnv -> IO (Either ResolverError ())
pingEndpoint NamesEnv {resolverEnv, config} =
  fromMaybe (Left ResolverTimeout) <$> timeout (resolverTimeoutMs config * 1000) (healthHttp resolverEnv)

resolveName :: NamesEnv -> SimplexDomain -> IO (Either NameErrorType NameRecord)
resolveName env d = do
  r <- E.try (timeout (resolverTimeoutMs (config env) * 1000) (fetch env d))
  case r of
    Right result -> pure (fromMaybe (Left (RESOLVER "timeout")) result)
    Left e
      | Just (_ :: E.SomeAsyncException) <- E.fromException e -> E.throwIO e
      | otherwise -> do
          logError $ "[NAMES] resolver fetch raised " <> T.pack (E.displayException e)
          pure (Left (RESOLVER "resolver error"))

-- | Whether a name can be registered. Same timeout handling as 'resolveName'.
getNameAvailability :: NamesEnv -> SimplexDomain -> IO (Either NameErrorType NameAvailability)
getNameAvailability env d = do
  r <- E.try (timeout (resolverTimeoutMs (config env) * 1000) (fetchAvail env d))
  case r of
    Right result -> pure (fromMaybe (Left (RESOLVER "timeout")) result)
    Left e
      | Just (_ :: E.SomeAsyncException) <- E.fromException e -> E.throwIO e
      | otherwise -> do
          logError $ "[NAMES] resolver availability raised " <> T.pack (E.displayException e)
          pure (Left (RESOLVER "resolver error"))

fetchAvail :: NamesEnv -> SimplexDomain -> IO (Either NameErrorType NameAvailability)
fetchAvail NamesEnv {resolverEnv} d =
  either (Left . mapAvailError) mapAvailability <$> availabilityHttp resolverEnv (fullDomainName d)

-- | NAVL must not fail as NOT_FOUND: a client reads that as "no such name, so
-- it is free". 'mapResolverError' returns it for 404/410/400.
mapAvailError :: ResolverError -> NameErrorType
mapAvailError = \case
  HttpStatusErr code -> RESOLVER ("HTTP " <> T.pack (show code))
  e -> mapResolverError e

-- | The resolver's vocabulary. Only the statuses that describe the name are
-- answers; anything else means it could not answer, and "taken" would assert a
-- registration nobody read.
mapAvailability :: NameStatusResp -> Either NameErrorType NameAvailability
mapAvailability NameStatusResp {nsStatus, nsExpires, nsGraceEnds, nsAuctionEnds, nsPremium, nsReasonCode} =
  case nsStatus of
    "unregistered" -> Right NAVailable
    "expired" -> Right NAVailable
    "grace" -> Right $ maybe lapsed NAInGrace nsGraceEnds
    "auction" -> Right $ fromMaybe lapsed (NAAuction <$> nsPremium <*> nsAuctionEnds)
    "reserved" -> Right $ NAReserved (maybe NRUnknown mapReason nsReasonCode)
    "registered" -> Right $ NATaken nsExpires
    -- registered, but its records point nowhere
    "noResolver" -> Right $ NATaken nsExpires
    -- the resolver's own words, bounded: they reach the client inside ERR
    s -> Left (RESOLVER (T.take 32 s))
  where
    -- lapsed, but missing the deadline or price its status carries. Withhold it
    -- rather than quote the ordinary price; its expiry is already past.
    lapsed = NATaken Nothing

-- | The controller's reservation reasons, as the resolver spells them.
mapReason :: Text -> NameReservedReason
mapReason = \case
  "unspecified" -> NRUnspecified
  "trademark" -> NRTrademark
  "publicInterest" -> NRPublicInterest
  "offensive" -> NROffensive
  "internal" -> NRInternal
  "premium" -> NRPremium
  -- a code this router has no word for: still reserved, just unworded
  _ -> NRUnknown

fetch :: NamesEnv -> SimplexDomain -> IO (Either NameErrorType NameRecord)
fetch NamesEnv {resolverEnv} d =
  first mapResolverError <$> resolveHttp resolverEnv (fullDomainName d)

mapResolverError :: ResolverError -> NameErrorType
mapResolverError = \case
  HttpStatusErr 404 -> NOT_FOUND
  -- 410 is a lapsed registration: an answer about the name, not a resolver
  -- failure, so it must not become RESOLVER.
  HttpStatusErr 410 -> NOT_FOUND
  HttpStatusErr 400 -> NOT_FOUND
  HttpStatusErr code -> RESOLVER ("HTTP " <> T.pack (show code))
  HttpFailure _ -> RESOLVER "transport failure"
  BodyTooLarge -> RESOLVER "response too large"
  InvalidJson _ -> RESOLVER "invalid response"
  ResolverTimeout -> RESOLVER "timeout"
