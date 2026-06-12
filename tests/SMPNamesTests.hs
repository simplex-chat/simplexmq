{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module SMPNamesTests (smpNamesTests, sampleRecord, sampleRecordJSON) where

import qualified Data.Aeson as J
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy as LB
import Data.Either (isLeft, isRight)
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.List (sort)
import qualified Data.Text as T
import Data.Text.Encoding (encodeUtf8)
import Simplex.Messaging.Encoding (smpDecode, smpEncode)
import Simplex.Messaging.Encoding.String (strDecode)
import Simplex.Messaging.Names.EthAddress (EthAddress, mkEthAddress, unEthAddress)
import Simplex.Messaging.Protocol (ErrorType (..), NameErrorType (..), NameRecord (..))
import Simplex.Messaging.Server.Main (validateUrl)
import Simplex.Messaging.Server.Names
  ( NamesConfig (..),
    ResolverCallKind (..),
    RpcAuth (..),
    newNamesEnvWith,
    pingEndpoint,
    resolveName,
  )
import Simplex.Messaging.Server.Names.HttpResolver (ResolverError (..))
import Simplex.Messaging.SimplexName (SimplexNameDomain (..), SimplexTLD (..))
import Test.Hspec

twentyOnes :: B.ByteString
twentyOnes = B.replicate 20 '\x01'

unsafeAddr :: B.ByteString -> EthAddress
unsafeAddr = either error id . mkEthAddress

-- | Sample record matching the resolver JSON shape. Text fields use the empty
-- string as the "unset" sentinel; coin fields use Nothing -> JSON null.
sampleRecord :: NameRecord
sampleRecord =
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
      nrOwner = unsafeAddr twentyOnes,
      nrResolver = unsafeAddr (B.replicate 20 '\x02')
    }

-- | JSON value canned by the resolver-stub for the "success" tests.
sampleRecordJSON :: J.Value
sampleRecordJSON = J.toJSON sampleRecord

testNamesConfig :: NamesConfig
testNamesConfig =
  NamesConfig
    { resolverEndpoint = "http://stub",
      resolverAuth = Nothing,
      resolverTimeoutMs = 1000,
      resolverMaxResponseBytes = 65536
    }

smpNamesTests :: Spec
smpNamesTests = do
  describe "NameRecord JSON (Protocol)" nameRecordEncodingSpec
  describe "Wire encoding (smpEncode)" wireEncodingSpec
  describe "Smart constructors (EthAddress)" smartCtorsSpec
  describe "Name parsing (SimplexNameDomain)" parseNameSpec
  describe "HTTP resolver" resolverSpec
  describe "Resolver health probe" healthSpec
  describe "resolver_endpoint validation" validateUrlSpec

nameRecordEncodingSpec :: Spec
nameRecordEncodingSpec = do
  it "round-trips JSON encode / decode" $
    J.eitherDecodeStrict (LB.toStrict (J.encode sampleRecord)) `shouldBe` Right sampleRecord

  it "emits keys in spec-documented order (resolver shape)" $ do
    let bytes = LB.toStrict (J.encode sampleRecord)
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
    let bytes = LB.toStrict (J.encode sampleRecord)
    B.isInfixOf "\"btc\":null" bytes `shouldBe` True
    B.isInfixOf "\"xmr\":null" bytes `shouldBe` True
    B.isInfixOf "\"dot\":null" bytes `shouldBe` True

  it "emits unset link fields as empty arrays (not null)" $ do
    let bytes = LB.toStrict (J.encode sampleRecord)
    B.isInfixOf "\"simplexChannel\":[]" bytes `shouldBe` True
    B.isInfixOf "\"simplexChannel\":null" bytes `shouldBe` False

  it "FromJSON EthAddress accepts both 0x and 0X prefixes" $ do
    let json p = "\"" <> p <> "0101010101010101010101010101010101010101\""
    (J.eitherDecodeStrict (json "0x") :: Either String EthAddress) `shouldSatisfy` isRight
    (J.eitherDecodeStrict (json "0X") :: Either String EthAddress) `shouldSatisfy` isRight

  it "owner / resolver are emitted as lowercase hex" $ do
    -- The resolver returns lowercase hex; encoded form must match.
    let mixedCase = unsafeAddr (B.pack ['\xde', '\xad', '\xbe', '\xef'] <> B.replicate 16 '\x00')
        bytes = LB.toStrict (J.encode sampleRecord {nrOwner = mixedCase, nrResolver = mixedCase})
    B.isInfixOf "0xdeadbeef" bytes `shouldBe` True
    B.isInfixOf "0xDEADBEEF" bytes `shouldBe` False

