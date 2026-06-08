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
-- Mocks the resolver at the `resolverCall` layer using `newNamesEnvWith`.
-- Tests:
--   * direct RSLV is accepted (not `CMD PROHIBITED`)
--   * `ERR AUTH` for malformed names (parseName layer)
--   * `ERR AUTH` for backend `NotFound` (404 / 400 from the HTTP resolver)
--   * `ERR AUTH` for backend transport errors (HTTP 502 or transport failure)
--   * `ERR AUTH` when the server has no `namesEnv` (rslvDisabled)
--   * `NAME` returned when the resolver returns a valid JSON record
--   * the same paths via PFWD round-trip (proxy + resolver wiring works)
module RSLVTests (rslvTests) where

import Control.Monad.Trans.Except (ExceptT, runExceptT)
import qualified Data.Aeson as J
import qualified Data.ByteString.Char8 as B
import Data.List.NonEmpty (NonEmpty (..))
import Data.Time.Clock (getCurrentTime)
import SMPClient
import Simplex.Messaging.Client
import qualified Simplex.Messaging.Crypto as C
import SMPNamesTests (sampleRecord, sampleRecordJSON)
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
    ResolverCall,
    ResolverCallKind (..),
    newNamesEnvWith,
  )
import Simplex.Messaging.Server.Names.HttpResolver (ResolverError (..))
import Simplex.Messaging.Transport
import Simplex.Messaging.Version (mkVersionRange)
import Test.Hspec hiding (fit, it)
import Util (it)

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------

unsafeOwner :: B.ByteString -> NameOwner
unsafeOwner = either error id . mkNameOwner

-- A placeholder contract used in RslvRequest. The server ignores the
-- contract field, so the value doesn't affect behaviour.
placeholderContract :: NameOwner
placeholderContract = unsafeOwner (B.replicate 20 '\NUL')

stubNamesConfig :: NamesConfig
stubNamesConfig =
  NamesConfig
    { resolverEndpoint = "http://stub",
      resolverAuth = Nothing,
      resolverTimeoutMs = 1000,
      resolverMaxResponseBytes = 65536
    }

-- | Default stub: the resolver replies 404. Server maps to NotFound -> AUTH.
stubResolverNotFound :: ResolverCall
stubResolverNotFound = \case
  ResolverFetch _ -> pure (Left (HttpStatusErr 404))
  ResolverHealth -> pure (Right (J.object []))

-- | Stub that returns a 502 upstream-RPC failure on resolve. Server maps to
-- ResolverError -> ERR AUTH via `rslvEthErrs`.
stubResolverHttpErr :: ResolverCall
stubResolverHttpErr = \case
  ResolverFetch _ -> pure (Left (HttpStatusErr 502))
  ResolverHealth -> pure (Right (J.object []))

-- | Stub returning a real NameRecord JSON value (success path).
stubResolverSuccess :: ResolverCall
stubResolverSuccess = \case
  ResolverFetch _ -> pure (Right sampleRecordJSON)
  ResolverHealth -> pure (Right (J.object []))

mkNamesEnv :: ResolverCall -> IO NamesEnv
mkNamesEnv stub = newNamesEnvWith stubNamesConfig stub Nothing

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

withResolverServer :: NamesEnv -> IO a -> IO a
withResolverServer nenv =
  withSmpServerConfigOnWithNames (transport @TLS) memCfg testPort nenv . const

withProxyAndResolver :: NamesEnv -> IO a -> IO a
withProxyAndResolver nenv runTest =
  withSmpServerConfigOn (transport @TLS) memProxyCfg testPort $ \_ ->
    withSmpServerConfigOnWithNames (transport @TLS) memCfg2 testPort2 nenv (const runTest)

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
    it "AUTH when name is malformed (bare label, no TLD)" testRslvBadName
    it "AUTH when resolver replies 404 (not registered)" testRslvBackendNotFound
    it "AUTH when resolver replies 502 (upstream failure)" testRslvBackendHttpErr
    it "AUTH when server has no names config (namesEnv = Nothing)" testRslvDisabled
  describe "RSLV forwarded (PFWD)" $ do
    it "PFWD-wrapped RSLV reaches resolver via proxy (PCEProtocolError AUTH)" testRslvForwarded
  describe "RSLV success path (NAME response)" $ do
    it "returns NAME with NameRecord" testRslvSuccess

