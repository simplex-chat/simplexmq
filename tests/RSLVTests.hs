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
import qualified Data.Aeson as J
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy as LB
import qualified Data.Map.Strict as M
import Data.IORef (IORef, readIORef)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text.Encoding (encodeUtf8)
import Data.Time.Clock (getCurrentTime)
import Network.HTTP.Types (Status, status200, status404, status410, status502)
import NamesResolverServer (memCfg, memCfg2, memProxyCfg, withNames)
import qualified NamesResolverServer as NRS
import SMPClient
import Simplex.Messaging.Client
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding.String (strDecode)
import SMPNamesTests (testNameRecord)
import Simplex.Messaging.Protocol
  ( BrokerMsg (..),
    Cmd (..),
    Command (..),
    CorrId (..),
    ErrorType (..),
    NamePricing (..),
    NameRegistration (..),
    NameReservedReason (..),
    USDCents (..),
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
import Simplex.Messaging.SystemTime (RoundedSystemTime (..))
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
  let TransmissionForAuth {tToSend} = encodeTransmissionForAuth params (CorrId corrId, NoEntity, Cmd SResolver (RSLV (SMP.nameQuery currentClientSMPRelayVersion d)))
  [Right ()] <- tPut h (Right (Nothing, tToSend) :| [])
  r :| _ <- tGetClient h
  pure r

rslvTests :: Spec
rslvTests = do
  describe "RSLV direct (non-forwarded)" $ do
    it "resolver replies 404 -> NAME NOT_FOUND (reached, not CMD PROHIBITED)" testRslvBackendNotFound
    it "resolver replies 410 -> NAME NOT_FOUND (a lapsed name, not a resolver failure)" testRslvBackendGone
    it "resolver replies 502 -> NAME (RESOLVER ..)" testRslvBackendHttpErr
    it "no names config -> NAME NO_RESOLVER" testRslvDisabled
    it "refuses to send RSLV on a session below namesSMPVersion" testRslvVersion
  describe "RSLV forwarded (PFWD)" $ do
    it "PFWD-wrapped RSLV reaches resolver via proxy (PCEProtocolError (NAME NOT_FOUND))" testRslvForwarded
    it "PFWD-wrapped RSLV success returns RNAME (record JSON frames over the proxy)" testRslvForwardedSuccess
  describe "RSLV success path (RNAME response)" $ do
    it "returns RNAME with NameRecord" testRslvSuccess
  describe "RSLV availability (RNAME response)" $ do
    it "unregistered comes back AVAILABLE" testRslvAvailable
    it "auction comes back with premium" testRslvAuction
    it "reserved comes back with the reason" testRslvReserved
    it "PFWD-wrapped auction reaches the resolver" testRslvForwardedAuction
  describe "RSLV below v22" $ do
    it "still resolves a name to its record" testRslvOldClientRecord
    it "still answers NAME NOT_FOUND for a name that does not resolve" testRslvOldClientNotFound
  describe "hashed lookups" $ do
    it "RSLV sends the 2LD as its hash" testRslvSendsTheHash
    it "subname labels stay text" testSubnameKeepsItsLabels

testRslvBackendNotFound :: IO ()
testRslvBackendNotFound =
  withResolverServer (status404, "{}") $
    testSMPClient @TLS $ \h -> do
      (corrId, _entId, resp) <- sendRslv h "rs01" (domain "ghost.simplex")
      corrId `shouldBe` CorrId "rs01"
      resp `shouldBe` Right (ERR (NAME NOT_FOUND))

testRslvBackendGone :: IO ()
testRslvBackendGone =
  withResolverServer (status410, "{}") $
    testSMPClient @TLS $ \h -> do
      (_, _, resp) <- sendRslv h "rs08" (domain "lapsed.simplex")
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

testRslvVersion :: IO ()
testRslvVersion =
  withResolverServer (status200, J.encode testNameRecord) $ do
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

forwardedResolveAlice :: IO (Either SMPClientError (Either ProxyClientError SMP.NameRegistration))
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

testRslvForwardedSuccess :: IO ()
testRslvForwardedSuccess =
  withProxyAndResolver (status200, J.encode testNameRecord) $
    forwardedResolveAlice >>= \r -> case r of
      Right (Right NRRegistered {nameRecord}) -> nameRecord `shouldBe` testNameRecord
      _ -> expectationFailure $ "expected Right (Right NRRegistered), got: " <> show r

testRslvSuccess :: IO ()
testRslvSuccess =
  withResolverServer (status200, J.encode testNameRecord) $
    testSMPClient @TLS $ \h -> do
      (corrId, _entId, resp) <- sendRslv h "rs07" (domain "alice.simplex")
      corrId `shouldBe` CorrId "rs07"
      case resp of
        Right (RNAME NRRegistered {nameRecord}) -> nameRecord `shouldBe` testNameRecord
        _ -> expectationFailure $ "expected Right (RNAME NRRegistered), got: " <> show resp

testRslvAvailable :: IO ()
testRslvAvailable =
  withResolverServer (status404, availableBody) $
    testSMPClient @TLS $ \h -> do
      (corrId, _entId, resp) <- sendRslv h "na01" (domain "ghost.simplex")
      corrId `shouldBe` CorrId "na01"
      resp `shouldBe` Right (RNAME (NRAvailable auctionPricing Nothing))

testRslvAuction :: IO ()
testRslvAuction =
  withResolverServer (status410, auctionBody) $
    testSMPClient @TLS $ \h -> do
      (_, _, resp) <- sendRslv h "na02" (domain "lapsed.simplex")
      resp `shouldBe` Right (RNAME (NRAvailable auctionPricing (Just (RoundedSystemTime 1790294400))))

testRslvReserved :: IO ()
testRslvReserved =
  withResolverServer (status404, "{\"error\":\"unregistered\",\"reasonCode\":\"trademark\"}") $
    testSMPClient @TLS $ \h -> do
      (_, _, resp) <- sendRslv h "na03" (domain "acme.simplex")
      resp `shouldBe` Right (RNAME (NRReserved NRRTrademark))

-- | A client that predates v22 must see exactly what it saw before: the record
-- for a name that resolves, and NOT_FOUND for one that does not.
oldClient :: IO SMPClient
oldClient = do
  g <- C.newRandom
  ts <- getCurrentTime
  let srv = SMPServer testHost testPort testKeyHash
      -- the version just below the gate: a lower ceiling would also pass for a
      -- gate at 20 or 21 and prove nothing about v22
      oldCfg = defaultSMPClientConfig {serverVRange = mkVersionRange minServerSMPRelayVersion serverInfoSMPVersion}
  pcE <- getProtocolClient g NRMInteractive (1, srv, Nothing) oldCfg [] Nothing ts (\_ -> pure ())
  either (fail . show) pure pcE

testRslvOldClientRecord :: IO ()
testRslvOldClientRecord =
  withResolverServer (status200, J.encode testNameRecord) $ do
    pc <- oldClient
    r <- runExceptT' (directResolveName pc NRMInteractive (domain "alice.simplex"))
    r `shouldBe` NRRegistered Nothing Nothing Nothing testNameRecord

testRslvOldClientNotFound :: IO ()
testRslvOldClientNotFound =
  withResolverServer (status404, availableBody) $ do
    pc <- oldClient
    r <- runExceptT (directResolveName pc NRMInteractive (domain "alice.simplex"))
    case r of
      Left (PCEProtocolError (SMP.NAME SMP.NOT_FOUND)) -> pure ()
      _ -> expectationFailure $ "expected Left (PCEProtocolError (NAME NOT_FOUND)), got: " <> show r

testRslvForwardedAuction :: IO ()
testRslvForwardedAuction =
  withProxyAndResolver (status410, auctionBody) $
    forwardedResolveAlice >>= \r -> case r of
      Right (Right (NRAvailable _ auctionUntil)) -> auctionUntil `shouldBe` Just (RoundedSystemTime 1790294400)
      _ -> expectationFailure $ "expected Right (Right NRAvailable), got: " <> show r

pricingJson :: LB.ByteString
pricingJson = "\"rentPrices\":{\"3\":12793,\"4\":3198},\"basePrice\":100,\"minLabelLength\":3"

availableBody :: LB.ByteString
availableBody = "{\"error\":\"unregistered\"," <> pricingJson <> "}"

-- a name past its grace period, still inside the window where it costs a
-- surcharge above the ordinary price
auctionBody :: LB.ByteString
auctionBody = "{\"error\":\"expired\",\"auctionUntil\":1790294400," <> pricingJson <> "}"

auctionPricing :: NamePricing
auctionPricing =
  NamePricing
    { rentPrices = M.fromList [(3, USDCents 12793), (4, USDCents 3198)],
      basePrice = USDCents 100,
      minLabelLength = 3
    }

-- keccak-256("alice"), the registry key
aliceHash :: Text
aliceHash = "[9c0257114eb9399a2985f8e75dad7600c5d89fe3824ffa99ec1c3eb8bf3b0501]"

-- | A current client must never put a registrable name on the wire.
resolvePaths :: IORef [[Text]] -> IO [[Text]]
resolvePaths reqs = filter isResolve <$> readIORef reqs
  where
    isResolve = \case ("resolve" : _) -> True; _ -> False

currentClient :: IO SMPClient
currentClient = do
  g <- C.newRandom
  ts <- getCurrentTime
  let srv = SMPServer testHost testPort testKeyHash
  pcE <- getProtocolClient g NRMInteractive (1, srv, Nothing) defaultSMPClientConfig [] Nothing ts (\_ -> pure ())
  either (fail . show) pure pcE

testRslvSendsTheHash :: IO ()
testRslvSendsTheHash =
  withResolverServerReqs (status200, J.encode testNameRecord) $ \reqs -> do
    pc <- currentClient
    r <- runExceptT' (directResolveName pc NRMInteractive (domain "alice.simplex"))
    resolvePaths reqs `shouldReturn` [["resolve", aliceHash <> ".simplex"]]
    -- the client never sent the name, and the record still names it: the
    -- registrar records the label at registration, keyed by its own hash
    case r of
      NRRegistered {nameRecord} -> SMP.nrName nameRecord `shouldBe` "alice.simplex"
      _ -> expectationFailure $ "expected NRRegistered, got: " <> show r

testSubnameKeepsItsLabels :: IO ()
testSubnameKeepsItsLabels =
  withResolverServerReqs (status404, availableBody) $ \reqs -> do
    pc <- currentClient
    _ <- runExceptT' (directResolveName pc NRMInteractive (domain "x.alice.simplex"))
    resolvePaths reqs `shouldReturn` [["resolve", "x." <> aliceHash <> ".simplex"]]

runExceptT' :: Show e => ExceptT e IO a -> IO a
runExceptT' a = runExceptT a >>= either (fail . show) pure
