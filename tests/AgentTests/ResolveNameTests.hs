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
-- Exercises the agent layer (real `AgentClient`) against an SMP server
-- whose `NamesEnv` is a stub `ResolverCall` — same pattern as `RSLVTests`
-- but going through `sendOrProxySMPCommand` so we cover the agent-side
-- direct/proxy selection and the agent's error mapping.
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
import Simplex.Messaging.Agent.Env.SQLite (InitialAgentServers (..))
import Simplex.Messaging.Agent.Protocol (AgentErrorType (..))
import Simplex.Messaging.Client (SMPProxyFallback (..), SMPProxyMode (..), pattern NRMInteractive)
import Simplex.Messaging.Protocol (pattern SMPServer)
import qualified Simplex.Messaging.Protocol as SMP
import Simplex.Messaging.Server.Env.STM (AStoreType (..), ServerConfig (..), ServerStoreCfg (..), StorePaths (..))
import Simplex.Messaging.Server.MsgStore.Types (SMSType (..), SQSType (..))
import Simplex.Messaging.Server.Names
  ( NamesConfig (..),
    NamesEnv,
    ResolverCall,
    ResolverCallKind (..),
    newNamesEnvWith,
  )
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

-- | 404 stub: the resolver returns "not registered". Server maps to ERR
-- AUTH; agent surfaces as SMP host AUTH.
stubResolverNotFound :: ResolverCall
stubResolverNotFound = \case
  ResolverFetch _ -> pure (Left (HttpStatusErr 404))
  ResolverHealth -> pure (Right (J.object []))

-- | Success stub: returns the canned NameRecord JSON.
stubResolverSuccess :: ResolverCall
stubResolverSuccess = \case
  ResolverFetch _ -> pure (Right sampleRecordJSON)
  ResolverHealth -> pure (Right (J.object []))

-- | 502 stub: the backing resolver fails (upstream RPC error). Server maps to
-- ERR INTERNAL; agent surfaces as SMP host INTERNAL (transient, not "not found").
stubResolverError :: ResolverCall
stubResolverError = \case
  ResolverFetch _ -> pure (Left (HttpStatusErr 502))
  ResolverHealth -> pure (Right (J.object []))

mkNotFoundNamesEnv :: IO NamesEnv
mkNotFoundNamesEnv = newNamesEnvWith stubNamesConfig stubResolverNotFound Nothing

mkSuccessNamesEnv :: IO NamesEnv
mkSuccessNamesEnv = newNamesEnvWith stubNamesConfig stubResolverSuccess Nothing

mkErrorNamesEnv :: IO NamesEnv
mkErrorNamesEnv = newNamesEnvWith stubNamesConfig stubResolverError Nothing

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

withDirectResolver :: NamesEnv -> (AgentClient -> IO a) -> IO a
withDirectResolver nenv k =
  withSmpServerConfigOnWithNames (transport @TLS) memCfg testPort nenv $ \_ ->
    withAgent 1 agentCfg directServers testDB k
  where
    directServers = (initAgentServersProxy_ SPMNever SPFProhibit) {smp = userServers [testSMPServer]}

withProxyAndResolver :: NamesEnv -> (AgentClient -> IO a) -> IO a
withProxyAndResolver nenv k =
  withSmpServerConfigOn (transport @TLS) memProxyCfg testPort $ \_ ->
    withSmpServerConfigOnWithNames (transport @TLS) memCfg2 testPort2 nenv $ \_ ->
      withAgent 1 agentCfg proxyServers testDB k
  where
    proxyServers = (initAgentServersProxy_ SPMAlways SPFProhibit) {smp = userServers [testSMPServer, testSMPServer2]}

-- | A direct SMP server with NO names role configured (namesEnv = Nothing).
withNoResolver :: (AgentClient -> IO a) -> IO a
withNoResolver k =
  withSmpServerConfigOn (transport @TLS) memCfg testPort $ \_ ->
    withAgent 1 agentCfg directServers testDB k
  where
    directServers = (initAgentServersProxy_ SPMNever SPFProhibit) {smp = userServers [testSMPServer]}

directResolverSrv :: SMP.SMPServer
directResolverSrv = SMPServer testHost testPort testKeyHash

proxiedResolverSrv :: SMP.SMPServer
proxiedResolverSrv = SMPServer testHost2 testPort2 testKeyHash

-- ---------------------------------------------------------------------------
-- Spec
-- ---------------------------------------------------------------------------

resolveNameTests :: Spec
resolveNameTests = do
  describe "Agent resolveSimplexName" $ do
    describe "direct path (SPMNever)" $
      it "AUTH propagates as SMP host AUTH (resolver 404 -> NotFound)" testDirectAuth
    describe "proxy path (SPMAlways)" $
      it "AUTH from resolver propagates via proxy as SMP <proxyHost> AUTH" testProxyAuth
    describe "TLDTesting path" $
      it "AUTH (resolver 404 -> NotFound) for TLDTesting too" testTestingTldAuth
    describe "TLDWeb path" $
      it "AUTH (resolver 404 -> NotFound) for TLDWeb too" testWebTldAuth
    describe "no resolver configured" $
      it "answers CMD PROHIBITED so the client skips this server" testNoResolverProhibited
    describe "backing resolver failure" $
      it "surfaces as SMP host INTERNAL (transient, not not-found)" testBackendErrorInternal
    describe "success path" $
      it "returns NameRecord" testDirectSuccess

