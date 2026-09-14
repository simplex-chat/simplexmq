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

module RSLVTests (rslvTests) where

import Control.Monad.Trans.Except (ExceptT, runExceptT)
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy as LB
import Data.IORef (IORef, readIORef)
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
import SMPNamesTests (availableBody, registeredBody, reservedBody, resolved, testNameRecord, testPricing)
import Simplex.Messaging.Protocol
  ( BrokerMsg (..),
    Cmd (..),
    Command (..),
    CorrId (..),
    ErrorType (..),
    NameQuery (..),
    NameRegistration (..),
    NameResponse (..),
    NameErrorType (..),
    NameReservedReason (..),
    SParty (..),
    Transmission,
    TransmissionForAuth (..),
    encodeTransmissionForAuth,
    pattern SMPServer,
    tGetClient,
    tPut,
  )
import qualified Simplex.Messaging.Protocol as SMP
import Simplex.Messaging.SimplexName (SimplexDomain)
import Simplex.Messaging.Transport
import Simplex.Messaging.Version (mkVersionRange)
import Test.Hspec hiding (fit, it)
import Util (it)

domain :: Text -> SimplexDomain
domain = either error id . strDecode . encodeUtf8

withResolverServer :: (Status, LB.ByteString) -> IO a -> IO a
withResolverServer (st, body) runTest =
  NRS.withResolverServer (NRS.resolveResp st body) $ \port _ ->
    withSmpServerConfigOn (transport @TLS) (withNames port memCfg) testPort (const runTest)

withResolverServerReqs :: (Status, LB.ByteString) -> (IORef [[Text]] -> IO a) -> IO a
withResolverServerReqs (st, body) runTest =
  NRS.withResolverServer (NRS.resolveResp st body) $ \port reqs ->
    withSmpServerConfigOn (transport @TLS) (withNames port memCfg) testPort (const (runTest reqs))

withProxyAndResolver :: (Status, LB.ByteString) -> IO a -> IO a
withProxyAndResolver (st, body) runTest =
  NRS.withResolverServer (NRS.resolveResp st body) $ \port _ ->
    withSmpServerConfigOn (transport @TLS) memProxyCfg testPort $ \_ ->
      withSmpServerConfigOn (transport @TLS) (withNames port memCfg2) testPort2 (const runTest)

sendRslv :: Transport c => THandleSMP c 'TClient -> B.ByteString -> SimplexDomain -> IO (Transmission (Either ErrorType BrokerMsg))
sendRslv h@THandle {params} corrId d = do
  let TransmissionForAuth {tToSend} = encodeTransmissionForAuth params (CorrId corrId, NoEntity, Cmd SResolver (RSLV (NQDomain d)))
  [Right ()] <- tPut h (Right (Nothing, tToSend) :| [])
  r :| _ <- tGetClient h
  pure r

rslvTests :: Spec
rslvTests = do
  describe "RSLV direct (non-forwarded)" $ do
    it "resolver without the v2 route (404) -> NAME RESOLVER, not NOT_FOUND" testRslvBackendNotFound
    it "resolver replies 502 -> NAME (RESOLVER ..)" testRslvBackendHttpErr
    it "no names config -> NAME NO_RESOLVER" testRslvDisabled
    it "refuses to send RSLV on a session below namesSMPVersion" testRslvVersion
  describe "RSLV forwarded (PFWD)" $ do
    it "PFWD-wrapped RSLV reaches resolver via proxy (PCEProtocolError (NAME RESOLVER))" testRslvForwarded
    it "PFWD-wrapped RSLV success returns RNAME (record JSON frames over the proxy)" testRslvForwardedSuccess
  describe "RSLV success path (RNAME response)" $ do
    it "returns RNAME with NameRecord" testRslvSuccess
  describe "RSLV availability (RNAME response)" $ do
    it "unregistered comes back AVAILABLE" testRslvAvailable
    it "reserved comes back with the reason" testRslvReserved
    it "PFWD-wrapped availability reaches the resolver" testRslvForwardedAvailable
  describe "RSLV below v22" $ do
    it "still resolves a name to its record" testRslvOldClientRecord
    it "still answers NAME NOT_FOUND for a name that does not resolve" testRslvOldClientNotFound
  describe "hashed lookups" $ do
    it "RSLV sends the 2LD as its hash" testRslvSendsTheHash
    it "a name with subnames is sent as text" testSubnameKeepsItsLabels
    it "a record naming a different name is rejected" testRslvWrongName

