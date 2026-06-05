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
-- Exercises the agent layer (real `AgentClient`) against an SMP server with
-- a stub `NamesEnv` — same pattern as `RSLVTests` but going through
-- `sendOrProxySMPCommand` so we cover the agent-side direct/proxy selection
-- and the agent's error mapping (`SMP host AUTH`, `PROXY {.. proxyErr ..}`,
-- `INTERNAL ..`).
module AgentTests.ResolveNameTests (resolveNameTests) where

import AgentTests.FunctionalAPITests (withAgent)
import Control.Monad.Except (runExceptT)
import qualified Data.ByteString.Char8 as B
import Data.List (isInfixOf)
import SMPAgentClient
import SMPClient
import SMPNamesTests (encodeRecordAbi)
import Simplex.Messaging.Agent (resolveSimplexName)
import Simplex.Messaging.Agent.Client (AgentClient)
import Simplex.Messaging.Agent.Env.SQLite (InitialAgentServers (..))
import Simplex.Messaging.Agent.Protocol (AgentErrorType (..))
import Simplex.Messaging.Client (SMPProxyFallback (..), SMPProxyMode (..), pattern NRMInteractive)
import Simplex.Messaging.Protocol (NameRecord (..), mkNameOwner, pattern SMPServer)
import qualified Simplex.Messaging.Protocol as SMP
import Simplex.Messaging.Server.Env.STM (AStoreType (..), ServerConfig (..), ServerStoreCfg (..), StorePaths (..))
import Simplex.Messaging.Server.MsgStore.Types (SMSType (..), SQSType (..))
import Simplex.Messaging.Server.Names (NamesConfig (..), NamesEnv, newNamesEnvWith)
import Simplex.Messaging.Server.Names.Eth.RPC (EthRpcError)
import Simplex.Messaging.SimplexName (SimplexNameDomain (..), SimplexTLD (..))
import Simplex.Messaging.Transport
import Test.Hspec hiding (fit, it)
import Util (it)

-- ---------------------------------------------------------------------------
-- Fixtures (parallel to RSLVTests)
-- ---------------------------------------------------------------------------

-- 12 slots * 32 bytes, all zero. `decodeGetRecord` reads the owner from
-- slot 10 and treats the zero address as the NotFound sentinel, so the
-- resolver maps to `ResolveError.NotFound` -> server `ERR AUTH`.
zeroOwnerAbi :: B.ByteString
zeroOwnerAbi = B.replicate (32 * 12) '\NUL'

stubNamesConfig :: NamesConfig
stubNamesConfig =
  NamesConfig
    { ethereumEndpoint = "http://stub",
      rpcAuth = Nothing,
      rpcTimeoutMs = 1000,
      rpcMaxResponseBytes = 65536,
      rpcMaxConcurrency = 4
    }

stubEthCallNotFound :: B.ByteString -> B.ByteString -> IO (Either EthRpcError B.ByteString)
stubEthCallNotFound _to _data = pure (Right zeroOwnerAbi)

-- | A complete NameRecord used by the success-path test. The decoder fills
-- `nrResolver` from the contract address the server's ethCall was sent to
-- (i.e. the simplex TLD contract); the test asserts against that value.
aliceRecord :: NameRecord
aliceRecord =
  NameRecord
    { nrName = "alice.simplex",
      nrNickname = Just "Alice",
      nrWebsite = Just "https://alice.example",
      nrLocation = Just "Earth",
      nrSimplexContact = Just "simplex:/contact/abc#xyz",
      nrSimplexChannel = Nothing,
      nrEth = Just "0x0000000000000000000000000000000000000001",
      nrBtc = Nothing,
      nrXmr = Nothing,
      nrDot = Nothing,
      nrOwner = either error id (mkNameOwner (B.replicate 20 '\x33')),
      -- Overwritten by the decoder; the placeholder here is never observed.
      nrResolver = either error id (mkNameOwner (B.replicate 20 '\xFF'))
    }

-- | Stub returning a valid ABI buffer for the success path (expiry = 0 ->
-- never expires).
stubEthCallSuccess :: B.ByteString -> B.ByteString -> IO (Either EthRpcError B.ByteString)
stubEthCallSuccess _to _data = pure (Right (encodeRecordAbi aliceRecord 0))

