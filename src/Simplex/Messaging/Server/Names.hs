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
import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (encodeUtf8)
import Simplex.Messaging.Encoding.String (strDecode)
import Simplex.Messaging.Protocol (NameErrorType (..), NamePricing (..), NameQuery, NameRecord, NameRegistration (..), NameReservedReason (..), USDCents (..), oldRegistration, queryName)
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
import Simplex.Messaging.SystemTime (RoundedSystemTime (..))
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

resolveName :: NamesEnv -> NameQuery -> IO (Either NameErrorType NameRegistration)
resolveName env q = do
  r <- E.try (timeout (resolverTimeoutMs (config env) * 1000) (fetch env q))
  case r of
    Right result -> pure (fromMaybe (Left (RESOLVER "timeout")) result)
    Left e
      | Just (_ :: E.SomeAsyncException) <- E.fromException e -> E.throwIO e
      | otherwise -> do
          logError $ "[NAMES] resolver fetch raised " <> T.pack (E.displayException e)
          pure (Left (RESOLVER "resolver error"))

fetch :: NamesEnv -> NameQuery -> IO (Either NameErrorType NameRegistration)
fetch NamesEnv {resolverEnv} q =
  either (Left . mapResolverError) nameRegistration <$> resolveHttp resolverEnv (queryName q)

-- | A resolver that reports no status is an older one, which returned a record
-- only for a live registration.
nameRegistration :: (Maybe NameRecord, Maybe NameStatusResp) -> Either NameErrorType NameRegistration
nameRegistration = \case
  (rec_, Just ns) -> mapStatus rec_ ns
  (Just rec, Nothing) -> Right (oldRegistration rec)
  (Nothing, Nothing) -> Left NOT_FOUND

-- | The resolver's status words. An unknown status is not an answer.
mapStatus :: Maybe NameRecord -> NameStatusResp -> Either NameErrorType NameRegistration
mapStatus rec_ ns@NameStatusResp {nsStatus, nsExpires, nsGraceEnds, nsReasonCode, nsAuctionUntil} =
  case nsStatus of
    "registered" -> registered
    "grace" -> registered
    "unregistered" -> available
    "expired" -> available
    s -> Left (RESOLVER (T.take 32 s))
  where
    reservedReason_ = resolverReason <$> nsReasonCode
    -- A registered name always has a record, and a registration this router
    -- cannot date is not one it can report.
    registered = case (rec_, nsExpires, nsGraceEnds) of
      (Just nameRecord, Just expires, Just graceUntil) ->
        Right NRRegistered {expires = Just (RoundedSystemTime expires), graceUntil = Just (RoundedSystemTime graceUntil), reservedReason_, nameRecord}
      (Nothing, _, _) -> Left (RESOLVER "no record")
      _ -> Left (RESOLVER "no expiry")
    available = case reservedReason_ of
      Just r -> Right (NRReserved r)
      Nothing -> case namePricing ns of
        Just pricing -> Right NRAvailable {pricing, auctionUntil = RoundedSystemTime <$> nsAuctionUntil}
        Nothing -> Left (RESOLVER "no price oracle")

-- | An unknown code still reserves the name, and travels on as itself. Cut to
-- one printable token: the wire slot it goes into ends at a space.
resolverReason :: Text -> NameReservedReason
resolverReason t = either (const (NRRUnknown t')) id (strDecode (encodeUtf8 t'))
  where
    t' = T.take 32 (T.takeWhile (\c -> c > ' ' && c < '\DEL') t)

namePricing :: NameStatusResp -> Maybe NamePricing
namePricing NameStatusResp {nsRentPrices, nsBasePrice, nsMinLabelLength} = do
  rentPrices <- M.map USDCents <$> nsRentPrices
  basePrice <- USDCents <$> nsBasePrice
  minLabelLength <- nsMinLabelLength
  pure NamePricing {rentPrices, basePrice, minLabelLength}

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