-- | /v2/resolve answers 200, 400 or 502, so a 404 is a resolver that predates
-- the route, not a name that does not exist.
testRslvBackendNotFound :: IO ()
testRslvBackendNotFound =
  withResolverServer (status404, "{}") $
    testSMPClient @TLS $ \h -> do
      (corrId, _entId, resp) <- sendRslv h "rs01" (domain "ghost.simplex")
      corrId `shouldBe` CorrId "rs01"
      resp `shouldBe` Right (ERR (NAME (RESOLVER "HTTP 404")))

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

testRslvVersion :: IO ()
testRslvVersion =
  withResolverServer (status200, registeredBody testNameRecord) $ do
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

forwardedResolveAlice :: IO (Either SMPClientError (Either ProxyClientError SMP.NameResponse))
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
      Left (PCEProtocolError (SMP.NAME (SMP.RESOLVER _))) -> pure ()
      _ -> expectationFailure $ "expected Left (PCEProtocolError (NAME (RESOLVER _))), got: " <> show r

testRslvForwardedSuccess :: IO ()
testRslvForwardedSuccess =
  withProxyAndResolver (status200, registeredBody testNameRecord) $
    forwardedResolveAlice >>= \r -> case r of
      Right (Right NameResponse {registration = NRRegistered {nameRecord}}) -> nameRecord `shouldBe` testNameRecord
      _ -> expectationFailure $ "expected Right (Right NRRegistered), got: " <> show r

testRslvSuccess :: IO ()
testRslvSuccess =
  withResolverServer (status200, registeredBody testNameRecord) $
    testSMPClient @TLS $ \h -> do
      (corrId, _entId, resp) <- sendRslv h "rs07" (domain "alice.simplex")
      corrId `shouldBe` CorrId "rs07"
      case resp of
        Right (RNAME NameResponse {registration = NRRegistered {nameRecord}}) -> nameRecord `shouldBe` testNameRecord
        _ -> expectationFailure $ "expected Right (RNAME NRRegistered), got: " <> show resp

testRslvAvailable :: IO ()
testRslvAvailable =
  withResolverServer (status200, availableBody) $
    testSMPClient @TLS $ \h -> do
      (corrId, _entId, resp) <- sendRslv h "na01" (domain "ghost.simplex")
      corrId `shouldBe` CorrId "na01"
      resp `shouldBe` Right (RNAME (resolved (NRAvailable testPricing)))

testRslvReserved :: IO ()
testRslvReserved =
  withResolverServer (status200, reservedBody) $
    testSMPClient @TLS $ \h -> do
      (_, _, resp) <- sendRslv h "na03" (domain "acme.simplex")
      resp `shouldBe` Right (RNAME (resolved (NRReserved NRRTrademark)))

-- | A client that predates v22 must see exactly what it saw before: the record
-- for a name that resolves, and NOT_FOUND for one that does not.
oldClient :: IO SMPClient
oldClient = do
  g <- C.newRandom
  ts <- getCurrentTime
  let srv = SMPServer testHost testPort testKeyHash
      -- the version just below the gate: a lower ceiling would pass even if
      -- the gate were at 20 or 21
      oldCfg = defaultSMPClientConfig {serverVRange = mkVersionRange minServerSMPRelayVersion serverInfoSMPVersion}
  pcE <- getProtocolClient g NRMInteractive (1, srv, Nothing) oldCfg [] Nothing ts (\_ -> pure ())
  either (fail . show) pure pcE

