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
-- Mocks the resolver at the `resolverCall` layer: tests set a stub via
-- `ServerConfig.namesResolverCall_` (no real HTTP, no startup probe).
-- Tests:
--   * direct RSLV reaches the resolver (not `CMD PROHIBITED`)
--   * `ERR (NAME NO_NAME)` for backend not-found (404 / 400)
--   * `ERR (NAME (RESOLVER ..))` for backend transport errors (HTTP 502)
--   * `ERR (NAME NO_RESOLVER)` when the server has no `namesEnv` (names off)
--   * `RNAME` returned when the resolver returns a valid JSON record
--   * the same paths via PFWD round-trip (proxy + resolver wiring works)
module RSLVTests (rslvTests) where

import Control.Monad.Trans.Except (ExceptT, runExceptT)
import qualified Data.Aeson as J
import qualified Data.ByteString.Char8 as B
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text.Encoding (encodeUtf8)
import Data.Time.Clock (getCurrentTime)
import SMPClient
import Simplex.Messaging.Client
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding.String (strDecode)
import SMPNamesTests (sampleRecord, sampleRecordJSON)
import Simplex.Messaging.Protocol
  ( BrokerMsg (..),
    Cmd (..),
    Command (..),
    CorrId (..),
    ErrorType (..),
    NameErrorType (..),
    SParty (..),
    Transmission,
    TransmissionForAuth (..),
    encodeTransmissionForAuth,
    pattern SMPServer,
    tGetClient,
    tPut,
  )
import qualified Simplex.Messaging.Protocol as SMP
import Simplex.Messaging.Server.Env.STM (AStoreType (..), ServerConfig (..), ServerStoreCfg (..), StorePaths (..))
import Simplex.Messaging.Server.MsgStore.Types (SMSType (..), SQSType (..))
import Simplex.Messaging.Server.Names
  ( NamesConfig (..),
    ResolverCall,
    ResolverCallKind (..),
  )
import Simplex.Messaging.Server.Names.HttpResolver (ResolverError (..))
import Simplex.Messaging.SimplexName (SimplexNameDomain)
import Simplex.Messaging.Transport
import Simplex.Messaging.Version (mkVersionRange)
import Test.Hspec hiding (fit, it)
import Util (it)

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------

-- | Build a validated SimplexNameDomain from a name string (the RSLV command
-- only carries a parsed domain; invalid names cannot be constructed here -
-- that rejection is tested at the SimplexName parse level).
domain :: Text -> SimplexNameDomain
domain = either error id . strDecode . encodeUtf8

stubNamesConfig :: NamesConfig
stubNamesConfig =
  NamesConfig
    { resolverEndpoint = "http://stub",
      resolverAuth = Nothing,
      resolverTimeoutMs = 1000,
      resolverMaxResponseBytes = 65536
    }

-- | Default stub: the resolver replies 404. Server maps to NAME NO_NAME.
stubResolverNotFound :: ResolverCall
stubResolverNotFound = \case
  ResolverFetch _ -> pure (Left (HttpStatusErr 404))
  ResolverHealth -> pure (Right (J.object []))

-- | Stub that returns a 502 upstream failure on resolve. Server maps to
-- NAME (RESOLVER "HTTP 502").
stubResolverHttpErr :: ResolverCall
stubResolverHttpErr = \case
  ResolverFetch _ -> pure (Left (HttpStatusErr 502))
  ResolverHealth -> pure (Right (J.object []))

-- | Stub returning a real NameRecord JSON value (success path).
stubResolverSuccess :: ResolverCall
stubResolverSuccess = \case
  ResolverFetch _ -> pure (Right sampleRecordJSON)
  ResolverHealth -> pure (Right (J.object []))

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

-- | Enable names on a config with a stub resolver (no real HTTP, no probe).
withNames :: ResolverCall -> AServerConfig -> AServerConfig
withNames stub c = updateCfg c $ \cfg_ -> cfg_ {namesConfig = Just stubNamesConfig, namesResolverCall_ = Just stub}

withResolverServer :: ResolverCall -> IO a -> IO a
withResolverServer stub = withSmpServerConfigOn (transport @TLS) (withNames stub memCfg) testPort . const