-- | Names env using the static `tldContract` mapping: TLDSimplex and
-- TLDTesting map to placeholder contracts; TLDWeb is unmapped and rejected
-- by the resolver's `verifyRslv`.
mkSimplexOnlyNamesEnv :: IO NamesEnv
mkSimplexOnlyNamesEnv = newNamesEnvWith stubNamesConfig stubEthCallNotFound Nothing

-- | Same as `mkSimplexOnlyNamesEnv` but the stub returns a real record.
mkSuccessNamesEnv :: IO NamesEnv
mkSuccessNamesEnv = newNamesEnvWith stubNamesConfig stubEthCallSuccess Nothing

memCfg :: AServerConfig
memCfg = cfgMS (ASType SQSMemory SMSMemory)

memProxyCfg :: AServerConfig
memProxyCfg = proxyCfgMS (ASType SQSMemory SMSMemory)

-- Second-server `memCfg` variant on `testStoreLogFile2` so the two servers
-- can coexist on the same machine (StoreLog locks `testStoreLogFile`); see
-- RSLVTests `memCfg2` for the same workaround.
memCfg2 :: AServerConfig
memCfg2 = case memCfg of
  ASrvCfg qt mt c -> ASrvCfg qt mt c {serverStoreCfg = newStoreCfg (serverStoreCfg c)}
  where
    newStoreCfg :: ServerStoreCfg s -> ServerStoreCfg s
    newStoreCfg = \case
      SSCMemory _ -> SSCMemory (Just StorePaths {storeLogFile = testStoreLogFile2, storeMsgsFile = Just testStoreMsgsFile2})
      other -> other

-- | Single resolver server on `testPort`, paired with an agent configured
-- for direct sends (SPMNever). The agent's only configured server is the
-- resolver itself.
withDirectResolver :: NamesEnv -> (AgentClient -> IO a) -> IO a
withDirectResolver nenv k =
  withSmpServerConfigOnWithNames (transport @TLS) memCfg testPort nenv $ \_ ->
    withAgent 1 agentCfg directServers testDB k
  where
    directServers = (initAgentServersProxy_ SPMNever SPFProhibit) {smp = userServers [testSMPServer]}

