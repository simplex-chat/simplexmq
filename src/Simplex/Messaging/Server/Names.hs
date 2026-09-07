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
    resolveName,
  )
where

import qualified Control.Exception as E
import Control.Logger.Simple (logError)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Simplex.Messaging.Protocol (NameErrorType (..), NameRecord, NameReservedReason (..), NameResponse (..))
import Simplex.Messaging.Server.Names.HttpResolver
  ( NameStatusResp (..),
    ResolverEnv,
    ResolverError (..),
    RpcAuth (..),
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

resolveName :: NamesEnv -> SimplexDomain -> IO (Either NameErrorType NameResponse)
resolveName env d = do
  r <- E.try (timeout (resolverTimeoutMs (config env) * 1000) (fetch env d))
  case r of
    Right result -> pure (fromMaybe (Left (RESOLVER "timeout")) result)
    Left e
      | Just (_ :: E.SomeAsyncException) <- E.fromException e -> E.throwIO e
      | otherwise -> do
          logError $ "[NAMES] resolver fetch raised " <> T.pack (E.displayException e)
          pure (Left (RESOLVER "resolver error"))

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

fetch :: NamesEnv -> SimplexDomain -> IO (Either NameErrorType NameResponse)
fetch NamesEnv {resolverEnv} d =
  either (Left . mapResolverError) nameResponse <$> resolveHttp resolverEnv (fullDomainName d)

-- | A record answers on its own; the status only dates it. Without a record the
-- status is the whole answer, and a status this router has no word for is not
-- one - "taken" would assert a registration nobody read.
nameResponse :: (Maybe NameRecord, Maybe NameStatusResp) -> Either NameErrorType NameResponse
nameResponse = \case
  (Just nameRecord, ns_) -> Right NRNameRecord {nameRecord, expires = nsExpires =<< ns_}
  (Nothing, Just ns) -> mapStatus ns
  (Nothing, Nothing) -> Left NOT_FOUND

-- | The resolver's vocabulary for a name that does not resolve.
mapStatus :: NameStatusResp -> Either NameErrorType NameResponse
mapStatus NameStatusResp {nsStatus, nsExpires, nsGraceEnds, nsAuctionEnds, nsPremium, nsReasonCode} =
  case nsStatus of
    "unregistered" -> Right NRNameAvailable
    "expired" -> Right NRNameAvailable
    "grace" -> Right $ maybe lapsed NRNameInGrace nsGraceEnds
    "auction" -> Right $ fromMaybe lapsed (NRNameAuction <$> nsPremium <*> nsAuctionEnds)
    "reserved" -> Right $ NRNameReserved (maybe NRUnknown mapReason nsReasonCode)
    -- registered, but its records point nowhere
    "noResolver" -> Right $ NRNameTaken nsExpires
    -- the resolver's own words, bounded: they reach the client inside ERR
    s -> Left (RESOLVER (T.take 32 s))
  where
    -- lapsed, but missing the deadline or price its status carries. Withhold it
    -- rather than quote the ordinary price; its expiry is already past.
    lapsed = NRNameTaken Nothing

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
