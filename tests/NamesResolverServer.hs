{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -fno-warn-ambiguous-fields #-}

-- | A real local HTTP resolver for the names tests. Tests point
-- `resolver_endpoint` at this server (http://127.0.0.1:<port>) so the full
-- HttpResolver path - request building, response reading, body cap, JSON
-- decoding - is exercised end to end, instead of injecting a stub below HTTP.
--
-- It also hosts the SMP server config fixtures shared by the names tests
-- (RSLVTests and AgentTests.ResolveNameTests), so the two suites stay in sync.
module NamesResolverServer
  ( withResolverServer,
    withResolverServerDelayed,
    resolveResp,
    testNamesConfig,
    memCfg,
    memProxyCfg,
    memCfg2,
    withNames,
    withNamesCap,
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

-- | Run an action with a local HTTP resolver listening on a free port. The
-- handler maps the request path segments to an HTTP response; every request's
-- path segments are appended to the returned log (for "no cache" / "addressed
-- with full name" assertions).
withResolverServer :: ([Text] -> (Status, LB.ByteString)) -> (Int -> IORef [[Text]] -> IO a) -> IO a
withResolverServer = withResolverServerDelayed 0

-- | Like 'withResolverServer' but delays each response by delayMs (exercises
-- the resolverTimeoutMs path).
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

-- | Handler that answers /health with 200 and every /resolve/<name> with the
-- given status + body; anything else 404s.
resolveResp :: Status -> LB.ByteString -> [Text] -> (Status, LB.ByteString)
resolveResp st body = \case
  ["health"] -> (ok200, "{}")
  ("resolve" : _) -> (st, body)
  _ -> (notFound404, "{}")

-- | Names config pointing at the local test resolver on `port`. Response cap
-- defaults to 65536; override via record update for the body-cap case.
testNamesConfig :: Int -> NamesConfig
testNamesConfig port =
  NamesConfig
    { resolverEndpoint = "http://127.0.0.1:" <> show port,
      resolverAuth = Nothing,
      resolverTimeoutMs = 1000,
      resolverMaxResponseBytes = 65536,
      resolverMaxConcurrent = 32
    }

memCfg :: AServerConfig
memCfg = cfgMS (ASType SQSMemory SMSMemory)

memProxyCfg :: AServerConfig
memProxyCfg = proxyCfgMS (ASType SQSMemory SMSMemory)

-- | 'memCfg' on the second store-log/messages files, for the second SMP server
-- (proxy + relay setups need two servers with distinct on-disk state).
memCfg2 :: AServerConfig
memCfg2 = case memCfg of
  ASrvCfg qt mt c -> ASrvCfg qt mt c {serverStoreCfg = newStoreCfg (serverStoreCfg c)}
  where
    newStoreCfg :: ServerStoreCfg s -> ServerStoreCfg s
    newStoreCfg = \case
      SSCMemory _ -> SSCMemory (Just StorePaths {storeLogFile = testStoreLogFile2, storeMsgsFile = Just testStoreMsgsFile2})
      other -> other

-- | Enable names on a config pointing at the local test resolver on `port`.
withNames :: Int -> AServerConfig -> AServerConfig
withNames port c = updateCfg c $ \cfg_ -> cfg_ {namesConfig = Just (testNamesConfig port)}

-- | Like 'withNames' but with a custom in-flight resolver cap, for tests that
-- exercise load-shedding / slot release at a small cap.
withNamesCap :: Int -> Int -> AServerConfig -> AServerConfig
withNamesCap cap port c = updateCfg c $ \cfg_ -> cfg_ {namesConfig = Just (testNamesConfig port) {resolverMaxConcurrent = cap}}