-- The RNAME response and ERR (NAME ...) travel as field-ordered smpEncode on
-- the wire (no JSON), so round-trip the new Encoding instances directly.
wireEncodingSpec :: Spec
wireEncodingSpec = do
  it "NameRecord round-trips smpEncode / smpDecode" $
    smpDecode (smpEncode sampleRecord) `shouldBe` Right sampleRecord

  it "NameRecord round-trips with multiple links and unset coins" $ do
    let r =
          sampleRecord
            { nrSimplexContact = ["simplex:/contact/a#1", "simplex:/contact/b#2"],
              nrSimplexChannel = [],
              nrEth = Nothing,
              nrBtc = Nothing
            }
    smpDecode (smpEncode r) `shouldBe` Right r

  it "ErrorType NAME family round-trips smpEncode / smpDecode" $ do
    smpDecode (smpEncode (NAME NO_RESOLVER)) `shouldBe` Right (NAME NO_RESOLVER)
    smpDecode (smpEncode (NAME NO_NAME)) `shouldBe` Right (NAME NO_NAME)
    -- RESOLVER detail may contain spaces - must survive the round-trip
    smpDecode (smpEncode (NAME (RESOLVER "HTTP 502"))) `shouldBe` Right (NAME (RESOLVER "HTTP 502"))

smartCtorsSpec :: Spec
smartCtorsSpec = do
  it "mkEthAddress accepts exactly 20 bytes" $ do
    mkEthAddress twentyOnes `shouldSatisfy` isRight
    mkEthAddress (B.replicate 19 '\x01') `shouldSatisfy` isLeft
    mkEthAddress (B.replicate 21 '\x01') `shouldSatisfy` isLeft

  it "unEthAddress round-trips mkEthAddress" $
    case mkEthAddress twentyOnes of
      Right o -> unEthAddress o `shouldBe` twentyOnes
      Left e -> expectationFailure ("mkEthAddress failed: " <> e)

-- The RSLV command carries a parsed SimplexNameDomain, so name validation
-- happens at parse (StrEncoding). These exercise that validation directly.
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
  where
    parseN :: T.Text -> Either String SimplexNameDomain
    parseN = strDecode . encodeUtf8

resolverSpec :: Spec
resolverSpec = do
  let mkEnv stub = newNamesEnvWith testNamesConfig stub Nothing
      aliceDomain = SimplexNameDomain {nameTLD = TLDSimplex, domain = "alice", subDomain = []}

  it "returns NameRecord on 200 OK" $ do
    env <- mkEnv (\_ -> pure (Right sampleRecordJSON))
    r <- resolveName env aliceDomain
    r `shouldBe` Right sampleRecord

  it "returns NO_NAME on 404" $ do
    env <- mkEnv (\_ -> pure (Left (HttpStatusErr 404)))
    resolveName env aliceDomain `shouldReturn` Left NO_NAME

  it "returns NO_NAME on 400 (unknown TLD)" $ do
    env <- mkEnv (\_ -> pure (Left (HttpStatusErr 400)))
    resolveName env aliceDomain `shouldReturn` Left NO_NAME

  it "returns RESOLVER on 502 (upstream failure)" $ do
    env <- mkEnv (\_ -> pure (Left (HttpStatusErr 502)))
    resolveName env aliceDomain `shouldReturn` Left (RESOLVER "HTTP 502")

  it "returns RESOLVER on transport-layer body-too-large" $ do
    env <- mkEnv (\_ -> pure (Left BodyTooLarge))
    resolveName env aliceDomain `shouldReturn` Left (RESOLVER "response too large")

  it "returns RESOLVER on malformed JSON from the resolver" $ do
    env <- mkEnv (\_ -> pure (Left (InvalidJson "expected object")))
    resolveName env aliceDomain `shouldReturn` Left (RESOLVER "invalid response")

  it "returns RESOLVER when JSON parses but isn't a NameRecord shape" $ do
    env <- mkEnv (\_ -> pure (Right (J.object [])))
    resolveName env aliceDomain `shouldReturn` Left (RESOLVER "invalid response")

  it "sends one HTTP request per lookup (no cache)" $ do
    callCount <- newIORef (0 :: Int)
    env <- mkEnv $ \_ -> do
      atomicModifyIORef' callCount (\v -> (v + 1, ()))
      pure (Right sampleRecordJSON)
    _ <- resolveName env aliceDomain
    _ <- resolveName env aliceDomain
    readIORef callCount `shouldReturn` 2

  it "addresses the resolver with the full canonical domain name" $ do
    seenName <- newIORef ("" :: T.Text)
    env <-
      mkEnv $ \case
        ResolverFetch n -> do
          atomicModifyIORef' seenName (\_ -> (n, ()))
          pure (Right sampleRecordJSON)
        ResolverHealth -> pure (Right (J.object []))
    _ <- resolveName env aliceDomain
    readIORef seenName `shouldReturn` "alice.simplex"

