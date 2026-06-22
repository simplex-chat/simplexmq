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
-- Runs a real local HTTP resolver (NamesResolverServer) and points the SMP
-- server's resolver_endpoint at it, so the full HttpResolver path is exercised.
-- Tests:
--   * direct RSLV reaches the resolver (not `CMD PROHIBITED`)
--   * `ERR (NAME NOT_FOUND)` for backend not-found (404 / 400)
--   * `ERR (NAME (RESOLVER ..))` for backend transport errors (HTTP 502)
--   * `ERR (NAME NO_RESOLVER)` when the server has no `namesEnv` (names off)
--   * `RNAME` returned when the resolver returns a valid JSON record
--   * the same paths via PFWD round-trip (proxy + resolver wiring works)
module RSLVTests (rslvTests) where

import Control.Monad.Trans.Except (ExceptT, runExceptT)
import qualified Data.Aeson as J
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy as LB
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text.Encoding (encodeUtf8)
import Data.Time.Clock (getCurrentTime)
import Network.HTTP.Types (Status, status200, status404, status502)
import NamesResolverServer (memCfg, memCfg2, memProxyCfg, withNames)
import qualified NamesResolverServer as NRS
import SMPClient
import Simplex.Messaging.Client
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding.String (strDecode)
import SMPNamesTests (sampleRecord)
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

-- | Run a local HTTP resolver (replying with the given status + body to every
-- /resolve) and an SMP server with names enabled pointing at it.
withResolverServer :: (Status, LB.ByteString) -> IO a -> IO a
withResolverServer (st, body) runTest =
  NRS.withResolverServer (NRS.resolveResp st body) $ \port _ ->
    withSmpServerConfigOn (transport @TLS) (withNames port memCfg) testPort (const runTest)

withProxyAndResolver :: (Status, LB.ByteString) -> IO a -> IO a
withProxyAndResolver (st, body) runTest =
  NRS.withResolverServer (NRS.resolveResp st body) $ \port _ ->
    withSmpServerConfigOn (transport @TLS) memProxyCfg testPort $ \_ ->
      withSmpServerConfigOn (transport @TLS) (withNames port memCfg2) testPort2 (const runTest)

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
    it "resolver replies 404 -> NAME NOT_FOUND (reached, not CMD PROHIBITED)" testRslvBackendNotFound
    it "resolver replies 502 -> NAME (RESOLVER ..)" testRslvBackendHttpErr
    it "no names config -> NAME NO_RESOLVER" testRslvDisabled
    it "refuses to send RSLV on a session below namesSMPVersion" testRslvVersionGate
  describe "RSLV forwarded (PFWD)" $ do
    it "PFWD-wrapped RSLV reaches resolver via proxy (PCEProtocolError (NAME NOT_FOUND))" testRslvForwarded
    it "PFWD-wrapped RSLV success returns RNAME (record JSON frames over the proxy)" testRslvForwardedSuccess
  describe "RSLV success path (RNAME response)" $ do
    it "returns RNAME with NameRecord" testRslvSuccess

testRslvBackendNotFound :: IO ()
testRslvBackendNotFound =
  withResolverServer (status404, "{}") $
    testSMPClient @TLS $ \h -> do
      (corrId, _entId, resp) <- sendRslv h "rs01" (domain "ghost.simplex")
      corrId `shouldBe` CorrId "rs01"
      resp `shouldBe` Right (ERR (NAME NOT_FOUND))

testRslvBackendHttpErr :: IO ()
testRslvBackendHttpErr =
  withResolverServer (status502, "{}") $
    testSMPClient @TLS $ \h -> do
      (_, _, resp) <- sendRslv h "rs05" (domain "alice.simplex")
      resp `shouldBe` Right (ERR (NAME (RESOLVER "HTTP 502")))

testRslvDisabled :: IO ()
testRslvDisabled =
  withSmpServerConfigOn (transport @TLS) memCfg testPort $ const $
    testSMPClient @TLS $ \h -> do
      (_, _, resp) <- sendRslv h "rs06" (domain "alice.simplex")
      resp `shouldBe` Right (ERR (NAME NO_RESOLVER))

-- The client must refuse to send RSLV on a session negotiated below
-- namesSMPVersion, surfacing TEVersion without contacting the resolver.
-- rcvServiceSMPVersion is the last version before names support.
testRslvVersionGate :: IO ()
testRslvVersionGate =
  withResolverServer (status200, J.encode sampleRecord) $ do
    g <- C.newRandom
    ts <- getCurrentTime
    let srv = SMPServer testHost testPort testKeyHash
        oldCfg = defaultSMPClientConfig {serverVRange = mkVersionRange minServerSMPRelayVersion rcvServiceSMPVersion}
    pcE <- getProtocolClient g NRMInteractive (1, srv, Nothing) oldCfg [] Nothing ts (\_ -> pure ())
    pc <- either (fail . show) pure pcE
    r <- runExceptT (directResolveName pc NRMInteractive (domain "alice.simplex"))
    case r of
      Left (PCETransportError TEVersion) -> pure ()
      _ -> expectationFailure $ "expected Left (PCETransportError TEVersion), got: " <> show r

-- Resolve "alice.simplex" through a proxy client + relay session against the
-- running proxy/relay servers, returning the raw proxied result.
forwardedResolveAlice :: IO (Either SMPClientError (Either ProxyClientError SMP.NameRecord))
forwardedResolveAlice = do
  g <- C.newRandom
  ts <- getCurrentTime
  let proxyServ = SMPServer testHost testPort testKeyHash
      relayServ = SMPServer testHost2 testPort2 testKeyHash
      cfg' = defaultSMPClientConfig {serverVRange = mkVersionRange minServerSMPRelayVersion currentClientSMPRelayVersion}
  pcE <- getProtocolClient g NRMInteractive (1, proxyServ, Nothing) cfg' [] Nothing ts (\_ -> pure ())
  pc <- either (fail . show) pure pcE
  sess <- runExceptT' (connectSMPProxiedRelay pc NRMInteractive relayServ Nothing)
  runExceptT (proxyResolveName pc NRMInteractive sess (domain "alice.simplex"))

testRslvForwarded :: IO ()
testRslvForwarded =
  withProxyAndResolver (status404, "{}") $
    forwardedResolveAlice >>= \r -> case r of
      Left (PCEProtocolError (SMP.NAME SMP.NOT_FOUND)) -> pure ()
      _ -> expectationFailure $ "expected Left (PCEProtocolError (NAME NOT_FOUND)), got: " <> show r

-- A successful RNAME over the proxy: exercises the resolver-record JSON framing
-- on the proxied (RRES, paddedProxiedTLength) response path, async on the relay.
testRslvForwardedSuccess :: IO ()
testRslvForwardedSuccess =
  withProxyAndResolver (status200, J.encode sampleRecord) $
    forwardedResolveAlice >>= \r -> case r of
      Right (Right nr) -> nr `shouldBe` sampleRecord
      _ -> expectationFailure $ "expected Right (Right NameRecord), got: " <> show r

testRslvSuccess :: IO ()
testRslvSuccess =
  withResolverServer (status200, J.encode sampleRecord) $
    testSMPClient @TLS $ \h -> do
      (corrId, _entId, resp) <- sendRslv h "rs07" (domain "alice.simplex")
      corrId `shouldBe` CorrId "rs07"
      case resp of
        Right (RNAME nr) -> nr `shouldBe` sampleRecord
        _ -> expectationFailure $ "expected Right (RNAME ..), got: " <> show resp

runExceptT' :: Show e => ExceptT e IO a -> IO a
runExceptT' a = runExceptT a >>= either (fail . show) pure
