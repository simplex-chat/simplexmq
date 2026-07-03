{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -fno-warn-ambiguous-fields #-}

-- | Name resolver mock
module NamesResolverServer
  ( withResolverServer,
    withResolverServerDelayed,
    resolveResp,
    testNamesConfig,
    memCfg,
    memProxyCfg,
    memCfg2,
    withNames,
  )
where

import Control.Concurrent (threadDelay)
import Control.Monad (when)
import qualified Data.ByteString.Lazy as LB
import Data.IORef (IORef, atomicModifyIORef', newIORef)
import Data.Text (Text)
import Network.HTTP.Types (Status, hContentType, notFound404, ok200)
import Network.Wai (Application, pathInfo, responseLBS)
import qualified Network.Wai.Handler.Warp as Warp
import SMPClient (AServerConfig (..), cfgMS, proxyCfgMS, testStoreLogFile2, testStoreMsgsFile2, updateCfg)
import Simplex.Messaging.Server.Env.STM (AStoreType (..), ServerConfig (..), ServerStoreCfg (..), StorePaths (..))
import Simplex.Messaging.Server.MsgStore.Types (SMSType (..), SQSType (..))
import Simplex.Messaging.Server.Names (NamesConfig (..))

-- | Run an action with a local HTTP resolver on a free port.
withResolverServer :: ([Text] -> (Status, LB.ByteString)) -> (Int -> IORef [[Text]] -> IO a) -> IO a
withResolverServer = withResolverServerDelayed 0

withResolverServerDelayed :: Int -> ([Text] -> (Status, LB.ByteString)) -> (Int -> IORef [[Text]] -> IO a) -> IO a
withResolverServerDelayed delayMs handler action = do
  reqs <- newIORef []
  Warp.withApplication (pure (app reqs)) $ \port -> action port reqs
  where
    app :: IORef [[Text]] -> Application
    app reqs req send = do
      atomicModifyIORef' reqs $ \rs -> (rs <> [pathInfo req], ())
      when (delayMs > 0) $ threadDelay (delayMs * 1000)
      let (st, body) = handler (pathInfo req)
      send $ responseLBS st [(hContentType, "application/json")] body

resolveResp :: Status -> LB.ByteString -> [Text] -> (Status, LB.ByteString)
resolveResp st body = \case
  ["health"] -> (ok200, "{}")
  ("resolve" : _) -> (st, body)
  _ -> (notFound404, "{}")

testNamesConfig :: Int -> NamesConfig
testNamesConfig port =
  NamesConfig
    { resolverEndpoint = "http://127.0.0.1:" <> show port,
      resolverAuth = Nothing,
      resolverTimeoutMs = 1000,
      resolverMaxResponseBytes = 65536
    }

memCfg :: AServerConfig
memCfg = cfgMS (ASType SQSMemory SMSMemory)

memProxyCfg :: AServerConfig
memProxyCfg = proxyCfgMS (ASType SQSMemory SMSMemory)

memCfg2 :: AServerConfig
memCfg2 = case memCfg of
  ASrvCfg qt mt c -> ASrvCfg qt mt c {serverStoreCfg = newStoreCfg (serverStoreCfg c)}
  where
    newStoreCfg :: ServerStoreCfg s -> ServerStoreCfg s
    newStoreCfg = \case
      SSCMemory _ -> SSCMemory (Just StorePaths {storeLogFile = testStoreLogFile2, storeMsgsFile = Just testStoreMsgsFile2})
      other -> other

withNames :: Int -> AServerConfig -> AServerConfig
withNames port c = updateCfg c $ \cfg_ -> cfg_ {namesConfig = Just (testNamesConfig port)}
