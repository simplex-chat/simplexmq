{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# OPTIONS_GHC -fno-warn-ambiguous-fields #-}

-- | Functional-API tests for the public-namespace resolver (RSLV).
--
-- Mocks the resolver at the `ethCall` layer using `newNamesEnvWith`. The
-- production `decodeGetRecord` is currently a placeholder that returns
-- `Right Nothing` for any non-malformed buffer (see Server/Names/Eth/SNRC.hs);
-- consequently the success-path test ("returns NAME with NameRecord") is
-- marked `pendingWith` until the SNRC ABI codec ships. Until then we test:
--   * direct RSLV (post-`ecd89cf1`) is accepted (not `CMD PROHIBITED`)
--   * `ERR AUTH` for contract / TLD config mismatches (verifyRslv layer)
--   * `ERR AUTH` for backend `NotFound` (placeholder decoder always hits this)
--   * `ERR AUTH` for backend transport errors
--   * `ERR AUTH` when the server has no `namesEnv` (rslvDisabled)
--   * the same paths via PFWD round-trip (proxy + resolver wiring works)
module RSLVTests (rslvTests) where

import Control.Monad.Trans.Except (ExceptT, runExceptT)
import qualified Data.ByteString.Char8 as B
import Data.List.NonEmpty (NonEmpty (..))
import Data.Time.Clock (getCurrentTime)
import SMPClient
import Simplex.Messaging.Client
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Protocol
  ( BrokerMsg (..),
    Cmd (..),
    Command (..),
    CorrId (..),
    ErrorType (..),
    NameOwner,
    RslvRequest (..),
    SParty (..),
    Transmission,
    TransmissionForAuth (..),
    encodeTransmissionForAuth,
    mkNameOwner,
    pattern SMPServer,
    tGetClient,
    tPut,
  )
import qualified Simplex.Messaging.Protocol as SMP
import Simplex.Messaging.Server.Env.STM (AStoreType (..), ServerConfig (..), ServerStoreCfg (..), StorePaths (..))
import Simplex.Messaging.Server.MsgStore.Types (SMSType (..), SQSType (..))
import Simplex.Messaging.Server.Names
  ( NamesConfig (..),
    NamesEnv,
    TldRegistries (..),
    newNamesEnvWith,
  )
import Simplex.Messaging.Server.Names.Eth.RPC (EthRpcError (..))
import Simplex.Messaging.Transport
import Simplex.Messaging.Version (mkVersionRange)
import Test.Hspec hiding (fit, it)
import Util (it)

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------

unsafeOwner :: B.ByteString -> NameOwner
unsafeOwner = either error id . mkNameOwner

-- contract address configured in the server's TLD registry
serverContract :: NameOwner
serverContract = unsafeOwner (B.replicate 20 '\x11')

-- a different contract address (client points at the wrong one)
otherContract :: NameOwner
otherContract = unsafeOwner (B.replicate 20 '\x22')

-- 8 slots × 32 bytes, all zero — `decodeGetRecord` treats slot 1 (owner) as
-- the zero sentinel and returns `Right Nothing` → resolver maps to NotFound.
zeroOwnerAbi :: B.ByteString
zeroOwnerAbi = B.replicate (32 * 8) '\NUL'

stubNamesConfig :: TldRegistries -> NamesConfig
stubNamesConfig regs =
  NamesConfig
    { ethereumEndpoint = "http://stub",
      tldRegistries = regs,
      rpcAuth = Nothing,
      rpcTimeoutMs = 1000,
      rpcMaxResponseBytes = 65536,
      rpcMaxConcurrency = 4
    }

-- | Default stub: returns the all-zero ABI buffer. With the placeholder
-- decoder this collapses every lookup to `ResolveError.NotFound` → AUTH.
stubEthCallNotFound :: B.ByteString -> B.ByteString -> IO (Either EthRpcError B.ByteString)
stubEthCallNotFound _to _data = pure (Right zeroOwnerAbi)

-- | Stub that always raises a transport-layer error (e.g. operator pointed
-- at the wrong endpoint). Server should map to `ERR AUTH` via
-- `rslvEthErrs` selector. We use `BodyTooLarge` because `HttpFailure` wraps
-- an `HttpException` value which is not easily constructed in tests; both
-- map to `EthHttpErr` via `mapEthRpcError`.
stubEthCallHttpErr :: B.ByteString -> B.ByteString -> IO (Either EthRpcError B.ByteString)
stubEthCallHttpErr _to _data = pure (Left BodyTooLarge)

-- | Names env: TLDSimplex is configured with `serverContract`; TLDTesting and
-- TLDWeb (via tldAll) are unset, so they should fail at `verifyRslv`.
mkSimplexOnlyNamesEnv :: (B.ByteString -> B.ByteString -> IO (Either EthRpcError B.ByteString)) -> IO NamesEnv
mkSimplexOnlyNamesEnv eth =
  newNamesEnvWith
    (stubNamesConfig regs)
    eth
    Nothing
  where
    regs = TldRegistries {tldSimplex = Just serverContract, tldTesting = Nothing, tldAll = Nothing}

memCfg :: AServerConfig
memCfg = cfgMS (ASType SQSMemory SMSMemory)

memProxyCfg :: AServerConfig
memProxyCfg = proxyCfgMS (ASType SQSMemory SMSMemory)

-- | Second-server variant of `memCfg` that uses the `.2` store paths so it
-- can coexist with a first server using `memCfg` on the same machine
-- (StoreLog locks `testStoreLogFile`). `updateCfg` doesn't help here
-- because `serverStoreCfg` is GADT-typed; instead we override the field
-- directly inside the existential.
memCfg2 :: AServerConfig
memCfg2 = case memCfg of
  ASrvCfg qt mt c -> ASrvCfg qt mt c {serverStoreCfg = newStoreCfg (serverStoreCfg c)}
  where
    -- For SMSMemory the storeCfg is `SSCMemory (Maybe StorePaths)`; for any
    -- other store the original is kept unchanged.
    newStoreCfg :: ServerStoreCfg s -> ServerStoreCfg s
    newStoreCfg = \case
      SSCMemory _ -> SSCMemory (Just StorePaths {storeLogFile = testStoreLogFile2, storeMsgsFile = Just testStoreMsgsFile2})
      other -> other

-- | Run a single SMP server with stub `NamesEnv` on `testPort`.
withResolverServer :: NamesEnv -> IO a -> IO a
withResolverServer nenv =
  withSmpServerConfigOnWithNames (transport @TLS) memCfg testPort nenv . const

-- | Two-server setup for PFWD RSLV. Proxy on `testPort` (no NamesEnv —
-- proxy doesn't resolve locally); resolver on `testPort2` (stub NamesEnv).
withProxyAndResolver :: NamesEnv -> IO a -> IO a
withProxyAndResolver nenv runTest =
  withSmpServerConfigOn (transport @TLS) memProxyCfg testPort $ \_ ->
    withSmpServerConfigOnWithNames (transport @TLS) memCfg2 testPort2 nenv (const runTest)

-- ---------------------------------------------------------------------------
-- Direct-RSLV send/recv on a raw THandle
-- ---------------------------------------------------------------------------

-- RSLV is `noAuthCmd` (Protocol.hs:1974) — sent unsigned. Helper sends one
-- transmission and reads the single-element batched response.
sendRslv :: Transport c => THandleSMP c 'TClient -> B.ByteString -> RslvRequest -> IO (Transmission (Either ErrorType BrokerMsg))
sendRslv h@THandle {params} corrId req = do
  let TransmissionForAuth {tToSend} = encodeTransmissionForAuth params (CorrId corrId, NoEntity, Cmd SResolver (RSLV req))
  [Right ()] <- tPut h (Right (Nothing, tToSend) :| [])
  r :| _ <- tGetClient h
  pure r

-- ---------------------------------------------------------------------------
-- Tests
-- ---------------------------------------------------------------------------

rslvTests :: Spec
rslvTests = do
  describe "RSLV direct (non-forwarded)" $ do
    it "server accepts RSLV without PFWD (not CMD PROHIBITED)" testRslvDirectAccepted
    it "AUTH when contract address does not match TLD config" testRslvWrongContract
    it "AUTH when TLD has no contract configured" testRslvUnknownTld
    it "AUTH when backend reports zero owner (NotFound via placeholder decoder)" testRslvBackendNotFound
    it "AUTH when backend transport fails (EthHttpErr)" testRslvBackendHttpErr
    it "AUTH when server has no names config (namesEnv = Nothing)" testRslvDisabled
  describe "RSLV forwarded (PFWD)" $ do
    it "PFWD-wrapped RSLV reaches resolver via proxy (PCEProtocolError AUTH)" testRslvForwarded
  describe "RSLV success path (NAME response)" $ do
    it "returns NAME with NameRecord" $
      pendingWith
        "decodeGetRecord placeholder returns Right Nothing for all non-malformed inputs; \
        \re-enable when SNRC ABI codec ships (Server/Names/Eth/SNRC.hs:177-178)"

-- --- direct path -----------------------------------------------------------

testRslvDirectAccepted :: IO ()
testRslvDirectAccepted = do
  nenv <- mkSimplexOnlyNamesEnv stubEthCallNotFound
  withResolverServer nenv $
    testSMPClient @TLS $ \h -> do
      (corrId, _entId, resp) <- sendRslv h "rs01" RslvRequest {name = "alice.simplex", contract = serverContract}
      -- Placeholder decoder collapses zero-owner buffer to NotFound -> AUTH.
      -- The point of this test is that the server accepted RSLV at all
      -- (CMD PROHIBITED would mean the no-PFWD path was rejected).
      corrId `shouldBe` CorrId "rs01"
      resp `shouldBe` Right (ERR AUTH)

testRslvWrongContract :: IO ()
testRslvWrongContract = do
  nenv <- mkSimplexOnlyNamesEnv stubEthCallNotFound
  withResolverServer nenv $
    testSMPClient @TLS $ \h -> do
      -- contract mismatch is caught by `verifyRslv` before any ethCall.
      (_, _, resp) <- sendRslv h "rs02" RslvRequest {name = "alice.simplex", contract = otherContract}
      resp `shouldBe` Right (ERR AUTH)

testRslvUnknownTld :: IO ()
testRslvUnknownTld = do
  nenv <- mkSimplexOnlyNamesEnv stubEthCallNotFound
  withResolverServer nenv $
    testSMPClient @TLS $ \h -> do
      -- TLDTesting has no whitelist entry; verifyRslv -> Nothing -> AUTH.
      (_, _, resp) <- sendRslv h "rs03" RslvRequest {name = "bob.testing", contract = serverContract}
      resp `shouldBe` Right (ERR AUTH)

testRslvBackendNotFound :: IO ()
testRslvBackendNotFound = do
  nenv <- mkSimplexOnlyNamesEnv stubEthCallNotFound
  withResolverServer nenv $
    testSMPClient @TLS $ \h -> do
      (_, _, resp) <- sendRslv h "rs04" RslvRequest {name = "ghost.simplex", contract = serverContract}
      resp `shouldBe` Right (ERR AUTH)

testRslvBackendHttpErr :: IO ()
testRslvBackendHttpErr = do
  nenv <- mkSimplexOnlyNamesEnv stubEthCallHttpErr
  withResolverServer nenv $
    testSMPClient @TLS $ \h -> do
      (_, _, resp) <- sendRslv h "rs05" RslvRequest {name = "alice.simplex", contract = serverContract}
      -- EthHttpErr maps to ERR AUTH (rslvEthErrs selector).
      resp `shouldBe` Right (ERR AUTH)

testRslvDisabled :: IO ()
testRslvDisabled = do
  -- Default cfgMS sets `namesConfig = Nothing` and we do NOT inject an
  -- override -> server's `namesEnv = Nothing` -> RSLV returns AUTH via
  -- the `rslvDisabled` selector path.
  withSmpServerConfigOn (transport @TLS) memCfg testPort $ const $
    testSMPClient @TLS $ \h -> do
      (_, _, resp) <- sendRslv h "rs06" RslvRequest {name = "alice.simplex", contract = serverContract}
      resp `shouldBe` Right (ERR AUTH)

-- --- PFWD path -------------------------------------------------------------

testRslvForwarded :: IO ()
testRslvForwarded = do
  nenv <- mkSimplexOnlyNamesEnv stubEthCallNotFound
  withProxyAndResolver nenv $ do
    g <- C.newRandom
    ts <- getCurrentTime
    let proxyServ = SMPServer testHost testPort testKeyHash
        relayServ = SMPServer testHost2 testPort2 testKeyHash
        cfg' = defaultSMPClientConfig {serverVRange = mkVersionRange minServerSMPRelayVersion currentClientSMPRelayVersion}
    pcE <- getProtocolClient g NRMInteractive (1, proxyServ, Nothing) cfg' [] Nothing ts (\_ -> pure ())
    pc <- either (fail . show) pure pcE
    -- proxyCfgMS has no `newQueueBasicAuth`; PRXY with Nothing succeeds.
    sess <- runExceptT' (connectSMPProxiedRelay pc NRMInteractive relayServ Nothing)
    -- The destination relay replies ERR AUTH; proxy decodes and reports as
    -- `PCEProtocolError AUTH`; `proxyResolveName` lets that throwE propagate.
    r <- runExceptT (proxyResolveName pc NRMInteractive sess serverContract "alice.simplex")
    case r of
      Left (PCEProtocolError SMP.AUTH) -> pure ()
      _ -> expectationFailure $ "expected Left (PCEProtocolError AUTH), got: " <> show r

runExceptT' :: Show e => ExceptT e IO a -> IO a
runExceptT' a = runExceptT a >>= either (fail . show) pure
