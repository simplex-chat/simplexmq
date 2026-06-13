{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# OPTIONS_GHC -fno-warn-ambiguous-fields #-}

-- | End-to-end tests for `Simplex.Messaging.Agent.resolveSimplexName`.
--
-- Exercises the agent layer (real `AgentClient`) against an SMP server with a
-- stub `ResolverCall` (set via `ServerConfig.namesResolverCall_`). The agent
-- owns server selection: it picks a names-capable server (ServerRoles.names)
-- from the user's nameSrvs, so the proxy test gives ONLY the resolver server
-- the names role (deterministic selection) and the proxy server the proxy role.
module AgentTests.ResolveNameTests (resolveNameTests) where

import AgentTests.FunctionalAPITests (withAgent)
import Control.Monad.Except (runExceptT)
import qualified Data.Aeson as J
import Data.List (isInfixOf)
import SMPAgentClient
import SMPClient
import SMPNamesTests (sampleRecord, sampleRecordJSON)
import Simplex.Messaging.Agent (resolveSimplexName)
import Simplex.Messaging.Agent.Client (AgentClient)
import Simplex.Messaging.Agent.Env.SQLite (InitialAgentServers (..), ServerCfg, ServerRoles (..), presetServerCfg)
import Simplex.Messaging.Agent.Protocol (AgentErrorType (..))
import Simplex.Messaging.Client (SMPProxyFallback (..), SMPProxyMode (..), pattern NRMInteractive)
import Simplex.Messaging.Protocol (SMPServer)
import qualified Simplex.Messaging.Protocol as SMP
import Simplex.Messaging.Server.Env.STM (AStoreType (..), ServerConfig (..), ServerStoreCfg (..), StorePaths (..))
import Simplex.Messaging.Server.MsgStore.Types (SMSType (..), SQSType (..))
import Simplex.Messaging.Server.Names (NamesConfig (..), ResolverCall, ResolverCallKind (..))
import Simplex.Messaging.Server.Names.HttpResolver (ResolverError (..))
import Simplex.Messaging.SimplexName (SimplexNameDomain (..), SimplexTLD (..))
import Simplex.Messaging.Transport
import Test.Hspec hiding (fit, it)
import Util (it)

stubNamesConfig :: NamesConfig
stubNamesConfig =
  NamesConfig
    { resolverEndpoint = "http://stub",
      resolverAuth = Nothing,
      resolverTimeoutMs = 1000,
      resolverMaxResponseBytes = 65536
    }

-- | 404 stub: resolver returns "not registered". Server -> ERR (NAME NO_NAME).
stubResolverNotFound :: ResolverCall
stubResolverNotFound = \case
  ResolverFetch _ -> pure (Left (HttpStatusErr 404))
  ResolverHealth -> pure (Right (J.object []))

-- | Success stub: returns the canned NameRecord JSON.
stubResolverSuccess :: ResolverCall
stubResolverSuccess = \case
  ResolverFetch _ -> pure (Right sampleRecordJSON)
  ResolverHealth -> pure (Right (J.object []))

-- | 502 stub: backing resolver fails. Server -> ERR (NAME (RESOLVER "HTTP 502")).
stubResolverError :: ResolverCall
stubResolverError = \case
  ResolverFetch _ -> pure (Left (HttpStatusErr 502))
  ResolverHealth -> pure (Right (J.object []))

-- | Enable names on a server config with a stub resolver (no real HTTP/probe).
withNames :: ResolverCall -> AServerConfig -> AServerConfig
withNames stub c = updateCfg c $ \cfg_ -> cfg_ {namesConfig = Just stubNamesConfig, namesResolverCall_ = Just stub}

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

-- per-server roles: only the resolver server carries the names role
nameSrvCfg :: SMPServer -> ServerCfg 'SMP.PSMP
nameSrvCfg = presetServerCfg True ServerRoles {storage = True, proxy = False, names = True} (Just 1) . SMP.noAuthSrv

proxySrvCfg :: SMPServer -> ServerCfg 'SMP.PSMP
proxySrvCfg = presetServerCfg True ServerRoles {storage = True, proxy = True, names = False} (Just 1) . SMP.noAuthSrv

-- single-server (operator 1) agent config, direct (no proxy)
oneSrv :: ServerCfg 'SMP.PSMP -> InitialAgentServers
oneSrv cfg_ = (initAgentServersProxy_ SPMNever SPFProhibit) {smp = [(1, [cfg_])]}

withDirectResolver :: ResolverCall -> (AgentClient -> IO a) -> IO a
withDirectResolver stub k =
  withSmpServerConfigOn (transport @TLS) (withNames stub memCfg) testPort $ \_ ->
    withAgent 1 agentCfg (oneSrv (nameSrvCfg testSMPServer)) testDB k

withProxyAndResolver :: ResolverCall -> (AgentClient -> IO a) -> IO a
withProxyAndResolver stub k =
  withSmpServerConfigOn (transport @TLS) memProxyCfg testPort $ \_ ->
    withSmpServerConfigOn (transport @TLS) (withNames stub memCfg2) testPort2 $ \_ ->
      withAgent 1 agentCfg proxyServers testDB k
  where
    -- only testSMPServer2 (the resolver) has the names role; testSMPServer is the proxy
    proxyServers = (initAgentServersProxy_ SPMAlways SPFProhibit) {smp = [(1, [proxySrvCfg testSMPServer, nameSrvCfg testSMPServer2])]}

-- | A direct SMP server with NO names role configured (namesEnv = Nothing): the
-- agent still picks it (client-side names role) and the server answers
-- NAME NO_RESOLVER.
withNoResolver :: (AgentClient -> IO a) -> IO a
withNoResolver k =
  withSmpServerConfigOn (transport @TLS) memCfg testPort $ \_ ->
    withAgent 1 agentCfg (oneSrv (nameSrvCfg testSMPServer)) testDB k

-- | An agent whose one server has the names role OFF (proxySrvCfg): nameSrvs is
-- empty, but the user exists, so resolution fails agent-side in getNextNameServer
-- with NO_SERVERS (not the unknown-user INTERNAL path) - no server is contacted.
withNoNameServers :: (AgentClient -> IO a) -> IO a
withNoNameServers k = withAgent 1 agentCfg (oneSrv (proxySrvCfg testSMPServer)) testDB k

-- ---------------------------------------------------------------------------
-- Spec
-- ---------------------------------------------------------------------------

resolveNameTests :: Spec
resolveNameTests = do
  describe "Agent resolveSimplexName" $ do
    describe "direct path (SPMNever)" $
      it "404 propagates as SMP host (NAME NO_NAME)" testDirectNotFound
    describe "proxy path (SPMAlways)" $
      it "404 from resolver propagates via proxy as SMP <proxyHost> (NAME NO_NAME)" testProxyNotFound
    describe "TLDTesting path" $
      it "NAME NO_NAME for TLDTesting too" testTestingTldNotFound
    describe "TLDWeb path" $
      it "NAME NO_NAME for TLDWeb too" testWebTldNotFound
    describe "no resolver configured" $
      it "answers NAME NO_RESOLVER" testNoResolver
    describe "no names servers (names role off everywhere)" $
      it "fails agent-side with NAME NO_SERVERS" testNoNameServers
    describe "backing resolver failure" $
      it "surfaces as SMP host (NAME (RESOLVER ..))" testBackendError
    describe "success path" $
      it "returns NameRecord" testDirectSuccess

-- ---------------------------------------------------------------------------
-- Tests
-- ---------------------------------------------------------------------------

testDirectNotFound :: HasCallStack => IO ()
testDirectNotFound =
  withDirectResolver stubResolverNotFound $ \c -> do
    r <- runExceptT $ resolveSimplexName c NRMInteractive 1 (SimplexNameDomain TLDSimplex "alice" [])
    case r of
      Left (SMP _ (SMP.NAME SMP.NO_NAME)) -> pure ()
      _ -> expectationFailure $ "expected Left (SMP _ (NAME NO_NAME)), got: " <> show r

testProxyNotFound :: HasCallStack => IO ()
testProxyNotFound =
  withProxyAndResolver stubResolverNotFound $ \c -> do
    r <- runExceptT $ resolveSimplexName c NRMInteractive 1 (SimplexNameDomain TLDSimplex "alice" [])
    case r of
      Left (SMP host (SMP.NAME SMP.NO_NAME)) | testPort `isInfixOf` host -> pure ()
      _ -> expectationFailure $ "expected Left (SMP <proxyHost:" <> testPort <> "> (NAME NO_NAME)), got: " <> show r

testTestingTldNotFound :: HasCallStack => IO ()
testTestingTldNotFound =
  withDirectResolver stubResolverNotFound $ \c -> do
    r <- runExceptT $ resolveSimplexName c NRMInteractive 1 (SimplexNameDomain TLDTesting "bob" [])
    case r of
      Left (SMP _ (SMP.NAME SMP.NO_NAME)) -> pure ()
      _ -> expectationFailure $ "expected Left (SMP _ (NAME NO_NAME)), got: " <> show r

testWebTldNotFound :: HasCallStack => IO ()
testWebTldNotFound =
  withDirectResolver stubResolverNotFound $ \c -> do
    r <- runExceptT $ resolveSimplexName c NRMInteractive 1 (SimplexNameDomain TLDWeb "example.com" [])
    case r of
      Left (SMP _ (SMP.NAME SMP.NO_NAME)) -> pure ()
      _ -> expectationFailure $ "expected Left (SMP _ (NAME NO_NAME)), got: " <> show r

-- | A router with the names role but no resolver configured answers
-- NAME NO_RESOLVER (distinct from NO_NAME / NO_SERVERS).
testNoResolver :: HasCallStack => IO ()
testNoResolver =
  withNoResolver $ \c -> do
    r <- runExceptT $ resolveSimplexName c NRMInteractive 1 (SimplexNameDomain TLDSimplex "alice" [])
    case r of
      Left (SMP _ (SMP.NAME SMP.NO_RESOLVER)) -> pure ()
      _ -> expectationFailure $ "expected Left (SMP _ (NAME NO_RESOLVER)), got: " <> show r

-- | With no names-role servers, resolution fails agent-side (no server is
-- contacted) with the agent-origin AgentErrorType.NAME NO_SERVERS.
testNoNameServers :: HasCallStack => IO ()
testNoNameServers =
  withNoNameServers $ \c -> do
    r <- runExceptT $ resolveSimplexName c NRMInteractive 1 (SimplexNameDomain TLDSimplex "alice" [])
    case r of
      Left (NAME SMP.NO_SERVERS) -> pure ()
      _ -> expectationFailure $ "expected Left (NAME NO_SERVERS), got: " <> show r

-- | A backing-resolver failure (502) surfaces as SMP host (NAME (RESOLVER ..)) -
-- a transient error distinct from NO_NAME ("name not registered").
testBackendError :: HasCallStack => IO ()
testBackendError =
  withDirectResolver stubResolverError $ \c -> do
    r <- runExceptT $ resolveSimplexName c NRMInteractive 1 (SimplexNameDomain TLDSimplex "alice" [])
    case r of
      Left (SMP _ (SMP.NAME (SMP.RESOLVER _))) -> pure ()
      _ -> expectationFailure $ "expected Left (SMP _ (NAME (RESOLVER ..))), got: " <> show r

testDirectSuccess :: HasCallStack => IO ()
testDirectSuccess =
  withDirectResolver stubResolverSuccess $ \c -> do
    r <- runExceptT $ resolveSimplexName c NRMInteractive 1 (SimplexNameDomain TLDSimplex "alice" [])
    case r of
      Right nr -> nr `shouldBe` sampleRecord
      _ -> expectationFailure $ "expected Right NameRecord, got: " <> show r