testRslvDirectAccepted :: IO ()
testRslvDirectAccepted = do
  nenv <- mkNamesEnv stubResolverNotFound
  withResolverServer nenv $
    testSMPClient @TLS $ \h -> do
      (corrId, _entId, resp) <- sendRslv h "rs01" RslvRequest {name = "alice.simplex", contract = placeholderContract}
      corrId `shouldBe` CorrId "rs01"
      resp `shouldBe` Right (ERR AUTH)

testRslvBadName :: IO ()
testRslvBadName = do
  nenv <- mkNamesEnv stubResolverNotFound
  withResolverServer nenv $
    testSMPClient @TLS $ \h -> do
      (_, _, resp) <- sendRslv h "rs02" RslvRequest {name = "alice", contract = placeholderContract}
      resp `shouldBe` Right (ERR AUTH)

testRslvBackendNotFound :: IO ()
testRslvBackendNotFound = do
  nenv <- mkNamesEnv stubResolverNotFound
  withResolverServer nenv $
    testSMPClient @TLS $ \h -> do
      (_, _, resp) <- sendRslv h "rs04" RslvRequest {name = "ghost.simplex", contract = placeholderContract}
      resp `shouldBe` Right (ERR AUTH)

testRslvBackendHttpErr :: IO ()
testRslvBackendHttpErr = do
  nenv <- mkNamesEnv stubResolverHttpErr
  withResolverServer nenv $
    testSMPClient @TLS $ \h -> do
      (_, _, resp) <- sendRslv h "rs05" RslvRequest {name = "alice.simplex", contract = placeholderContract}
      resp `shouldBe` Right (ERR AUTH)

testRslvDisabled :: IO ()
testRslvDisabled =
  withSmpServerConfigOn (transport @TLS) memCfg testPort $ const $
    testSMPClient @TLS $ \h -> do
      (_, _, resp) <- sendRslv h "rs06" RslvRequest {name = "alice.simplex", contract = placeholderContract}
      resp `shouldBe` Right (ERR AUTH)

testRslvForwarded :: IO ()
testRslvForwarded = do
  nenv <- mkNamesEnv stubResolverNotFound
  withProxyAndResolver nenv $ do
    g <- C.newRandom
    ts <- getCurrentTime
    let proxyServ = SMPServer testHost testPort testKeyHash
        relayServ = SMPServer testHost2 testPort2 testKeyHash
        cfg' = defaultSMPClientConfig {serverVRange = mkVersionRange minServerSMPRelayVersion currentClientSMPRelayVersion}
    pcE <- getProtocolClient g NRMInteractive (1, proxyServ, Nothing) cfg' [] Nothing ts (\_ -> pure ())
    pc <- either (fail . show) pure pcE
    sess <- runExceptT' (connectSMPProxiedRelay pc NRMInteractive relayServ Nothing)
    r <- runExceptT (proxyResolveName pc NRMInteractive sess placeholderContract "alice.simplex")
    case r of
      Left (PCEProtocolError SMP.AUTH) -> pure ()
      _ -> expectationFailure $ "expected Left (PCEProtocolError AUTH), got: " <> show r

testRslvSuccess :: IO ()
testRslvSuccess = do
  nenv <- mkNamesEnv stubResolverSuccess
  withResolverServer nenv $
    testSMPClient @TLS $ \h -> do
      (corrId, _entId, resp) <- sendRslv h "rs07" RslvRequest {name = "alice.simplex", contract = placeholderContract}
      corrId `shouldBe` CorrId "rs07"
      case resp of
        Right (NAME nr) -> nr `shouldBe` sampleRecord
        _ -> expectationFailure $ "expected Right (NAME ..), got: " <> show resp

runExceptT' :: Show e => ExceptT e IO a -> IO a
runExceptT' a = runExceptT a >>= either (fail . show) pure
