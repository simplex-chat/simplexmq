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
import Data.Bifunctor (first)
import Data.Maybe (fromMaybe)
import qualified Data.Text as T
import Data.Text.Encoding (decodeLatin1)
import Simplex.Messaging.Encoding
import Simplex.Messaging.Protocol (NameErrorType (..), NameQuery, NameResolution)
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

resolveName :: NamesEnv -> NameQuery -> IO (Either NameErrorType NameResolution)
resolveName env q = do
  r <- E.try (timeout (resolverTimeoutMs (config env) * 1000) (fetch env q))
  case r of
    Right result -> pure (fromMaybe (Left (RESOLVER "timeout")) result)
    Left e
      | Just (_ :: E.SomeAsyncException) <- E.fromException e -> E.throwIO e
      | otherwise -> do
          logError $ "[NAMES] resolver fetch raised " <> T.pack (E.displayException e)
          pure (Left (RESOLVER "resolver error"))

fetch :: NamesEnv -> NameQuery -> IO (Either NameErrorType NameResolution)
fetch NamesEnv {resolverEnv} q =
  first mapResolverError <$> resolveHttp resolverEnv (decodeLatin1 $ smpEncode q)

mapResolverError :: ResolverError -> NameErrorType
mapResolverError = \case
  HttpStatusErr code -> RESOLVER ("HTTP " <> T.pack (show code))
  HttpFailure _ -> RESOLVER "transport failure"
  BodyTooLarge -> RESOLVER "response too large"
  InvalidJson _ -> RESOLVER "invalid response"
  ResolverTimeout -> RESOLVER "timeout"
