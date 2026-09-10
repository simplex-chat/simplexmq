{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module SMPNamesTests (smpNamesTests, testNameRecord, testPricing, registeredBody, availableBody, reservedBody) where

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
import Simplex.Messaging.Protocol (Command (..), ErrorType (..), NameErrorType (..), NamePricing (..), NameQuery (..), NameRecord (..), NameRegistration (..), NameReservedReason (..), ProtocolEncoding (..), USDCents (..))
import Simplex.Messaging.Server.Main (validateUrl)
import Simplex.Messaging.Server.Names
  ( NamesConfig (..),
    RpcAuth (..),
    newNamesEnv,
    pingEndpoint,
    resolveName,
  )
import Simplex.Messaging.Server.Names.HttpResolver (ResolverError (..))
import Simplex.Messaging.SimplexName (SimplexDomain (..), SimplexTLD (..), fullDomainName, labelHash)
import Simplex.Messaging.SystemTime (RoundedSystemTime (..))
import Simplex.Messaging.Transport (nameAvailSMPVersion, serverInfoSMPVersion)
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

-- | What the resolver serves on /v2/resolve. Spelled out rather than encoded
-- from the Haskell value: the literal JSON is the contract with the resolver.
registeredBody :: NameRecord -> LB.ByteString
registeredBody nameRec =
  "{\"type\":\"registered\",\"expires\":1813853483,\"graceUntil\":1821629483,\"reservedReason\":null,\"nameRecord\":" <> J.encode nameRec <> "}"

availableBody :: LB.ByteString
availableBody = "{\"type\":\"available\",\"pricing\":{\"registrationPrices\":{\"3\":12793,\"4\":3198},\"basePrice\":100,\"minLabelLength\":3}}"

reservedBody :: LB.ByteString
reservedBody = "{\"type\":\"reserved\",\"reservedReason\":\"trademark\"}"

-- | What `registeredBody testNameRecord` resolves to.
registeredAlice :: NameRegistration
registeredAlice =
  NRRegistered {expires = Just (RoundedSystemTime 1813853483), graceUntil = Just (RoundedSystemTime 1821629483), reservedReason_ = Nothing, nameRecord = testNameRecord}

smpNamesTests :: Spec
smpNamesTests = do
  describe "NameRecord JSON (Protocol)" nameRecordEncodingSpec
  describe "ErrorType NAME wire encoding" errorWireSpec
  describe "RSLV wire encoding" rslvWireSpec
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

-- the query format changed at v22, so an older session must still get the name
rslvWireSpec :: Spec
rslvWireSpec = do
  it "below v22 carries the name, as it did before" $
    encodeProtocol v20 (RSLV (NQDomain aliceDomain')) `shouldBe` "RSLV " <> smpEncode aliceDomain'
  -- keccak-256("alice"), the same constant the resolver's own tests use
  it "from v22 carries the 2LD as its hash" $
    encodeProtocol v22 (RSLV (NQDomain aliceDomain'))
      `shouldBe` "RSLV [9c0257114eb9399a2985f8e75dad7600c5d89fe3824ffa99ec1c3eb8bf3b0501].simplex"
  -- the hashed query has no room for subname labels, so such a name goes as text
  it "a name with subnames is not hashed" $
    encodeProtocol v22 (RSLV (NQDomain aliceDomain' {subDomain = ["x"]})) `shouldBe` "RSLV x.alice.simplex"
  it "leaves a web name alone: no registry, nothing to key on" $
    encodeProtocol v22 (RSLV (NQDomain webDomain')) `shouldBe` "RSLV example.com"
  where
    v20 = serverInfoSMPVersion
    v22 = nameAvailSMPVersion
    aliceDomain' = SimplexDomain {nameTLD = TLDSimplex, domain = "alice", subDomain = []}
    webDomain' = SimplexDomain {nameTLD = TLDWeb, domain = "example.com", subDomain = []}

availabilitySpec :: Spec
availabilitySpec = do
  -- one lookup answers what the name points to, whether it can be taken, and
  -- whether it is held back
  it "a registered name answers with its record and dates" $
    answers (registeredBody testNameRecord) registeredAlice
  it "a registered name can be held back too" $
    answers heldBackBody $
      NRRegistered {expires = Just (RoundedSystemTime 1813853483), graceUntil = Just (RoundedSystemTime 1821629483), reservedReason_ = Just NRRInternal, nameRecord = testNameRecord}
  it "an unregistered name answers with the price" $
    answers availableBody NRAvailable {pricing = testPricing}
  it "reserved carries the reason and no price" $
    answers reservedBody (NRReserved NRRTrademark)
  -- losing the reservation would offer a name that cannot be registered
  it "a reason from a later version still reserves the name" $
    answers "{\"type\":\"reserved\",\"reservedReason\":\"seasonal\"}" (NRReserved (NRRUnknown "seasonal"))
  -- RNAME carries the registration as JSON, so that is the encoding to hold
  it "every registration survives the wire" $
    mapM_
      (\a -> J.eitherDecodeStrict (LB.toStrict (J.encode a)) `shouldBe` Right a)
      [ registeredAlice,
        NRRegistered {expires = Nothing, graceUntil = Nothing, reservedReason_ = Just NRRInternal, nameRecord = testNameRecord},
        NRAvailable {pricing = testPricing},
        NRReserved NRRInternal,
        NRReserved NRRTrademark,
        NRReserved NRRCommunity,
        NRReserved (NRRUnknown "seasonal")
      ]
  -- one vocabulary: the same word from the resolver and in JSON
  it "a reason reads the same in JSON as from the resolver" $ do
    J.encode (NRRUnknown "seasonal") `shouldBe` "\"seasonal\""
    J.encode NRRTrademark `shouldBe` "\"trademark\""
  where
    heldBackBody =
      "{\"type\":\"registered\",\"expires\":1813853483,\"graceUntil\":1821629483,\"reservedReason\":\"internal\",\"nameRecord\":" <> J.encode testNameRecord <> "}"
    answers body a =
      withResolverServer (resolveResp status200 body) $ \port _ -> do
        env <- newNamesEnv (testNamesConfig port)
        resolveName env aliceQuery `shouldReturn` Right a
    aliceQuery = NQDomain SimplexDomain {nameTLD = TLDSimplex, domain = "alice", subDomain = []}

-- | The .testing oracle: US cents per year by label length.
testPricing :: NamePricing
testPricing =
  NamePricing
    { registrationPrices = M.fromList [(3, USDCents 12793), (4, USDCents 3198)],
      basePrice = USDCents 100,
      minLabelLength = 3
    }

parseNameSpec :: Spec
parseNameSpec = do
  -- the hashed form is a query, not a name: it has its own type
  it "a name is never a hash" $
    parseN ("[" <> T.replicate 64 "b" <> "].simplex") `shouldSatisfy` isLeft
  it "a query survives the wire" $
    mapM_
      (\q -> smpDecode (smpEncode q) `shouldBe` Right q)
      [ NQDomain d,
        NQHash TLDSimplex (labelHash "alice")
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
  it "returns the registration on 200 OK" $
    withResolverServer (resolveResp status200 (registeredBody testNameRecord)) $ \port _ -> do
      env <- newNamesEnv (testNamesConfig port)
      resolveName env aliceDomain `shouldReturn` Right registeredAlice

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

  it "returns RESOLVER when JSON parses but isn't a NameRegistration shape" $
    withResolverServer (resolveResp status200 "{}") $ \port _ -> do
      env <- newNamesEnv (testNamesConfig port)
      resolveName env aliceDomain `shouldReturn` Left (RESOLVER "invalid response")

  it "returns RESOLVER (timeout) when the resolver is slower than resolverTimeoutMs" $
    withResolverServerDelayed 1500 (resolveResp status200 (registeredBody testNameRecord)) $ \port _ -> do
      env <- newNamesEnv (testNamesConfig port) {resolverTimeoutMs = 300}
      resolveName env aliceDomain `shouldReturn` Left (RESOLVER "timeout")

  it "sends one HTTP request per lookup (no cache)" $
    withResolverServer (resolveResp status200 (registeredBody testNameRecord)) $ \port reqs -> do
      env <- newNamesEnv (testNamesConfig port)
      _ <- resolveName env aliceDomain
      _ <- resolveName env aliceDomain
      readIORef reqs >>= \rs -> length rs `shouldBe` 2

  it "addresses the resolver with the full canonical domain name" $
    withResolverServer (resolveResp status200 (registeredBody testNameRecord)) $ \port reqs -> do
      env <- newNamesEnv (testNamesConfig port)
      _ <- resolveName env aliceDomain
      readIORef reqs `shouldReturn` [["v2", "resolve", "alice.simplex"]]

  where
    aliceDomain = NQDomain SimplexDomain {nameTLD = TLDSimplex, domain = "alice", subDomain = []}

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
