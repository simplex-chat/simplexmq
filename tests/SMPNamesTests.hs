{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module SMPNamesTests (smpNamesTests, testNameRecord) where

import qualified Data.Aeson as J
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy as LB
import Data.Either (isLeft, isRight)
import Data.IORef (readIORef)
import Data.List (sort)
import qualified Data.Text as T
import Data.Text.Encoding (encodeUtf8)
import Network.HTTP.Types (status200, status400, status404, status500, status502)
import NamesResolverServer (resolveResp, testNamesConfig, withResolverServer, withResolverServerDelayed)
import Simplex.Messaging.Encoding (smpDecode, smpEncode)
import Simplex.Messaging.Encoding.String (strDecode)
import Simplex.Messaging.Protocol (ErrorType (..), NameErrorType (..), NameRecord (..))
import Simplex.Messaging.Server.Main (validateUrl)
import Simplex.Messaging.Server.Names
  ( NamesConfig (..),
    RpcAuth (..),
    newNamesEnv,
    pingEndpoint,
    resolveName,
  )
import Simplex.Messaging.Server.Names.HttpResolver (ResolverError (..))
import Simplex.Messaging.SimplexName (SimplexNameDomain (..), SimplexTLD (..))
import Test.Hspec

testNameRecord :: NameRecord
testNameRecord =
  NameRecord
    { nrName = "alice.simplex",
      nrNickname = "Alice",
      nrWebsite = "https://alice.example",
      nrLocation = "Earth",
      nrSimplexContact = ["simplex:/contact/abc#xyz"],
      nrSimplexChannel = [],
      nrEth = Just "0x0000000000000000000000000000000000000001",
      nrBtc = Nothing,
      nrXmr = Nothing,
      nrDot = Nothing,
      nrOwner = "0x0101010101010101010101010101010101010101",
      nrResolver = "0x0202020202020202020202020202020202020202"
    }

smpNamesTests :: Spec
smpNamesTests = do
  describe "NameRecord JSON (Protocol)" nameRecordEncodingSpec
  describe "ErrorType NAME wire encoding" errorWireSpec
  describe "Name parsing (SimplexNameDomain)" parseNameSpec
  describe "HTTP resolver" resolverSpec
  describe "Resolver health probe" healthSpec
  describe "resolver_endpoint validation" validateUrlSpec

nameRecordEncodingSpec :: Spec
nameRecordEncodingSpec = do
  it "round-trips JSON encode / decode" $
    J.eitherDecodeStrict (LB.toStrict (J.encode testNameRecord)) `shouldBe` Right testNameRecord

  it "emits keys in spec-documented order (resolver shape)" $ do
    let bytes = LB.toStrict (J.encode testNameRecord)
        offset k = B.length (fst (B.breakSubstring k bytes))
        offsets =
          map
            offset
            [ "name",
              "nickname",
              "website",
              "location",
              "simplexContact",
              "simplexChannel",
              "eth",
              "btc",
              "xmr",
              "dot",
              "owner",
              "resolver"
            ]
    offsets `shouldBe` sort offsets

  it "emits unset coin fields as null (not absent)" $ do
    let bytes = LB.toStrict (J.encode testNameRecord)
    B.isInfixOf "\"btc\":null" bytes `shouldBe` True
    B.isInfixOf "\"xmr\":null" bytes `shouldBe` True
    B.isInfixOf "\"dot\":null" bytes `shouldBe` True

  it "emits unset link fields as empty arrays (not null)" $ do
    let bytes = LB.toStrict (J.encode testNameRecord)
    B.isInfixOf "\"simplexChannel\":[]" bytes `shouldBe` True
    B.isInfixOf "\"simplexChannel\":null" bytes `shouldBe` False

errorWireSpec :: Spec
errorWireSpec =
  it "ErrorType NAME family round-trips smpEncode / smpDecode" $ do
    smpDecode (smpEncode (NAME NO_RESOLVER)) `shouldBe` Right (NAME NO_RESOLVER)
    smpDecode (smpEncode (NAME NOT_FOUND)) `shouldBe` Right (NAME NOT_FOUND)
    -- RESOLVER detail may contain spaces - must survive the round-trip
    smpDecode (smpEncode (NAME (RESOLVER "HTTP 502"))) `shouldBe` Right (NAME (RESOLVER "HTTP 502"))

parseNameSpec :: Spec
parseNameSpec = do
  it "accepts a valid simplex-TLD name" $
    case parseN "privacy.simplex" of
      Right d -> do
        nameTLD d `shouldBe` TLDSimplex
        domain d `shouldBe` "privacy"
      Left e -> expectationFailure ("expected Right, got Left " <> e)

  it "normalises case across labels (Alice.SIMPLEX = alice.simplex)" $
    parseN "alice.simplex" `shouldBe` parseN "Alice.SIMPLEX"

  it "accepts a testing-TLD name" $
    case parseN "bob.testing" of
      Right d -> nameTLD d `shouldBe` TLDTesting
      Left e -> expectationFailure ("expected Right, got Left " <> e)

  it "accepts a TLDWeb name (server forwards to resolver, which will likely 404/400)" $
    parseN "example.com" `shouldSatisfy` isRight

  it "rejects a bare (no-TLD) name" $
    parseN "privacy" `shouldSatisfy` isLeft

  it "rejects non-ASCII labels (homograph attacks)" $
    parseN "\1072lice.simplex" `shouldSatisfy` isLeft

  it "rejects oversized inputs (>253 bytes)" $
    parseN (T.replicate 254 "a" <> ".simplex") `shouldSatisfy` isLeft

  it "rejects a label longer than 63 bytes (DNS label limit)" $
    parseN (T.replicate 64 "a" <> ".simplex") `shouldSatisfy` isLeft

  it "accepts a label of exactly 63 bytes" $
    parseN (T.replicate 63 "a" <> ".simplex") `shouldSatisfy` isRight
  where
    parseN :: T.Text -> Either String SimplexNameDomain
    parseN = strDecode . encodeUtf8

resolverSpec :: Spec
resolverSpec = do
  it "returns NameRecord on 200 OK" $
    withResolverServer (resolveResp status200 (J.encode testNameRecord)) $ \port _ -> do
      env <- newNamesEnv (testNamesConfig port)
      resolveName env aliceDomain `shouldReturn` Right testNameRecord

  it "returns NOT_FOUND on 404" $
    withResolverServer (resolveResp status404 "{}") $ \port _ -> do
      env <- newNamesEnv (testNamesConfig port)
      resolveName env aliceDomain `shouldReturn` Left NOT_FOUND

  it "returns NOT_FOUND on 400 (unknown TLD)" $
    withResolverServer (resolveResp status400 "{}") $ \port _ -> do
      env <- newNamesEnv (testNamesConfig port)
      resolveName env aliceDomain `shouldReturn` Left NOT_FOUND

  it "returns RESOLVER on 502 (upstream failure)" $
    withResolverServer (resolveResp status502 "{}") $ \port _ -> do
      env <- newNamesEnv (testNamesConfig port)
      resolveName env aliceDomain `shouldReturn` Left (RESOLVER "HTTP 502")

  it "returns RESOLVER when the body exceeds the response cap" $
    withResolverServer (resolveResp status200 (LB.fromStrict (B.replicate 500 'x'))) $ \port _ -> do
      env <- newNamesEnv (testNamesConfig port) {resolverMaxResponseBytes = 100}
      resolveName env aliceDomain `shouldReturn` Left (RESOLVER "response too large")

  it "returns RESOLVER on malformed JSON from the resolver" $
    withResolverServer (resolveResp status200 "this is not json") $ \port _ -> do
      env <- newNamesEnv (testNamesConfig port)
      resolveName env aliceDomain `shouldReturn` Left (RESOLVER "invalid response")

  it "returns RESOLVER when JSON parses but isn't a NameRecord shape" $
    withResolverServer (resolveResp status200 "{}") $ \port _ -> do
      env <- newNamesEnv (testNamesConfig port)
      resolveName env aliceDomain `shouldReturn` Left (RESOLVER "invalid response")

  it "returns RESOLVER (timeout) when the resolver is slower than resolverTimeoutMs" $
    withResolverServerDelayed 1500 (resolveResp status200 (J.encode testNameRecord)) $ \port _ -> do
      env <- newNamesEnv (testNamesConfig port) {resolverTimeoutMs = 300}
      resolveName env aliceDomain `shouldReturn` Left (RESOLVER "timeout")

  it "sends one HTTP request per lookup (no cache)" $
    withResolverServer (resolveResp status200 (J.encode testNameRecord)) $ \port reqs -> do
      env <- newNamesEnv (testNamesConfig port)
      _ <- resolveName env aliceDomain
      _ <- resolveName env aliceDomain
      readIORef reqs >>= \rs -> length rs `shouldBe` 2

  it "addresses the resolver with the full canonical domain name" $
    withResolverServer (resolveResp status200 (J.encode testNameRecord)) $ \port reqs -> do
      env <- newNamesEnv (testNamesConfig port)
      _ <- resolveName env aliceDomain
      readIORef reqs `shouldReturn` [["resolve", "alice.simplex"]]

  where
    aliceDomain = SimplexNameDomain {nameTLD = TLDSimplex, domain = "alice", subDomain = []}

healthSpec :: Spec
healthSpec = do
  it "pingEndpoint succeeds on a 200 OK /health response" $
    withResolverServer (resolveResp status200 "{}") $ \port _ -> do
      env <- newNamesEnv (testNamesConfig port)
      pingEndpoint env >>= \case
        Right () -> pure ()
        Left e -> expectationFailure $ "expected Right (), got Left " <> show e

  it "pingEndpoint fails on a 500 /health response" $
    withResolverServer healthFails $ \port _ -> do
      env <- newNamesEnv (testNamesConfig port)
      pingEndpoint env >>= \case
        Left (HttpStatusErr 500) -> pure ()
        r -> expectationFailure $ "expected Left (HttpStatusErr 500), got " <> show r

  it "pingEndpoint queries /health" $
    withResolverServer (resolveResp status200 "{}") $ \port reqs -> do
      env <- newNamesEnv (testNamesConfig port)
      _ <- pingEndpoint env
      readIORef reqs `shouldReturn` [["health"]]
  where
    healthFails = \case
      ["health"] -> (status500, "{}")
      _ -> (status404, "{}")

validateUrlSpec :: Spec
validateUrlSpec = do
  it "accepts an https URL with a path prefix" $
    validateUrl "https://gw.example.com:443/snrc" Nothing `shouldSatisfy` isRight
  it "accepts an http URL" $
    validateUrl "http://127.0.0.1:8000" Nothing `shouldSatisfy` isRight
  it "accepts a URL without an explicit port" $
    validateUrl "https://gw.example.com/snrc" Nothing `shouldSatisfy` isRight
  it "rejects a relative / non-absolute URI" $
    validateUrl "gw.example.com/snrc" Nothing `shouldSatisfy` isLeft
  it "rejects a non-http(s) scheme" $
    validateUrl "ftp://gw.example.com:21" Nothing `shouldSatisfy` isLeft
  it "rejects an empty host" $
    validateUrl "http://" Nothing `shouldSatisfy` isLeft
  it "accepts https with auth (Authorization is TLS-protected)" $
    validateUrl "https://gw.example.com" (Just auth) `shouldSatisfy` isRight
  it "accepts loopback http with auth (no cleartext exposure)" $
    validateUrl "http://localhost:8000" (Just auth) `shouldSatisfy` isRight
  it "rejects non-loopback http with auth (cleartext credential leak)" $
    validateUrl "http://gw.example.com:8000" (Just auth) `shouldSatisfy` isLeft
  it "rejects URL-embedded userinfo (credentials belong in resolver_auth)" $
    validateUrl "https://user:pass@gw.example.com" Nothing `shouldSatisfy` isLeft
  it "rejects http+auth to a 127.-prefixed non-loopback host (not real loopback)" $
    validateUrl "http://127.evil.com:8000" (Just auth) `shouldSatisfy` isLeft
  where
    auth = AuthBasic "user" "pass"