-- ---------------------------------------------------------------------------
-- Tests
-- ---------------------------------------------------------------------------

-- | Direct path: agent with SPMNever sends RSLV without PFWD; resolver
-- replies 404 (not found); server returns ERR AUTH; agent maps to
-- `SMP host AUTH`.
testDirectAuth :: HasCallStack => IO ()
testDirectAuth = do
  nenv <- mkNotFoundNamesEnv
  withDirectResolver nenv $ \c -> do
    r <- runExceptT $ resolveSimplexName c NRMInteractive 1 directResolverSrv simplexDomain
    case r of
      Left (SMP _ SMP.AUTH) -> pure ()
      _ -> expectationFailure $ "expected Left (SMP _ AUTH), got: " <> show r
  where
    simplexDomain = SimplexNameDomain TLDSimplex "alice" []

-- | Proxy path: relay-level protocol errors are reported transparently as
-- SMP errors with the proxy host (see Client.hs:1178 "transparent for
-- AUTH/QUOTA").
testProxyAuth :: HasCallStack => IO ()
testProxyAuth = do
  nenv <- mkNotFoundNamesEnv
  withProxyAndResolver nenv $ \c -> do
    r <- runExceptT $ resolveSimplexName c NRMInteractive 1 proxiedResolverSrv simplexDomain
    case r of
      Left (SMP host SMP.AUTH) | testPort `isInfixOf` host -> pure ()
      _ -> expectationFailure $ "expected Left (SMP <proxyHost:" <> testPort <> "> AUTH), got: " <> show r
  where
    simplexDomain = SimplexNameDomain TLDSimplex "alice" []

-- | TLDTesting routes through the same code path as TLDSimplex (the contract
-- field is ignored server-side; the resolver decides which registry to query).
testTestingTldAuth :: HasCallStack => IO ()
testTestingTldAuth = do
  nenv <- mkNotFoundNamesEnv
  withDirectResolver nenv $ \c -> do
    r <- runExceptT $ resolveSimplexName c NRMInteractive 1 directResolverSrv testingDomain
    case r of
      Left (SMP _ SMP.AUTH) -> pure ()
      _ -> expectationFailure $ "expected Left (SMP _ AUTH), got: " <> show r
  where
    testingDomain = SimplexNameDomain TLDTesting "bob" []

-- | TLDWeb is no longer a TLDContract-gated short-circuit on the agent side;
-- the agent forwards the request to the server, which forwards to the
-- resolver, which decides (per its configured TLDs) whether to honour the
-- lookup. The stub here returns 404 for every fetch, so we get AUTH.
testWebTldAuth :: HasCallStack => IO ()
testWebTldAuth = do
  nenv <- mkNotFoundNamesEnv
  withDirectResolver nenv $ \c -> do
    r <- runExceptT $ resolveSimplexName c NRMInteractive 1 directResolverSrv webDomain
    case r of
      Left (SMP _ SMP.AUTH) -> pure ()
      _ -> expectationFailure $ "expected Left (SMP _ AUTH), got: " <> show r
  where
    webDomain = SimplexNameDomain TLDWeb "example.com" []

-- | A router with no resolver configured (namesEnv = Nothing) answers
-- CMD PROHIBITED, so a client iterating its servers skips it and tries the
-- next rather than treating the response as an authoritative "not found".
testNoResolverProhibited :: HasCallStack => IO ()
testNoResolverProhibited =
  withNoResolver $ \c -> do
    r <- runExceptT $ resolveSimplexName c NRMInteractive 1 directResolverSrv simplexDomain
    case r of
      Left (SMP _ (SMP.CMD SMP.PROHIBITED)) -> pure ()
      _ -> expectationFailure $ "expected Left (SMP _ (CMD PROHIBITED)), got: " <> show r
  where
    simplexDomain = SimplexNameDomain TLDSimplex "alice" []

-- | A backing-resolver failure (502 upstream) surfaces as SMP host INTERNAL -
-- a transient error the client surfaces / retries, distinct from AUTH which
-- would (incorrectly) read as "name not registered".
testBackendErrorInternal :: HasCallStack => IO ()
testBackendErrorInternal = do
  nenv <- mkErrorNamesEnv
  withDirectResolver nenv $ \c -> do
    r <- runExceptT $ resolveSimplexName c NRMInteractive 1 directResolverSrv simplexDomain
    case r of
      Left (SMP _ SMP.INTERNAL) -> pure ()
      _ -> expectationFailure $ "expected Left (SMP _ INTERNAL), got: " <> show r
  where
    simplexDomain = SimplexNameDomain TLDSimplex "alice" []

-- | Success path: stub returns a real NameRecord. The agent surfaces it
-- verbatim.
testDirectSuccess :: HasCallStack => IO ()
testDirectSuccess = do
  nenv <- mkSuccessNamesEnv
  withDirectResolver nenv $ \c -> do
    r <- runExceptT $ resolveSimplexName c NRMInteractive 1 directResolverSrv simplexDomain
    case r of
      Right nr -> nr `shouldBe` sampleRecord
      _ -> expectationFailure $ "expected Right NameRecord, got: " <> show r
  where
    simplexDomain = SimplexNameDomain TLDSimplex "alice" []
