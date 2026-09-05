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
import Network.HTTP.Types (status200, status400, status404, status410, status500, status502)
import NamesResolverServer (resolveResp, testNamesConfig, withResolverServer, withResolverServerDelayed)
import Simplex.Messaging.Encoding (smpDecode, smpEncode)
import Simplex.Messaging.Encoding.String (strDecode, strEncode)
import Simplex.Messaging.Protocol (NameAvailability (..), ErrorType (..), NameErrorType (..), NameRecord (..), NameReservedReason (..))
import Simplex.Messaging.Server.Main (validateUrl)
import Simplex.Messaging.Server.Names
  ( NamesConfig (..),
    RpcAuth (..),
    nameAvailability,
    newNamesEnv,
    pingEndpoint,
    resolveName,
  )
import Simplex.Messaging.Server.Names.HttpResolver (ResolverError (..))
import Simplex.Messaging.SimplexName (SimplexDomain (..), SimplexTLD (..), fullDomainName, hashedDomain)
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
  describe "Name parsing (SimplexDomain)" parseNameSpec
  describe "HTTP resolver" resolverSpec
  describe "name availability" availabilitySpec
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

availabilitySpec :: Spec
availabilitySpec = do
  it "a name nobody has taken is available" $
    answers status404 "{\"error\":\"unregistered\"}" NAVailable
  it "a lapsed name past the auction is available at the usual price" $
    answers status410 "{\"error\":\"expired\"}" NAVailable
  it "a lapsed name still in grace says when its owner loses it" $
    answers status410 "{\"error\":\"grace\",\"graceEnds\":1796377221}" (NAInGrace 1796377221)
  it "a name in the auction after grace carries its premium and deadline" $
    answers
      status410
      "{\"error\":\"auction\",\"premium\":\"99999952316384526016153087\",\"auctionEnds\":1798191621}"
      (NAAuction "99999952316384526016153087" 1798191621)
  it "a reserved name says why it is held back" $
    answers status404 "{\"error\":\"reserved\",\"reasonCode\":\"trademark\"}" (NAReserved NRTrademark)
  it "a reserved name with no reason recorded is still reserved" $
    answers status404 "{\"error\":\"reserved\"}" (NAReserved NRUnspecified)
  it "a reason this server does not know does not lose the reservation" $
    answers status404 "{\"error\":\"reserved\",\"reasonCode\":\"astrology\"}" (NAReserved NRUnspecified)
  it "a live registration is taken, and says until when" $
    answers status200 "{\"status\":\"registered\",\"expires\":1811232000}" (NATaken (Just 1811232000))
  it "a registration whose expiry could not be read is still taken" $
    answers status200 "{\"status\":\"registered\",\"expires\":null}" (NATaken Nothing)
  -- quoting the usual price for a name that costs a premium is the one wrong
  -- answer here, so an answer missing its payload withholds the name instead
  it "grace without its deadline is reported as taken" $
    answers status410 "{\"error\":\"grace\"}" (NATaken Nothing)
  it "an auction without its price is reported as taken" $
    answers status410 "{\"error\":\"auction\",\"auctionEnds\":1798191621}" (NATaken Nothing)
  it "a registered name whose records point nowhere is still taken" $
    answers status404 "{\"error\":\"noResolver\",\"expires\":1811232000}" (NATaken (Just 1811232000))
  -- a price is a 256-bit integer in decimal; the wire length-prefixes it with one
  -- byte, so a longer or non-numeric string is dropped rather than re-encoded
  it "a premium too long to encode is not quoted" $
    answers status410 (jsonBody ("{\"error\":\"auction\",\"premium\":\"" <> replicate 300 '9' <> "\",\"auctionEnds\":1798191621}")) (NATaken Nothing)
  it "a premium that is not a decimal integer is not quoted" $
    answers status410 "{\"error\":\"auction\",\"premium\":\"1e26\",\"auctionEnds\":1798191621}" (NATaken Nothing)
  -- a resolver that could not answer must not be reported as an answer: saying
  -- TAKEN would assert a registration nobody read, and NOT_FOUND would read as
  -- "no such name, therefore free"
  it "an upstream RPC failure is a resolver error, not a taken name" $
    refuses status502 "{\"error\":\"upstreamError\"}" (RESOLVER "upstreamError")
  it "a TLD this resolver has no registry for is a resolver error" $
    refuses status400 "{\"error\":\"tldNotConfigured\"}" (RESOLVER "tldNotConfigured")
  it "a TLD with no registrar, so status could not be read, is a resolver error" $
    refuses status200 "{\"status\":\"unknown\",\"expires\":null}" (RESOLVER "unknown")
  it "a body that is not the resolver's JSON is never NOT_FOUND" $
    refuses status404 "<html>gateway</html>" (RESOLVER "HTTP 404")
  it "a body past the configured cap is a resolver error" $
    withResolverServer (resolveResp status200 (jsonBody ("{\"status\":\"registered\",\"pad\":\"" <> replicate 400 'x' <> "\"}"))) $ \port _ -> do
      env <- newNamesEnv (testNamesConfig port) {resolverMaxResponseBytes = 200}
      nameAvailability env navlDomain `shouldReturn` Left (RESOLVER "response too large")
  it "every answer survives the wire" $
    mapM_
      (\a -> smpDecode (smpEncode a) `shouldBe` Right a)
      [ NAVailable,
        NATaken (Just 1811232000),
        NATaken Nothing,
        NAInGrace 1796377221,
        NAAuction "99999952316384526016153087" 1798191621,
        NAReserved NRUnspecified,
        NAReserved NRTrademark,
        NAReserved NRPublicInterest,
        NAReserved NROffensive,
        NAReserved NRInternal,
        NAReserved NRPremium
      ]
  where
    jsonBody = LB.fromStrict . B.pack
    answers st body expected = asks_ st body (Right expected)
    refuses st body err = asks_ st body (Left err)
    asks_ st body expected =
      withResolverServer (resolveResp st body) $ \port _ -> do
        env <- newNamesEnv (testNamesConfig port)
        nameAvailability env navlDomain `shouldReturn` expected
    navlDomain = SimplexDomain {nameTLD = TLDSimplex, domain = "alice", subDomain = []}