testRslvOldClientRecord :: IO ()
testRslvOldClientRecord =
  withResolverServer (status200, registeredBody testNameRecord) $ do
    pc <- oldClient
    r <- runExceptT' (directResolveName pc NRMInteractive (domain "alice.simplex"))
    r `shouldBe` NameResponse Nothing (NRRegistered Nothing Nothing Nothing testNameRecord)

testRslvOldClientNotFound :: IO ()
testRslvOldClientNotFound =
  withResolverServer (status200, availableBody) $ do
    pc <- oldClient
    r <- runExceptT (directResolveName pc NRMInteractive (domain "alice.simplex"))
    case r of
      Left (PCEProtocolError (SMP.NAME SMP.NOT_FOUND)) -> pure ()
      _ -> expectationFailure $ "expected Left (PCEProtocolError (NAME NOT_FOUND)), got: " <> show r

testRslvForwardedAvailable :: IO ()
testRslvForwardedAvailable =
  withProxyAndResolver (status200, availableBody) $
    forwardedResolveAlice >>= \r -> case r of
      Right (Right NameResponse {registration = NRAvailable {pricing}}) -> pricing `shouldBe` testPricing
      _ -> expectationFailure $ "expected Right (Right NRAvailable), got: " <> show r

-- keccak-256("alice"), the registry key
aliceHash :: Text
aliceHash = "[9c0257114eb9399a2985f8e75dad7600c5d89fe3824ffa99ec1c3eb8bf3b0501]"

-- | The paths the client asked the resolver for.
resolvePaths :: IORef [[Text]] -> IO [[Text]]
resolvePaths reqs = filter isResolve <$> readIORef reqs
  where
    isResolve = \case ("v2" : "resolve" : _) -> True; _ -> False

currentClient :: IO SMPClient
currentClient = do
  g <- C.newRandom
  ts <- getCurrentTime
  let srv = SMPServer testHost testPort testKeyHash
  pcE <- getProtocolClient g NRMInteractive (1, srv, Nothing) defaultSMPClientConfig [] Nothing ts (\_ -> pure ())
  either (fail . show) pure pcE

testRslvSendsTheHash :: IO ()
testRslvSendsTheHash =
  withResolverServerReqs (status200, registeredBody testNameRecord) $ \reqs -> do
    pc <- currentClient
    r <- runExceptT' (directResolveName pc NRMInteractive (domain "alice.simplex"))
    resolvePaths reqs `shouldReturn` [["v2", "resolve", aliceHash <> ".simplex"]]
    -- the client never sent the name, and the record still names it
    case r of
      NameResponse {registration = NRRegistered {nameRecord}} -> SMP.nrName nameRecord `shouldBe` "alice.simplex"
      _ -> expectationFailure $ "expected NRRegistered, got: " <> show r

testSubnameKeepsItsLabels :: IO ()
testSubnameKeepsItsLabels =
  withResolverServerReqs (status200, availableBody) $ \reqs -> do
    pc <- currentClient
    _ <- runExceptT' (directResolveName pc NRMInteractive (domain "x.alice.simplex"))
    resolvePaths reqs `shouldReturn` [["v2", "resolve", "x.alice.simplex"]]

-- a hashed query does not tell the router the name, so the record's own name is
-- checked against the one that was asked for
testRslvWrongName :: IO ()
testRslvWrongName =
  withResolverServer (status200, registeredBody testNameRecord {SMP.nrName = "mallory.simplex"}) $ do
    pc <- currentClient
    r <- runExceptT (directResolveName pc NRMInteractive (domain "alice.simplex"))
    case r of
      Left (PCEUnexpectedResponse _) -> pure ()
      _ -> expectationFailure $ "expected Left (PCEUnexpectedResponse ..), got: " <> show r

runExceptT' :: Show e => ExceptT e IO a -> IO a
runExceptT' a = runExceptT a >>= either (fail . show) pure