healthSpec :: Spec
healthSpec = do
  let mkEnv stub = newNamesEnvWith testNamesConfig stub Nothing

  it "pingEndpoint succeeds on a 200 OK /health response" $ do
    env <- mkEnv (\_ -> pure (Right (J.object [])))
    r <- pingEndpoint env
    case r of
      Right () -> pure ()
      Left e -> expectationFailure $ "expected Right (), got Left " <> show e

  it "pingEndpoint fails on a 500 /health response" $ do
    env <- mkEnv (\_ -> pure (Left (HttpStatusErr 500)))
    r <- pingEndpoint env
    case r of
      Left (HttpStatusErr 500) -> pure ()
      _ -> expectationFailure $ "expected Left (HttpStatusErr 500), got " <> show r

  it "pingEndpoint routes to ResolverHealth (not ResolverFetch)" $ do
    seenKind <- newIORef Nothing
    env <- mkEnv $ \k -> do
      atomicModifyIORef' seenKind (\_ -> (Just k, ()))
      pure (Right (J.object []))
    _ <- pingEndpoint env
    readIORef seenKind `shouldReturn` Just ResolverHealth

validateUrlSpec :: Spec
validateUrlSpec = do
  let auth = Just (AuthBasic "user" "pass")
  it "accepts https with explicit port and auth (root path)" $
    validateUrl "https://gw.example.com:443" auth `shouldSatisfy` isRight
  it "accepts a path prefix (reverse-proxy sub-path)" $
    validateUrl "https://gw.example.com:443/snrc" auth `shouldSatisfy` isRight
  it "accepts a path prefix with trailing slash" $
    validateUrl "https://gw.example.com:443/snrc/" auth `shouldSatisfy` isRight
  it "rejects a query string" $
    validateUrl "https://gw.example.com:443/snrc?x=1" auth `shouldSatisfy` isLeft
  it "rejects a fragment" $
    validateUrl "https://gw.example.com:443/snrc#f" auth `shouldSatisfy` isLeft
  it "rejects userinfo (credentials belong in resolver_auth)" $
    validateUrl "https://user:pass@gw.example.com:443" auth `shouldSatisfy` isLeft
  it "rejects a missing port" $
    validateUrl "https://gw.example.com/snrc" auth `shouldSatisfy` isLeft
  it "accepts https on a non-loopback host without auth (public resolver)" $
    validateUrl "https://gw.example.com:443/snrc" Nothing `shouldSatisfy` isRight
  it "accepts http without auth on a non-loopback host (e.g. host.docker.internal)" $
    validateUrl "http://host.docker.internal:9999" Nothing `shouldSatisfy` isRight
  it "rejects http WITH auth on a non-loopback host (cleartext credential leak)" $
    validateUrl "http://gw.example.com:9999" auth `shouldSatisfy` isLeft
  it "allows loopback http without auth (with a path prefix)" $
    validateUrl "http://localhost:8000/snrc" Nothing `shouldSatisfy` isRight
