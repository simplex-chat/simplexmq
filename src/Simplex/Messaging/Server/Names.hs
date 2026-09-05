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
    nameAvailability,
    resolveName,
  )
where

import qualified Control.Exception as E
import Control.Logger.Simple (logError)
import Data.Bifunctor (bimap, first)
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

-- | Whether a name can be registered. Same timeout and failure handling as
-- 'resolveName', which is the other question this server asks the resolver.
nameAvailability :: NamesEnv -> SimplexDomain -> IO (Either NameErrorType NameAvailability)
nameAvailability env d = do
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
  bimap mapResolverError mapAvailability <$> availabilityHttp resolverEnv (fullDomainName d)

-- | The resolver's own vocabulary. A lapsed registration past its grace period
-- is available again; one still in grace belongs to its previous owner; one in
-- the auction that follows grace is registrable, but not at the usual price. A
-- status whose payload is missing is reported as taken - refusing a name the
-- user could have had is a smaller harm than quoting the wrong price for it.
mapAvailability :: NameStatusResp -> NameAvailability
mapAvailability NameStatusResp {nsStatus, nsExpires, nsGraceEnds, nsAuctionEnds, nsPremium, nsReasonCode} = case nsStatus of
  "unregistered" -> NAVailable
  "expired" -> NAVailable
  "grace" -> maybe taken NAInGrace nsGraceEnds
  "auction" -> fromMaybe taken (NAAuction <$> nsPremium <*> nsAuctionEnds)
  "reserved" -> NAReserved (maybe NRUnspecified mapReason nsReasonCode)
  _ -> taken
  where
    taken = NATaken nsExpires

-- | The controller's reservation reasons, as the resolver spells them.
mapReason :: Text -> NameReservedReason
mapReason = \case
  "trademark" -> NRTrademark
  "publicInterest" -> NRPublicInterest
  "offensive" -> NROffensive
  "internal" -> NRInternal
  "premium" -> NRPremium
  _ -> NRUnspecified

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
