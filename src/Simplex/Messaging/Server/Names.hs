{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StrictData #-}

module Simplex.Messaging.Server.Names
  ( NamesConfig (..),
    RpcAuth (..),
    NamesEnv (..),
    NameFailure (..),
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
import Data.Text.Encoding (decodeLatin1)
import Simplex.Messaging.Encoding
import Simplex.Messaging.Protocol (NameErrorType (..), NameQuery, NameResponse)
import Simplex.Messaging.Server.Names.HttpResolver
  ( ResolverEnv,
    ResolverError (..),
    RpcAuth (..),
    closeResolverEnv,
    healthHttp,
    newResolverEnv,
    resolveHttp,
  )
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

data NameFailure
  = QueryRejected NameErrorType
  | ResolverFailed NameErrorType
  deriving (Eq, Show)

resolveName :: NamesEnv -> NameQuery -> IO (Either NameFailure NameResponse)
resolveName env q = do
  r <- E.try (timeout (resolverTimeoutMs (config env) * 1000) (fetch env q))
  case r of
    Right result -> pure (fromMaybe (Left (ResolverFailed (RESOLVER "timeout"))) result)
    Left e
      | Just (_ :: E.SomeAsyncException) <- E.fromException e -> E.throwIO e
      | otherwise -> do
          logError $ "[NAMES] resolver fetch raised " <> T.pack (E.displayException e)
          pure (Left (ResolverFailed (RESOLVER "resolver error")))

fetch :: NamesEnv -> NameQuery -> IO (Either NameFailure NameResponse)
fetch NamesEnv {resolverEnv} q =
  first mapResolverError <$> resolveHttp resolverEnv (decodeLatin1 $ smpEncode q)

mapResolverError :: ResolverError -> NameFailure
mapResolverError = \case
  HttpStatusErr code (Just c) | c `elem` queryErrors -> QueryRejected (httpErr code)
  HttpStatusErr code _ -> ResolverFailed (httpErr code)
  HttpFailure _ -> ResolverFailed $ RESOLVER "transport failure"
  BodyTooLarge -> ResolverFailed $ RESOLVER "response too large"
  InvalidJson _ -> ResolverFailed $ RESOLVER "invalid response"
  ResolverTimeout -> ResolverFailed $ RESOLVER "timeout"
  where
    httpErr code = RESOLVER ("HTTP " <> T.pack (show code))
    -- error codes of /v2/resolve listed in scripts/resolver/README.md
    queryErrors = ["tldNotConfigured", "notFullyQualified", "labelNotRecorded", "noPriceOracle"]
