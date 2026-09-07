{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StrictData #-}
{-# LANGUAGE TupleSections #-}

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
import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text)
import qualified Data.Text as T
import Simplex.Messaging.Protocol (NameErrorType (..), MicroUSD (..), NamePricing (..), NameRecord, NameRegistration (..), NameResult, NameReservedReason, reservedReason)
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

resolveName :: NamesEnv -> SimplexDomain -> IO (Either NameErrorType NameResult)
resolveName env d = do
  r <- E.try (timeout (resolverTimeoutMs (config env) * 1000) (fetch env d))
  case r of
    Right result -> pure (fromMaybe (Left (RESOLVER "timeout")) result)
    Left e
      | Just (_ :: E.SomeAsyncException) <- E.fromException e -> E.throwIO e
      | otherwise -> do
          logError $ "[NAMES] resolver fetch raised " <> T.pack (E.displayException e)
          pure (Left (RESOLVER "resolver error"))

-- | A code this router has no word for still reserves the name, and travels on
-- as itself. Bounded to one wire token: it is the resolver's text, and the slot
-- it goes into ends at a space.
resolverReason :: Text -> NameReservedReason
resolverReason = reservedReason . T.take 32 . T.takeWhile (/= ' ')

fetch :: NamesEnv -> SimplexDomain -> IO (Either NameErrorType NameResult)
fetch NamesEnv {resolverEnv} d =
  either (Left . mapResolverError) nameResult <$> resolveHttp resolverEnv (fullDomainName d)

-- | A record answers what the name points to; the status answers whether it can
-- be taken; a reservation is orthogonal to both. A resolver that reports no
-- status at all is an older one, and only ever returned a record for a live
-- registration - the client reads the absent status that way.
nameResult :: (Maybe NameRecord, Maybe NameStatusResp) -> Either NameErrorType NameResult
nameResult = \case
  (rec_, Just ns) -> (\(reserved_, reg) -> (reserved_, Just reg, rec_)) <$> mapStatus ns
  (Just rec, Nothing) -> Right (Nothing, Nothing, Just rec)
  (Nothing, Nothing) -> Left NOT_FOUND

-- | The resolver's vocabulary. A status this router has no word for is not an
-- answer: "registered" would assert a registration nobody read, and
-- "unregistered" would offer a name that may be held.
mapStatus :: NameStatusResp -> Either NameErrorType (Maybe NameReservedReason, NameRegistration)
mapStatus ns@NameStatusResp {nsStatus, nsExpires, nsGraceEnds, nsReasonCode} =
  (reserved_,) <$> case nsStatus of
    "registered" -> registered
    -- registered, but its records point nowhere
    "noResolver" -> registered
    "grace" -> registered
    "unregistered" -> Right unregistered
    "expired" -> Right unregistered
    "auction" -> Right unregistered
    s -> Left (RESOLVER (T.take 32 s))
  where
    reserved_ = resolverReason <$> nsReasonCode
    -- a registration the router could not date is not one it can report
    registered = maybe (Left $ RESOLVER "no expiry") Right $ do
      expires <- nsExpires
      graceUntil <- nsGraceEnds
      pure NRRegistered {expires, graceUntil}
    -- a held-back name is not for sale at the registry's price, so it is quoted
    -- no price at all: what it costs is a conversation with SimpleX
    unregistered = NRUnregistered {pricing = if isJust reserved_ then Nothing else namePricing ns}

-- | Absent when the TLD has no controller or price oracle configured. The
-- surcharge start is absent for a name that never lapsed.
namePricing :: NameStatusResp -> Maybe NamePricing
namePricing NameStatusResp {nsRentPrices, nsMinLabelLength, nsPremiumFrom, nsStartPremium, nsEndPremium} = do
  rentPrices <- map MicroUSD <$> nsRentPrices
  minLabelLength <- nsMinLabelLength
  startPremium <- MicroUSD <$> nsStartPremium
  endPremium <- MicroUSD <$> nsEndPremium
  pure NamePricing {rentPrices, minLabelLength, premiumFrom = nsPremiumFrom, startPremium, endPremium}


mapResolverError :: ResolverError -> NameErrorType
mapResolverError = \case
  HttpStatusErr 404 -> NOT_FOUND
  HttpStatusErr 410 -> NOT_FOUND
  HttpStatusErr 400 -> NOT_FOUND
  HttpStatusErr code -> RESOLVER ("HTTP " <> T.pack (show code))
  HttpFailure _ -> RESOLVER "transport failure"
  BodyTooLarge -> RESOLVER "response too large"
  InvalidJson _ -> RESOLVER "invalid response"
  ResolverTimeout -> RESOLVER "timeout"
