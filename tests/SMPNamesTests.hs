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
import qualified Data.Map.Strict as M
import qualified Data.Text as T
import Data.Text.Encoding (encodeUtf8)
import Network.HTTP.Types (status200, status400, status404, status410, status500, status502)
import NamesResolverServer (resolveResp, testNamesConfig, withResolverServer, withResolverServerDelayed)
import Simplex.Messaging.Encoding (smpDecode, smpEncode)
import Simplex.Messaging.Encoding.String (strDecode, strEncode)
import Simplex.Messaging.Protocol (ErrorType (..), NameErrorType (..), NamePricing (..), NameRecord (..), NameRegistration (..), NameReservedReason (..), USDCents (..), nameQuery, queryName)
import Simplex.Messaging.Server.Main (validateUrl)
import Simplex.Messaging.Server.Names
  ( NamesConfig (..),
    RpcAuth (..),
    newNamesEnv,
    pingEndpoint,
    resolveName,
  )
import Simplex.Messaging.Server.Names.HttpResolver (ResolverError (..))
import Simplex.Messaging.SimplexName (SimplexDomain (..), SimplexTLD (..), fullDomainName)
import Simplex.Messaging.SystemTime (RoundedSystemTime (..))
import Simplex.Messaging.Transport (currentClientSMPRelayVersion, namesSMPVersion)
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
  -- one lookup answers what the name points to, whether it can be taken, and
  -- whether the registry holds it back
  it "a registered name answers with its record and dates" $
    answers status200 (recordWith "\"status\":\"registered\",\"expires\":1813853483,\"graceEnds\":1821629483") $
      NRRegistered {expires = Just (RoundedSystemTime 1813853483), graceUntil = Just (RoundedSystemTime 1821629483), reservedReason_ = Nothing, nameRecord = testNameRecord}
  -- the record travels through grace: the UI decides how long to keep opening it
  it "a name in grace keeps its record" $
    answers status200 (recordWith "\"status\":\"grace\",\"expires\":1785000000,\"graceEnds\":1792776000") $
      NRRegistered {expires = Just (RoundedSystemTime 1785000000), graceUntil = Just (RoundedSystemTime 1792776000), reservedReason_ = Nothing, nameRecord = testNameRecord}
  -- reservation is orthogonal: it is why the name will not free up at expiry
  it "a registered name can be held back too" $
    answers status200 (recordWith "\"status\":\"registered\",\"expires\":1813853483,\"graceEnds\":1821629483,\"reasonCode\":\"internal\"") $
      NRRegistered {expires = Just (RoundedSystemTime 1813853483), graceUntil = Just (RoundedSystemTime 1821629483), reservedReason_ = Just NRRInternal, nameRecord = testNameRecord}
  -- an older resolver reports no status; the record is still the answer
  it "a resolver that sends no status still answers with the record" $
    answers status200 (J.encode testNameRecord) $
      NRRegistered {expires = Nothing, graceUntil = Nothing, reservedReason_ = Nothing, nameRecord = testNameRecord}
  it "an unregistered name answers with the price" $
    answers status404 (jsonBody ("{\"error\":\"unregistered\"," <> pricingJson <> "}")) $
      NRAvailable {pricing = testPricing, auctionUntil = Nothing}
  it "expired is available, counting down to the ordinary price" $
    answers status410 (jsonBody ("{\"error\":\"expired\",\"auctionUntil\":1790294400," <> pricingJson <> "}")) $
      NRAvailable {pricing = testPricing, auctionUntil = Just (RoundedSystemTime 1790294400)}
  -- a held-back name is not for sale at the registry's price
  it "reserved carries the reason and no price" $
    answers status404 (jsonBody ("{\"error\":\"unregistered\",\"reasonCode\":\"trademark\"," <> pricingJson <> "}")) $
      NRReserved NRRTrademark
  -- a later version may reserve names for reasons this one cannot name; the
  -- reservation must survive that, or a client would offer a name it cannot get
  it "a reason from a later version still reserves the name" $
    answers status404 "{\"error\":\"unregistered\",\"reasonCode\":\"seasonal\"}" (NRReserved (NRRUnknown "seasonal"))
  -- the reason re-encodes into a slot that ends at a space, so the router keeps
  -- it to one bounded token rather than trusting the resolver's text
  it "a reason with a space is cut at the space" $
    answers status404 "{\"error\":\"unregistered\",\"reasonCode\":\"two words\"}" (NRReserved (NRRUnknown "two"))
  it "an over-long reason is truncated" $
    answers status404 (jsonBody ("{\"error\":\"unregistered\",\"reasonCode\":\"" <> replicate 100 'z' <> "\"}")) $
      NRReserved (NRRUnknown (T.replicate 32 "z"))
  -- a name that cannot be dated or priced is not one this router reports on
  it "a registration without expiry is a resolver error" $
    refuses status200 (recordWith "\"status\":\"registered\"") (RESOLVER "no expiry")
  it "a registered name without a record is a resolver error" $
    refuses status404 "{\"error\":\"registered\",\"expires\":1813853483,\"graceEnds\":1821629483}" (RESOLVER "no record")
  it "no price oracle is a resolver error" $
    refuses status404 "{\"error\":\"unregistered\"}" (RESOLVER "no price oracle")
  it "upstream failure is a resolver error" $
    refuses status502 "{\"error\":\"upstreamError\"}" (RESOLVER "upstreamError")
  it "unconfigured TLD is a resolver error" $
    refuses status400 "{\"error\":\"tldNotConfigured\"}" (RESOLVER "tldNotConfigured")
  it "unreadable status is a resolver error" $
    refuses status404 "{\"error\":\"unknown\"}" (RESOLVER "unknown")
  it "long status is truncated" $
    refuses status502 (jsonBody ("{\"error\":\"" <> replicate 400 'e' <> "\"}")) (RESOLVER (T.replicate 32 "e"))
  -- a body the router cannot read is the pre-v22 answer, unchanged: NOT_FOUND
  -- says the router has nothing to say, never that the name is registrable
  it "unreadable 404 body stays NOT_FOUND" $
    refuses status404 "<html>gateway</html>" NOT_FOUND
  it "over-cap body is a resolver error" $
    withResolverServer (resolveResp status200 (jsonBody ("{\"status\":\"registered\",\"pad\":\"" <> replicate 400 'x' <> "\"}"))) $ \port _ -> do
      env <- newNamesEnv (testNamesConfig port) {resolverMaxResponseBytes = 200}
      resolveName env navlDomain `shouldReturn` Left (RESOLVER "response too large")
  it "every registration survives the wire" $
    mapM_
      (\a -> smpDecode (smpEncode a) `shouldBe` Right a)
      [ NRRegistered {expires = Just (RoundedSystemTime 1813853483), graceUntil = Just (RoundedSystemTime 1821629483), reservedReason_ = Nothing, nameRecord = testNameRecord},
        NRRegistered {expires = Nothing, graceUntil = Nothing, reservedReason_ = Just NRRInternal, nameRecord = testNameRecord},
        NRAvailable {pricing = testPricing, auctionUntil = Nothing},
        NRAvailable {pricing = testPricing, auctionUntil = Just (RoundedSystemTime 1790294400)},
        NRReserved NRRInternal,
        NRReserved NRRTrademark,
        NRReserved NRRCommunity,
        NRReserved (NRRUnknown "seasonal")
      ]
  -- one vocabulary: the same word on the wire, from the resolver, and in JSON
  it "a reason reads the same in JSON as on the wire" $ do
    J.encode (NRRUnknown "seasonal") `shouldBe` "\"seasonal\""
    J.encode NRRTrademark `shouldBe` "\"trademark\""
  where
    jsonBody = LB.fromStrict . B.pack
    -- the resolver returns the record and the registration status in one body
    recordWith extra = LB.init (J.encode testNameRecord) <> "," <> extra <> "}"
    answers st body a = resolverSays st body (Right a)
    refuses st body e = resolverSays st body (Left e)
    resolverSays st body expected =
      withResolverServer (resolveResp st body) $ \port _ -> do
        env <- newNamesEnv (testNamesConfig port)
        resolveName env navlDomain `shouldReturn` expected
    navlDomain = nameQuery namesSMPVersion SimplexDomain {nameTLD = TLDSimplex, domain = "alice", subDomain = []}

