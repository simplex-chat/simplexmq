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
    NameAvailability (..),
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

withProxyAndResolver :: (Status, LB.ByteString) -> IO a -> IO a
withProxyAndResolver (st, body) runTest =
  NRS.withResolverServer (NRS.resolveResp st body) $ \port _ ->
    withSmpServerConfigOn (transport @TLS) memProxyCfg testPort $ \_ ->
      withSmpServerConfigOn (transport @TLS) (withNames port memCfg2) testPort2 (const runTest)

sendRslv :: Transport c => THandleSMP c 'TClient -> B.ByteString -> SimplexDomain -> IO (Transmission (Either ErrorType BrokerMsg))
sendRslv h@THandle {params} corrId d = do
  let TransmissionForAuth {tToSend} = encodeTransmissionForAuth params (CorrId corrId, NoEntity, Cmd SResolver (RSLV d))
  [Right ()] <- tPut h (Right (Nothing, tToSend) :| [])
  r :| _ <- tGetClient h
  pure r

sendNavl :: Transport c => THandleSMP c 'TClient -> B.ByteString -> SimplexDomain -> IO (Transmission (Either ErrorType BrokerMsg))
sendNavl h@THandle {params} corrId d = do
  let TransmissionForAuth {tToSend} = encodeTransmissionForAuth params (CorrId corrId, NoEntity, Cmd SResolver (NAVL d))
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
  describe "NAVL (availability)" $ do
    it "a name nobody has taken comes back AVAILABLE" testNavlAvailable
    it "a lapsed name in its auction comes back with the premium and deadline" testNavlAuction
    it "a reserved name comes back with the reason it is held back" testNavlReserved
    it "no names config -> NAME NO_RESOLVER" testNavlDisabled
    it "refuses to send NAVL on a session below nameAvailSMPVersion" testNavlVersion
    it "PFWD-wrapped NAVL reaches the resolver via the proxy" testNavlForwarded

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

testRslvForwardedSuccess :: IO ()
testRslvForwardedSuccess =
  withProxyAndResolver (status200, J.encode testNameRecord) $
    forwardedResolveAlice >>= \r -> case r of
      Right (Right nr) -> nr `shouldBe` testNameRecord
      _ -> expectationFailure $ "expected Right (Right NameRecord), got: " <> show r

testRslvSuccess :: IO ()
testRslvSuccess =
  withResolverServer (status200, J.encode testNameRecord) $
    testSMPClient @TLS $ \h -> do
      (corrId, _entId, resp) <- sendRslv h "rs07" (domain "alice.simplex")
      corrId `shouldBe` CorrId "rs07"
      case resp of
        Right (RNAME nr) -> nr `shouldBe` testNameRecord
        _ -> expectationFailure $ "expected Right (RNAME ..), got: " <> show resp

testNavlAvailable :: IO ()
testNavlAvailable =
  withResolverServer (status404, "{\"error\":\"unregistered\"}") $
    testSMPClient @TLS $ \h -> do
      (corrId, _entId, resp) <- sendNavl h "na01" (domain "ghost.simplex")
      corrId `shouldBe` CorrId "na01"
      resp `shouldBe` Right (NAVAIL NAVailable)

testNavlAuction :: IO ()
testNavlAuction =
  withResolverServer (status410, auctionBody) $
    testSMPClient @TLS $ \h -> do
      (_, _, resp) <- sendNavl h "na02" (domain "lapsed.simplex")
      resp `shouldBe` Right (NAVAIL (NAAuction "99999952316384526016153087" 1798191621))

testNavlReserved :: IO ()
testNavlReserved =
  withResolverServer (status404, "{\"error\":\"reserved\",\"reasonCode\":\"trademark\"}") $
    testSMPClient @TLS $ \h -> do
      (_, _, resp) <- sendNavl h "na03" (domain "acme.simplex")
      resp `shouldBe` Right (NAVAIL (NAReserved NRTrademark))

testNavlDisabled :: IO ()
testNavlDisabled =
  withSmpServerConfigOn (transport @TLS) memCfg testPort $ const $
    testSMPClient @TLS $ \h -> do
      (_, _, resp) <- sendNavl h "na04" (domain "alice.simplex")
      resp `shouldBe` Right (ERR (NAME NO_RESOLVER))

testNavlVersion :: IO ()
testNavlVersion =
  withResolverServer (status404, "{\"error\":\"unregistered\"}") $ do
    g <- C.newRandom
    ts <- getCurrentTime
    let srv = SMPServer testHost testPort testKeyHash
        oldCfg = defaultSMPClientConfig {serverVRange = mkVersionRange minServerSMPRelayVersion rcvServiceSMPVersion}
    pcE <- getProtocolClient g NRMInteractive (1, srv, Nothing) oldCfg [] Nothing ts (\_ -> pure ())
    pc <- either (fail . show) pure pcE
    r <- runExceptT (directNameAvailability pc NRMInteractive (domain "alice.simplex"))
    case r of
      Left (PCETransportError TEVersion) -> pure ()
      _ -> expectationFailure $ "expected Left (PCETransportError TEVersion), got: " <> show r

testNavlForwarded :: IO ()
testNavlForwarded =
  withProxyAndResolver (status410, auctionBody) $ do
    g <- C.newRandom
    ts <- getCurrentTime
    let proxyServ = SMPServer testHost testPort testKeyHash
        relayServ = SMPServer testHost2 testPort2 testKeyHash
        cfg' = defaultSMPClientConfig {serverVRange = mkVersionRange minServerSMPRelayVersion currentClientSMPRelayVersion}
    pcE <- getProtocolClient g NRMInteractive (1, proxyServ, Nothing) cfg' [] Nothing ts (\_ -> pure ())
    pc <- either (fail . show) pure pcE
    sess <- runExceptT' (connectSMPProxiedRelay pc NRMInteractive relayServ Nothing)
    r <- runExceptT (proxyNameAvailability pc NRMInteractive sess (domain "lapsed.simplex"))
    case r of
      Right (Right a) -> a `shouldBe` NAAuction "99999952316384526016153087" 1798191621
      _ -> expectationFailure $ "expected Right (Right NAAuction ..), got: " <> show r

-- a name one day past its grace period, priced by the .testing auction curve
auctionBody :: LB.ByteString
auctionBody = "{\"error\":\"auction\",\"premium\":\"99999952316384526016153087\",\"auctionEnds\":1798191621}"

runExceptT' :: Show e => ExceptT e IO a -> IO a
runExceptT' a = runExceptT a >>= either (fail . show) pure