withProxyAndResolver :: ResolverCall -> IO a -> IO a
withProxyAndResolver stub runTest =
  withSmpServerConfigOn (transport @TLS) memProxyCfg testPort $ \_ ->
    withSmpServerConfigOn (transport @TLS) (withNames stub memCfg2) testPort2 (const runTest)

sendRslv :: Transport c => THandleSMP c 'TClient -> B.ByteString -> SimplexNameDomain -> IO (Transmission (Either ErrorType BrokerMsg))
sendRslv h@THandle {params} corrId d = do
  let TransmissionForAuth {tToSend} = encodeTransmissionForAuth params (CorrId corrId, NoEntity, Cmd SResolver (RSLV d))
  [Right ()] <- tPut h (Right (Nothing, tToSend) :| [])
  r :| _ <- tGetClient h
  pure r

-- ---------------------------------------------------------------------------
-- Tests
-- ---------------------------------------------------------------------------

rslvTests :: Spec
rslvTests = do
  describe "RSLV direct (non-forwarded)" $ do
    it "resolver replies 404 -> NAME NO_NAME (reached, not CMD PROHIBITED)" testRslvBackendNotFound
    it "resolver replies 502 -> NAME (RESOLVER ..)" testRslvBackendHttpErr
    it "no names config -> NAME NO_RESOLVER" testRslvDisabled
  describe "RSLV forwarded (PFWD)" $ do
    it "PFWD-wrapped RSLV reaches resolver via proxy (PCEProtocolError (NAME NO_NAME))" testRslvForwarded
  describe "RSLV success path (RNAME response)" $ do
    it "returns RNAME with NameRecord" testRslvSuccess

testRslvBackendNotFound :: IO ()
testRslvBackendNotFound =
  withResolverServer stubResolverNotFound $
    testSMPClient @TLS $ \h -> do
      (corrId, _entId, resp) <- sendRslv h "rs01" (domain "ghost.simplex")
      corrId `shouldBe` CorrId "rs01"
      resp `shouldBe` Right (ERR (NAME NO_NAME))

testRslvBackendHttpErr :: IO ()
testRslvBackendHttpErr =
  withResolverServer stubResolverHttpErr $
    testSMPClient @TLS $ \h -> do
      (_, _, resp) <- sendRslv h "rs05" (domain "alice.simplex")
      resp `shouldBe` Right (ERR (NAME (RESOLVER "HTTP 502")))

testRslvDisabled :: IO ()
testRslvDisabled =
  withSmpServerConfigOn (transport @TLS) memCfg testPort $ const $
    testSMPClient @TLS $ \h -> do
      (_, _, resp) <- sendRslv h "rs06" (domain "alice.simplex")
      resp `shouldBe` Right (ERR (NAME NO_RESOLVER))

testRslvForwarded :: IO ()
testRslvForwarded =
  withProxyAndResolver stubResolverNotFound $ do
    g <- C.newRandom
    ts <- getCurrentTime
    let proxyServ = SMPServer testHost testPort testKeyHash
        relayServ = SMPServer testHost2 testPort2 testKeyHash
        cfg' = defaultSMPClientConfig {serverVRange = mkVersionRange minServerSMPRelayVersion currentClientSMPRelayVersion}
    pcE <- getProtocolClient g NRMInteractive (1, proxyServ, Nothing) cfg' [] Nothing ts (\_ -> pure ())
    pc <- either (fail . show) pure pcE
    sess <- runExceptT' (connectSMPProxiedRelay pc NRMInteractive relayServ Nothing)
    r <- runExceptT (proxyResolveName pc NRMInteractive sess (domain "alice.simplex"))
    case r of
      Left (PCEProtocolError (SMP.NAME SMP.NO_NAME)) -> pure ()
      _ -> expectationFailure $ "expected Left (PCEProtocolError (NAME NO_NAME)), got: " <> show r

testRslvSuccess :: IO ()
testRslvSuccess =
  withResolverServer stubResolverSuccess $
    testSMPClient @TLS $ \h -> do
      (corrId, _entId, resp) <- sendRslv h "rs07" (domain "alice.simplex")
      corrId `shouldBe` CorrId "rs07"
      case resp of
        Right (RNAME nr) -> nr `shouldBe` sampleRecord
        _ -> expectationFailure $ "expected Right (RNAME ..), got: " <> show resp

runExceptT' :: Show e => ExceptT e IO a -> IO a
runExceptT' a = runExceptT a >>= either (fail . show) pure