-- | The .testing oracle: US cents per year by label length.
testPricing :: NamePricing
testPricing =
  NamePricing
    { rentPrices = M.fromList [(3, USDCents 12793), (4, USDCents 3198)],
      basePrice = USDCents 100,
      minLabelLength = 3
    }

pricingJson :: String
pricingJson = "\"rentPrices\":{\"3\":12793,\"4\":3198},\"basePrice\":100,\"minLabelLength\":3"

parseNameSpec :: Spec
parseNameSpec = do
  -- a name is a name: the hashed form is a query, and has its own type
  it "a name is never a hash" $
    parseN ("[" <> T.replicate 64 "b" <> "].simplex") `shouldSatisfy` isLeft
  -- keccak-256("alice"), the same constant the resolver's own tests use
  it "hashes the 2LD to the registry key" $
    (queryName . nameQuery currentClientSMPRelayVersion <$> parseN "alice.simplex")
      `shouldBe` Right "[9c0257114eb9399a2985f8e75dad7600c5d89fe3824ffa99ec1c3eb8bf3b0501].simplex"
  it "leaves subname labels as text" $
    (queryName . nameQuery currentClientSMPRelayVersion <$> parseN "x.alice.simplex")
      `shouldBe` Right "x.[9c0257114eb9399a2985f8e75dad7600c5d89fe3824ffa99ec1c3eb8bf3b0501].simplex"
  it "leaves a web name alone: no registry, nothing to key on" $
    (queryName . nameQuery currentClientSMPRelayVersion <$> parseN "example.com") `shouldBe` Right "example.com"
  -- below v22 a router can only read the name
  it "sends the name itself below v22" $
    (queryName . nameQuery namesSMPVersion <$> parseN "alice.simplex") `shouldBe` Right "alice.simplex"
  it "a query survives the wire" $
    mapM_
      (\q -> smpDecode (smpEncode q) `shouldBe` Right q)
      [ nameQuery currentClientSMPRelayVersion d,
        nameQuery namesSMPVersion d
      ]
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
    d = SimplexDomain {nameTLD = TLDSimplex, domain = "alice", subDomain = ["x"]}

resolverSpec :: Spec
resolverSpec = do
  it "returns NameRecord on 200 OK" $
    withResolverServer (resolveResp status200 (J.encode testNameRecord)) $ \port _ -> do
      env <- newNamesEnv (testNamesConfig port)
      resolveName env aliceDomain `shouldReturn` Right (NRRegistered Nothing Nothing Nothing testNameRecord)

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
    aliceDomain = nameQuery namesSMPVersion SimplexDomain {nameTLD = TLDSimplex, domain = "alice", subDomain = []}

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
