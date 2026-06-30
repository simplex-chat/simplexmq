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

module AgentTests.ResolveNameTests (resolveNameTests) where

import AgentTests.FunctionalAPITests (withAgent)
import Control.Monad.Except (runExceptT)
import qualified Data.Aeson as J
import qualified Data.ByteString.Lazy as LB
import Data.List (isInfixOf)
import Network.HTTP.Types (Status, status200, status404, status502)
import NamesResolverServer (memCfg, memCfg2, memProxyCfg, withNames)
import qualified NamesResolverServer as NRS
import SMPAgentClient
import SMPClient
import SMPNamesTests (testNameRecord)
import Simplex.Messaging.Agent (resolveSimplexName)
import Simplex.Messaging.Agent.Client (AgentClient)
import Simplex.Messaging.Agent.Env.SQLite (InitialAgentServers (..), ServerCfg, ServerRoles (..), presetServerCfg)
import Simplex.Messaging.Agent.Protocol (AgentErrorType (..))
import Simplex.Messaging.Client (SMPProxyFallback (..), SMPProxyMode (..), pattern NRMInteractive)
import Simplex.Messaging.Protocol (SMPServer)
import qualified Simplex.Messaging.Protocol as SMP
import Simplex.Messaging.SimplexName (SimplexNameDomain (..), SimplexTLD (..))
import Simplex.Messaging.Transport
import Test.Hspec hiding (fit, it)
import Util (it)

nameSrvCfg :: SMPServer -> ServerCfg 'SMP.PSMP
nameSrvCfg = presetServerCfg True ServerRoles {storage = True, proxy = False, names = True} (Just 1) . SMP.noAuthSrv

proxySrvCfg :: SMPServer -> ServerCfg 'SMP.PSMP
proxySrvCfg = presetServerCfg True ServerRoles {storage = True, proxy = True, names = False} (Just 1) . SMP.noAuthSrv

oneSrv :: ServerCfg 'SMP.PSMP -> InitialAgentServers
oneSrv cfg_ = (initAgentServersProxy_ SPMNever SPFProhibit) {smp = [(1, [cfg_])]}

withDirectResolver :: (Status, LB.ByteString) -> (AgentClient -> IO a) -> IO a
withDirectResolver (st, body) k =
  NRS.withResolverServer (NRS.resolveResp st body) $ \port _ ->
    withSmpServerConfigOn (transport @TLS) (withNames port memCfg) testPort $ \_ ->
      withAgent 1 agentCfg (oneSrv (nameSrvCfg testSMPServer)) testDB k

withProxyAndResolver :: (Status, LB.ByteString) -> (AgentClient -> IO a) -> IO a
withProxyAndResolver (st, body) k =
  NRS.withResolverServer (NRS.resolveResp st body) $ \port _ ->
    withSmpServerConfigOn (transport @TLS) memProxyCfg testPort $ \_ ->
      withSmpServerConfigOn (transport @TLS) (withNames port memCfg2) testPort2 $ \_ ->
        withAgent 1 agentCfg proxyServers testDB k
  where
    -- only testSMPServer2 (the resolver) has the names role; testSMPServer is the proxy
    proxyServers = (initAgentServersProxy_ SPMAlways SPFProhibit) {smp = [(1, [proxySrvCfg testSMPServer, nameSrvCfg testSMPServer2])]}

withNoResolver :: (AgentClient -> IO a) -> IO a
withNoResolver k =
  withSmpServerConfigOn (transport @TLS) memCfg testPort $ \_ ->
    withAgent 1 agentCfg (oneSrv (nameSrvCfg testSMPServer)) testDB k

withNoNameServers :: (AgentClient -> IO a) -> IO a
withNoNameServers k = withAgent 1 agentCfg (oneSrv (proxySrvCfg testSMPServer)) testDB k

resolveNameTests :: Spec
resolveNameTests = do
  describe "direct path (SPMNever)" $
    it "404 propagates as SMP host (NAME NOT_FOUND)" testDirectNotFound
  describe "proxy path (SPMAlways)" $
    it "404 from resolver propagates via proxy as SMP <proxyHost> (NAME NOT_FOUND)" testProxyNotFound
  describe "TLDTesting path" $
    it "NAME NOT_FOUND for TLDTesting too" testTestingTldNotFound
  describe "TLDWeb path" $
    it "NAME NOT_FOUND for TLDWeb too" testWebTldNotFound
  describe "no resolver configured" $
    it "answers NAME NO_RESOLVER" testNoResolver
  describe "no names servers (names role off everywhere)" $
    it "fails agent-side with NO_NAME_SERVERS" testNoNameServers
  describe "backing resolver failure" $
    it "surfaces as SMP host (NAME (RESOLVER ..))" testBackendError
  describe "success path" $
    it "returns NameRecord" testDirectSuccess