parseNameSpec :: Spec
parseNameSpec = do
  -- asking by hash is how a client learns whether a name is taken without
  -- saying which name it is asking about
  it "accepts a labelhash label" $
    parseN ("[" <> T.replicate 64 "b" <> "].simplex") `shouldSatisfy` isRight
  it "refuses a hash of the wrong width" $
    parseN ("[" <> T.replicate 63 "b" <> "].simplex") `shouldSatisfy` isLeft
  -- the resolver keys the registry on the bracketed form only; a bare hex string
  -- would be hashed again as if it were a name, answering about a different key
  it "refuses a bare hex string in place of a labelhash" $
    parseN ("0x" <> T.replicate 64 "b" <> ".simplex") `shouldSatisfy` isLeft
  it "keeps the brackets, which are what the resolver reads as a hash" $
    (strEncode <$> parseN ("[" <> T.replicate 64 "b" <> "].simplex"))
      `shouldBe` Right (encodeUtf8 ("[" <> T.replicate 64 "b" <> "].simplex"))
  -- only the second-level label is a registry key, so only it may be hashed;
  -- a subname label is needed as text to reach the record
  it "accepts a hashed second-level label under a subname" $
    parseN ("x.[" <> T.replicate 64 "b" <> "].simplex") `shouldSatisfy` isRight
  it "refuses a hashed subname label" $
    parseN ("[" <> T.replicate 64 "b" <> "].alice.simplex") `shouldSatisfy` isLeft
  it "refuses a labelhash under a web TLD, which has no registry" $
    parseN ("[" <> T.replicate 64 "b" <> "].com") `shouldSatisfy` isLeft
  -- the hash the client sends must be the one the resolver keys on: this is
  -- keccak-256("alice"), the same constant the resolver's own tests use
  it "hashes the second-level label to the registry key" $
    (fullDomainName . hashedDomain <$> parseN "alice.simplex")
      `shouldBe` Right "[9c0257114eb9399a2985f8e75dad7600c5d89fe3824ffa99ec1c3eb8bf3b0501].simplex"
  it "leaves subname labels as text" $
    (fullDomainName . hashedDomain <$> parseN "x.alice.simplex")
      `shouldBe` Right "x.[9c0257114eb9399a2985f8e75dad7600c5d89fe3824ffa99ec1c3eb8bf3b0501].simplex"
  it "leaves a web name alone, as it has no registry to key into" $
    (fullDomainName . hashedDomain <$> parseN "example.com") `shouldBe` Right "example.com"
  it "does not hash a name that is already a hash" $
    (fullDomainName . hashedDomain . hashedDomain <$> parseN "alice.simplex")
      `shouldBe` Right "[9c0257114eb9399a2985f8e75dad7600c5d89fe3824ffa99ec1c3eb8bf3b0501].simplex"
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
    parseN :: T.Text -> Either String SimplexDomain
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

  it "returns NOT_FOUND on 410 (registration lapsed)" $
    withResolverServer (resolveResp status410 "{}") $ \port _ -> do
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
    aliceDomain = SimplexDomain {nameTLD = TLDSimplex, domain = "alice", subDomain = []}

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
