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
import Control.Logger.Simple (logError, logWarn)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (decodeLatin1)
import Data.Time.Clock (UTCTime, diffUTCTime, getCurrentTime)
import Network.HTTP.Client (HttpException (..))
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
import Simplex.Messaging.Util (diffToMilliseconds, tshow)
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
resolveName env q = do
  start <- getCurrentTime
  r <- E.try (timeout (resolverTimeoutMs (config env) * 1000) (fetch env q))
  case r of
    Right (Just (Right res)) -> pure (Right res)
    Right (Just (Left e)) -> failed start (resolverErrorText e) (mapResolverError e)
    Right Nothing -> failed start "timeout" (RESOLVER "timeout")
    Left e
      | Just (_ :: E.SomeAsyncException) <- E.fromException e -> E.throwIO e
      | otherwise -> do
          logError $ "[NAMES] resolver fetch raised " <> T.pack (E.displayException e)
          pure (Left (RESOLVER "resolver error"))
  where
    failed :: UTCTime -> Text -> NameErrorType -> IO (Either NameErrorType NameResponse)
    failed start reason err = do
      ms <- diffToMilliseconds . (`diffUTCTime` start) <$> getCurrentTime
      logWarn $ "[NAMES] resolver failed after " <> tshow ms <> "ms: " <> reason
      pure (Left err)

fetch :: NamesEnv -> NameQuery -> IO (Either ResolverError NameResponse)
fetch NamesEnv {resolverEnv} q = resolveHttp resolverEnv (decodeLatin1 $ smpEncode q)

-- The shown request would put the queried name in the log, so only the content is shown.
resolverErrorText :: ResolverError -> Text
resolverErrorText = \case
  HttpFailure (HttpExceptionRequest _ content) -> tshow content
  e -> tshow e

mapResolverError :: ResolverError -> NameErrorType
mapResolverError = \case
  HttpStatusErr code -> RESOLVER ("HTTP " <> T.pack (show code))
  HttpFailure _ -> RESOLVER "transport failure"
  BodyTooLarge -> RESOLVER "response too large"
  InvalidJson _ -> RESOLVER "invalid response"
  ResolverTimeout -> RESOLVER "timeout"
