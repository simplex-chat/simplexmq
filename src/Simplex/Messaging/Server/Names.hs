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
    ownedNames,
  )
where

import qualified Control.Exception as E
import Control.Logger.Simple (logError)
import Data.Bifunctor (first)
import Data.Maybe (fromMaybe)
import qualified Data.Text as T
import Data.Text.Encoding (decodeLatin1)
import Data.Word (Word32)
import Simplex.Messaging.Encoding
import Simplex.Messaging.Encoding.String (strEncode)
import Simplex.Messaging.Eth.Address (Address)
import Simplex.Messaging.Names.Record (OwnedNames)
import Simplex.Messaging.Protocol (NameErrorType (..), NameQuery, NameResponse)
import Simplex.Messaging.Server.Names.HttpResolver
  ( ResolverEnv,
    ResolverError (..),
    RpcAuth (..),
    closeResolverEnv,
    healthHttp,
    newResolverEnv,
    ownedByHttp,
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

resolveName :: NamesEnv -> NameQuery -> IO (Either NameErrorType NameResponse)
resolveName env q = resolverCall env $ fetch env q

-- | Bound the call by the configured timeout, and report a raised exception as an error, leaving async exceptions alone.
resolverCall :: NamesEnv -> IO (Either NameErrorType a) -> IO (Either NameErrorType a)
resolverCall env a =
  E.try (timeout (resolverTimeoutMs (config env) * 1000) a) >>= \case
    Right result -> pure (fromMaybe (Left (RESOLVER "timeout")) result)
    Left e
      | Just (_ :: E.SomeAsyncException) <- E.fromException e -> E.throwIO e
      | otherwise -> do
          logError $ "[NAMES] resolver fetch raised " <> T.pack (E.displayException e)
          pure (Left (RESOLVER "resolver error"))

fetch :: NamesEnv -> NameQuery -> IO (Either NameErrorType NameResponse)
fetch NamesEnv {resolverEnv} q =
  first mapResolverError <$> resolveHttp resolverEnv (decodeLatin1 $ smpEncode q)

-- | The names an address owns. A resolver without the endpoint answers 404, which is a RESOLVER error, not an empty list.
ownedNames :: NamesEnv -> Address -> Word32 -> IO (Either NameErrorType OwnedNames)
ownedNames env addr offset = resolverCall env $ fetchOwned env addr offset

fetchOwned :: NamesEnv -> Address -> Word32 -> IO (Either NameErrorType OwnedNames)
fetchOwned NamesEnv {resolverEnv} addr offset =
  first mapResolverError <$> ownedByHttp resolverEnv (decodeLatin1 $ strEncode addr) offset

mapResolverError :: ResolverError -> NameErrorType
mapResolverError = \case
  HttpStatusErr code -> RESOLVER ("HTTP " <> T.pack (show code))
  HttpFailure _ -> RESOLVER "transport failure"
  BodyTooLarge -> RESOLVER "response too large"
  InvalidJson _ -> RESOLVER "invalid response"
  ResolverTimeout -> RESOLVER "timeout"