testDirectNotFound :: HasCallStack => IO ()
testDirectNotFound =
  withDirectResolver (status404, "{}") $ \c -> do
    r <- runExceptT $ resolveSimplexName c NRMInteractive 1 (SimplexNameDomain TLDSimplex "alice" [])
    case r of
      Left (SMP _ (SMP.NAME SMP.NOT_FOUND)) -> pure ()
      _ -> expectationFailure $ "expected Left (SMP _ (NAME NOT_FOUND)), got: " <> show r

testProxyNotFound :: HasCallStack => IO ()
testProxyNotFound =
  withProxyAndResolver (status404, "{}") $ \c -> do
    r <- runExceptT $ resolveSimplexName c NRMInteractive 1 (SimplexNameDomain TLDSimplex "alice" [])
    case r of
      Left (SMP host (SMP.NAME SMP.NOT_FOUND)) | testPort `isInfixOf` host -> pure ()
      _ -> expectationFailure $ "expected Left (SMP <proxyHost:" <> testPort <> "> (NAME NOT_FOUND)), got: " <> show r

testTestingTldNotFound :: HasCallStack => IO ()
testTestingTldNotFound =
  withDirectResolver (status404, "{}") $ \c -> do
    r <- runExceptT $ resolveSimplexName c NRMInteractive 1 (SimplexNameDomain TLDTesting "bob" [])
    case r of
      Left (SMP _ (SMP.NAME SMP.NOT_FOUND)) -> pure ()
      _ -> expectationFailure $ "expected Left (SMP _ (NAME NOT_FOUND)), got: " <> show r

testWebTldNotFound :: HasCallStack => IO ()
testWebTldNotFound =
  withDirectResolver (status404, "{}") $ \c -> do
    r <- runExceptT $ resolveSimplexName c NRMInteractive 1 (SimplexNameDomain TLDWeb "example.com" [])
    case r of
      Left (SMP _ (SMP.NAME SMP.NOT_FOUND)) -> pure ()
      _ -> expectationFailure $ "expected Left (SMP _ (NAME NOT_FOUND)), got: " <> show r

testNoResolver :: HasCallStack => IO ()
testNoResolver =
  withNoResolver $ \c -> do
    r <- runExceptT $ resolveSimplexName c NRMInteractive 1 (SimplexNameDomain TLDSimplex "alice" [])
    case r of
      Left (SMP _ (SMP.NAME SMP.NO_RESOLVER)) -> pure ()
      _ -> expectationFailure $ "expected Left (SMP _ (NAME NO_RESOLVER)), got: " <> show r

testNoNameServers :: HasCallStack => IO ()
testNoNameServers =
  withNoNameServers $ \c -> do
    r <- runExceptT $ resolveSimplexName c NRMInteractive 1 (SimplexNameDomain TLDSimplex "alice" [])
    case r of
      Left NO_NAME_SERVERS -> pure ()
      _ -> expectationFailure $ "expected Left NO_NAME_SERVERS, got: " <> show r

testBackendError :: HasCallStack => IO ()
testBackendError =
  withDirectResolver (status502, "{}") $ \c -> do
    r <- runExceptT $ resolveSimplexName c NRMInteractive 1 (SimplexNameDomain TLDSimplex "alice" [])
    case r of
      Left (SMP _ (SMP.NAME (SMP.RESOLVER _))) -> pure ()
      _ -> expectationFailure $ "expected Left (SMP _ (NAME (RESOLVER ..))), got: " <> show r

testDirectSuccess :: HasCallStack => IO ()
testDirectSuccess =
  withDirectResolver (status200, J.encode testNameRecord) $ \c -> do
    r <- runExceptT $ resolveSimplexName c NRMInteractive 1 (SimplexNameDomain TLDSimplex "alice" [])
    case r of
      Right nr -> nr `shouldBe` testNameRecord
      _ -> expectationFailure $ "expected Right NameRecord, got: " <> show r