-- | Two-server setup for the proxy path. Proxy on `testPort` (no NamesEnv —
-- proxy doesn't resolve locally), resolver on `testPort2` (stub NamesEnv).
-- Agent's user-server list contains both, with SPMAlways so it always picks
-- a proxy. `getNextServer` excludes the destination from candidates, so the
-- agent picks the first server (proxy) when sending to the second (resolver).
withProxyAndResolver :: NamesEnv -> (AgentClient -> IO a) -> IO a
withProxyAndResolver nenv k =
  withSmpServerConfigOn (transport @TLS) memProxyCfg testPort $ \_ ->
    withSmpServerConfigOnWithNames (transport @TLS) memCfg2 testPort2 nenv $ \_ ->
      withAgent 1 agentCfg proxyServers testDB k
  where
    proxyServers = (initAgentServersProxy_ SPMAlways SPFProhibit) {smp = userServers [testSMPServer, testSMPServer2]}

-- The resolver address corresponds to whichever server has the stub NamesEnv:
-- single-server -> testPort; two-server -> testPort2.
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
      it "AUTH propagates as SMP host AUTH (zero-owner stub -> NotFound)" testDirectAuth
    describe "proxy path (SPMAlways)" $
      it "AUTH from resolver propagates via proxy as SMP <proxyHost> AUTH" testProxyAuth
    describe "TLDTesting path" $
      it "AUTH (zero-owner stub -> NotFound) for TLDTesting too" testUnknownTldOnServer
    describe "TLD without contract entry" $
      it "INTERNAL (TLDWeb has no tldContract entry)" testNoAgentContract
    describe "success path" $
      it "returns NameRecord" testDirectSuccess

-- ---------------------------------------------------------------------------
-- Tests
-- ---------------------------------------------------------------------------

-- | Direct path: agent with SPMNever sends RSLV without PFWD; resolver
-- replies ERR AUTH (placeholder decoder -> NotFound); agent maps the SMP
-- protocol error to `SMP host AUTH` (Client.hs:1255 -> protocolError_).
testDirectAuth :: HasCallStack => IO ()
testDirectAuth = do
  nenv <- mkSimplexOnlyNamesEnv
  withDirectResolver nenv $ \c -> do
    r <- runExceptT $ resolveSimplexName c NRMInteractive 1 directResolverSrv simplexDomain
    case r of
      Left (SMP _ SMP.AUTH) -> pure ()
      _ -> expectationFailure $ "expected Left (SMP _ AUTH), got: " <> show r
  where
    simplexDomain = SimplexNameDomain TLDSimplex "alice" []

-- | Proxy path: agent with SPMAlways wraps RSLV in PFWD; proxy forwards to
-- the resolver, which replies ERR AUTH (placeholder decoder -> NotFound).
-- The proxy's `proxySMPCommand` wraps a destination-relay protocol error in
-- `throwE $ PCEProtocolError AUTH` (Client.hs:1231), which `liftClient SMP`
-- in `sendOrProxySMPCommand` (Client.hs:1179) surfaces as `SMP proxyHost AUTH`.
-- The agent-level `PROXY` constructor is reserved for proxy-side failures
-- (e.g. PROXY NO_SESSION); relay-level protocol errors are reported
-- transparently as SMP errors — this is the "transparent for AUTH/QUOTA"
-- contract documented at Client.hs:1178.
--
-- Note the host is the proxy server's host (testPort/5001), not the resolver
-- — this is the proxy server the agent is connected to for forwarding.
testProxyAuth :: HasCallStack => IO ()
testProxyAuth = do
  nenv <- mkSimplexOnlyNamesEnv
  withProxyAndResolver nenv $ \c -> do
    r <- runExceptT $ resolveSimplexName c NRMInteractive 1 proxiedResolverSrv simplexDomain
    case r of
      Left (SMP host SMP.AUTH) | testPort `isInfixOf` host -> pure ()
      _ -> expectationFailure $ "expected Left (SMP <proxyHost:" <> testPort <> "> AUTH), got: " <> show r
  where
    simplexDomain = SimplexNameDomain TLDSimplex "alice" []

-- | TLDTesting maps (on both agent and server, via the static
-- `tldContract`) to its own placeholder contract. With the placeholder
-- decoder the resolver collapses any non-zero buffer to NotFound, so the
-- agent surfaces `SMP host AUTH`. Sanity-check that the non-default TLD
-- routes through the same code path as TLDSimplex.
testUnknownTldOnServer :: HasCallStack => IO ()
testUnknownTldOnServer = do
  nenv <- mkSimplexOnlyNamesEnv
  withDirectResolver nenv $ \c -> do
    r <- runExceptT $ resolveSimplexName c NRMInteractive 1 directResolverSrv testingDomain
    case r of
      Left (SMP _ SMP.AUTH) -> pure ()
      _ -> expectationFailure $ "expected Left (SMP _ AUTH), got: " <> show r
  where
    testingDomain = SimplexNameDomain TLDTesting "bob" []

-- | Pure agent-side test: `tldContract TLDWeb = Nothing`
-- (SimplexName.Contracts), so `resolveSimplexName'` throws INTERNAL before
-- any server contact. The agent still needs initialisation, but no server
-- bracket: the throw happens before any network IO.
testNoAgentContract :: HasCallStack => IO ()
testNoAgentContract =
  withAgent 1 agentCfg agentServers testDB $ \c -> do
    r <- runExceptT $ resolveSimplexName c NRMInteractive 1 directResolverSrv webDomain
    case r of
      Left (INTERNAL msg) | "no resolver contract for TLD" `isInfixOf` msg -> pure ()
      _ -> expectationFailure $ "expected Left (INTERNAL \"... no resolver contract for TLD\"), got: " <> show r
  where
    webDomain = SimplexNameDomain TLDWeb "example.com" []
    -- Non-empty userServers is required for agent init; never contacted.
    agentServers = initAgentServers {smp = userServers [testSMPServer]}

-- | Success path: stub returns a valid ABI buffer, the agent receives a
-- decoded NameRecord. The decoder populates `nrResolver` with the contract
-- the server's ethCall was sent to (i.e. `tldContract TLDSimplex`), so the
-- expected record's resolver is `'\x11'`-bytes (see Contracts.hs).
testDirectSuccess :: HasCallStack => IO ()
testDirectSuccess = do
  nenv <- mkSuccessNamesEnv
  withDirectResolver nenv $ \c -> do
    r <- runExceptT $ resolveSimplexName c NRMInteractive 1 directResolverSrv simplexDomain
    case r of
      Right nr -> nr `shouldBe` aliceRecord {nrResolver = simplexContract}
      _ -> expectationFailure $ "expected Right NameRecord, got: " <> show r
  where
    simplexDomain = SimplexNameDomain TLDSimplex "alice" []
    simplexContract = either error id (mkNameOwner (B.replicate 20 '\x11'))
