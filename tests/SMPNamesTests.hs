{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module SMPNamesTests (smpNamesTests) where

import qualified Crypto.Hash as Crypton
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteArray as BA
import Data.Either (isLeft, isRight)
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.List (sort)
import qualified Data.Text as T
import qualified Data.Aeson as J
import qualified Data.ByteString.Lazy as LB
import Simplex.Messaging.Protocol
  ( NameOwner,
    NameRecord (..),
    RslvRequest (..),
    mkNameLink,
    mkNameOwner,
    unNameLink,
    unNameOwner,
  )
import Simplex.Messaging.Server.Names
  ( NamesConfig (..),
    ResolveError (..),
    TldRegistries (..),
    lookupTldAddress,
    newNamesEnvWith,
    resolveName,
    verifyRslv,
  )
import Simplex.Messaging.Server.Names.Eth.SNRC
  ( AbiError (..),
    decodeAddress,
    decodeGetRecord,
    decodeString,
    decodeStringArray,
    decodeWord256Int64,
    encodeGetRecord,
    keccak256,
    namehash,
    snrcSelector,
  )
import Simplex.Messaging.SimplexName (SimplexNameDomain (..), SimplexTLD (..))
import Test.Hspec

-- Reference vectors:
-- keccak256("")  = c5d2460186f7233c927e7db2dcc703c0e500b653ca8227b7bfad8045d85a470
-- keccak256("abc") = 4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45
-- sha3_256("abc") = 3a985da74fe225b2045c172d6bd390bd855f086e3e9d525b46bfe24511431532
-- namehash("eth")  = 93cdeb708b7545dc668eb9280176169d1c33cfd8ed6f04690a0bcc88a93fc4ae

keccak256Empty :: ByteString
keccak256Empty = "\xc5\xd2\x46\x01\x86\xf7\x23\x3c\x92\x7e\x7d\xb2\xdc\xc7\x03\xc0\xe5\x00\xb6\x53\xca\x82\x27\x3b\x7b\xfa\xd8\x04\x5d\x85\xa4\x70"

keccak256Abc :: ByteString
keccak256Abc = "\x4e\x03\x65\x7a\xea\x45\xa9\x4f\xc7\xd4\x7b\xa8\x26\xc8\xd6\x67\xc0\xd1\xe6\xe3\x3a\x64\xa0\x36\xec\x44\xf5\x8f\xa1\x2d\x6c\x45"

sha3_256Abc :: ByteString
sha3_256Abc = "\x3a\x98\x5d\xa7\x4f\xe2\x25\xb2\x04\x5c\x17\x2d\x6b\xd3\x90\xbd\x85\x5f\x08\x6e\x3e\x9d\x52\x5b\x46\xbf\xe2\x45\x11\x43\x15\x32"

namehashEth :: ByteString
namehashEth = "\x93\xcd\xeb\x70\x8b\x75\x45\xdc\x66\x8e\xb9\x28\x01\x76\x16\x9d\x1c\x33\xcf\xd8\xed\x6f\x04\x69\x0a\x0b\xcc\x88\xa9\x3f\xc4\xae"

twentyOnes :: ByteString
twentyOnes = B.replicate 20 '\x01'

sampleRecord :: NameRecord
sampleRecord = case (mkNameOwner twentyOnes, mkNameLink "simplex:/contact/abc#xyz") of
  (Right o, Right l) ->
    NameRecord
      { nrDisplayName = "Alice",
        nrOwner = o,
        nrChannelLinks = [],
        nrContactLinks = [l],
        nrAdminAddress = Just "simplex:/admin/...",
        nrAdminEmail = Just "admin@example.org",
        nrExpiry = 1735689600,
        nrIsTest = False
      }
  _ -> error "sampleRecord smart ctors failed"

smpNamesTests :: Spec
smpNamesTests = do
  describe "NameRecord encoding (Protocol)" nameRecordEncodingSpec
  describe "Smart constructors (NameOwner, NameLink)" smartCtorsSpec
  describe "Keccak-256 and namehash" namehashSpec
  describe "ABI primitive bounds" abiBoundsSpec
  describe "decodeGetRecord (zero-owner sentinel)" zeroOwnerSpec
  describe "TLD whitelist + RSLV verification" tldWhitelistSpec
  describe "Resolver" resolverSpec

nameRecordEncodingSpec :: Spec
nameRecordEncodingSpec = do
  it "round-trips JSON encode / decode" $
    J.eitherDecodeStrict (LB.toStrict (J.encode sampleRecord)) `shouldBe` Right sampleRecord

  it "emits keys in spec-documented order (displayName, owner, channelLinks, contactLinks, adminAddress, adminEmail, expiry, isTest)" $ do
    -- Default toEncoding routes through Value/KeyMap and re-emits keys
    -- alphabetically; spec requires byte-identical canonical encoding.
    let bytes = LB.toStrict (J.encode sampleRecord)
        offset k = B.length (fst (B.breakSubstring k bytes))
        offsets = map offset ["displayName", "owner", "channelLinks", "contactLinks", "adminAddress", "adminEmail", "expiry", "isTest"]
    offsets `shouldBe` sort offsets

  it "rejects negative expiry" $ do
    let badBytes = LB.toStrict (J.encode sampleRecord {nrExpiry = -1})
    (J.eitherDecodeStrict badBytes :: Either String NameRecord) `shouldSatisfy` isLeft

  it "enforces combined channel+contact list cap of 8" $ do
    let mkLink i = either error id (mkNameLink ("simplex:/contact/" <> T.pack (show (i :: Int))))
        nineLinks = map mkLink [0 .. 8]
        overflow = sampleRecord {nrChannelLinks = nineLinks, nrContactLinks = []}
        bytes = LB.toStrict (J.encode overflow)
    (J.eitherDecodeStrict bytes :: Either String NameRecord) `shouldSatisfy` isLeft

  it "rejects nrDisplayName > 255 bytes UTF-8" $ do
    let oversize = sampleRecord {nrDisplayName = T.replicate 256 "x"}
        bytes = LB.toStrict (J.encode oversize)
    (J.eitherDecodeStrict bytes :: Either String NameRecord) `shouldSatisfy` isLeft

  it "FromJSON NameOwner accepts both 0x and 0X prefixes" $ do
    let json p = "\"" <> p <> "0101010101010101010101010101010101010101\""
    (J.eitherDecodeStrict (json "0x") :: Either String NameOwner) `shouldSatisfy` isRight
    (J.eitherDecodeStrict (json "0X") :: Either String NameOwner) `shouldSatisfy` isRight

  it "encodes within the proxied transmission budget" $ do
    let huge = either error id (mkNameLink (T.replicate 1024 "x"))
        wide =
          sampleRecord
            { nrChannelLinks = replicate 4 huge,
              nrContactLinks = replicate 4 huge,
              nrDisplayName = T.replicate 255 "n",
              nrAdminAddress = Just (T.replicate 255 "a"),
              nrAdminEmail = Just (T.replicate 255 "e")
            }
    LB.length (J.encode wide) < 16224 `shouldBe` True

smartCtorsSpec :: Spec
smartCtorsSpec = do
  it "mkNameOwner accepts exactly 20 bytes" $ do
    mkNameOwner twentyOnes `shouldSatisfy` isRight
    mkNameOwner (B.replicate 19 '\x01') `shouldSatisfy` isLeft
    mkNameOwner (B.replicate 21 '\x01') `shouldSatisfy` isLeft

  it "mkNameLink rejects >1024 UTF-8 bytes" $ do
    mkNameLink (T.replicate 1024 "x") `shouldSatisfy` isRight
    mkNameLink (T.replicate 1025 "x") `shouldSatisfy` isLeft
    -- multibyte UTF-8 counted in bytes, not chars: 600 × 3 = 1800 bytes
    mkNameLink (T.replicate 600 "\x4e2d") `shouldSatisfy` isLeft

  it "unNameLink / unNameOwner round-trip the smart ctors" $ do
    case (mkNameOwner twentyOnes, mkNameLink "abc") of
      (Right o, Right l) -> do
        unNameOwner o `shouldBe` twentyOnes
        unNameLink l `shouldBe` "abc"
      _ -> expectationFailure "smart ctors failed"

namehashSpec :: Spec
namehashSpec = do
  it "keccak256 of empty string matches reference vector" $
    keccak256 "" `shouldBe` keccak256Empty

  it "keccak256 of \"abc\" matches reference vector" $
    keccak256 "abc" `shouldBe` keccak256Abc

  it "Keccak-256 is NOT SHA3-256 (different output for same input)" $ do
    let sha3 = BA.convert (Crypton.hash @ByteString @Crypton.SHA3_256 "abc") :: ByteString
    sha3 `shouldBe` sha3_256Abc
    keccak256 "abc" `shouldNotBe` sha3

  it "namehash of empty name is 32 zero bytes" $
    namehash "" `shouldBe` B.replicate 32 '\NUL'

  it "namehash of \"eth\" matches ENS reference vector" $
    namehash "eth" `shouldBe` namehashEth

  it "snrcSelector is 4 bytes" $
    B.length snrcSelector `shouldBe` 4

  it "encodeGetRecord = selector ++ 32-byte node" $ do
    let node = namehash "alice.eth"
        bytes = encodeGetRecord node
    B.length bytes `shouldBe` 36
    B.take 4 bytes `shouldBe` snrcSelector
    B.drop 4 bytes `shouldBe` node

abiBoundsSpec :: Spec
abiBoundsSpec = do
  let mkBuf n = B.replicate n '\NUL'

  it "decodeWord256Int64 fails when offset + 32 > buf length" $
    decodeWord256Int64 0 (mkBuf 31) `shouldBe` Left AbiTruncated

  it "decodeWord256Int64 rejects non-zero high 24 bytes (Int64 overflow)" $ do
    let buf = B.replicate 23 '\NUL' <> B.singleton '\x01' <> B.replicate 8 '\NUL'
    decodeWord256Int64 0 buf `shouldBe` Left AbiNonZeroHighBytes

  it "decodeWord256Int64 rejects sign bit set in low 8 bytes (silent negative)" $ do
    -- 0x8000000000000000 would decode to Int64.minBound without the check;
    -- downstream length math would then see a negative len and silently
    -- return empty bytes from B.take instead of failing.
    let buf = B.replicate 24 '\NUL' <> "\x80\x00\x00\x00\x00\x00\x00\x00"
    decodeWord256Int64 0 buf `shouldBe` Left AbiNonZeroHighBytes

  it "decodeWord256Int64 succeeds for the max representable positive value" $ do
    let buf = B.replicate 24 '\NUL' <> "\x7F\xFF\xFF\xFF\xFF\xFF\xFF\xFF"
    decodeWord256Int64 0 buf `shouldBe` Right maxBound

  it "decodeWord256Int64 succeeds for low 8 bytes set" $ do
    let buf = B.replicate 24 '\NUL' <> "\x00\x00\x00\x00\x00\x00\x12\x34"
    decodeWord256Int64 0 buf `shouldBe` Right 0x1234

  it "decodeAddress rejects non-zero high 12 bytes" $ do
    let buf = B.replicate 11 '\NUL' <> B.singleton '\x01' <> B.replicate 20 '\NUL'
    decodeAddress 0 buf `shouldSatisfy` isLeft

  it "decodeString fails on backward offset" $
    decodeString 100 50 1024 (mkBuf 200) `shouldBe` Left AbiBackwardOffset

  it "decodeString fails when declared length exceeds the per-field cap" $ do
    let lenBytes = B.replicate 24 '\NUL' <> "\x00\x00\x00\x00\x00\x00\x00\x64" -- length 100
        buf = lenBytes <> B.replicate 100 'x'
    decodeString 0 0 10 buf `shouldBe` Left AbiOversized

  it "decodeStringArray fails when depth ≥ 2" $
    decodeStringArray 2 0 0 8 1024 (mkBuf 64) `shouldBe` Left AbiDepthExceeded

  it "decodeStringArray fails when array count exceeds cap" $ do
    let lenBytes = B.replicate 24 '\NUL' <> "\x00\x00\x00\x00\x00\x00\x00\x09" -- 9 elements
        buf = lenBytes <> B.replicate 1024 '\NUL'
    decodeStringArray 0 0 0 8 1024 buf `shouldBe` Left AbiOversized

zeroOwnerSpec :: Spec
zeroOwnerSpec = do
  it "decodeGetRecord returns Nothing for zero-owner buffer" $ do
    -- 8 slots × 32 bytes; owner at slot 1 (offset 32) is all-zero by construction
    let buf = B.replicate (32 * 8) '\NUL'
    decodeGetRecord buf `shouldBe` Right Nothing

  it "decodeGetRecord fails on truncated buffer" $ do
    let tiny = B.replicate 31 '\NUL'
    decodeGetRecord tiny `shouldBe` Left AbiTruncated

tldWhitelistSpec :: Spec
tldWhitelistSpec = do
  let addr1 = either error id (mkNameOwner twentyOnes)
      addr2 = either error id (mkNameOwner (B.replicate 20 '\x02'))
      addr3 = either error id (mkNameOwner (B.replicate 20 '\x03'))

  describe "lookupTldAddress" $ do
    it "TLD-specific entry takes precedence over _all" $ do
      let regs = TldRegistries {tldSimplex = Just addr1, tldTesting = Just addr2, tldAll = Just addr3}
      lookupTldAddress regs TLDSimplex `shouldBe` Just addr1
      lookupTldAddress regs TLDTesting `shouldBe` Just addr2

    it "TLD without specific entry falls back to _all" $ do
      let regs = TldRegistries {tldSimplex = Nothing, tldTesting = Nothing, tldAll = Just addr3}
      lookupTldAddress regs TLDSimplex `shouldBe` Just addr3
      lookupTldAddress regs TLDTesting `shouldBe` Just addr3

    it "TLDWeb resolves only through _all" $ do
      let regs = TldRegistries {tldSimplex = Just addr1, tldTesting = Just addr2, tldAll = Just addr3}
      lookupTldAddress regs TLDWeb `shouldBe` Just addr3

    it "TLDWeb without _all returns Nothing even if other TLDs are set" $ do
      let regs = TldRegistries {tldSimplex = Just addr1, tldTesting = Just addr2, tldAll = Nothing}
      lookupTldAddress regs TLDWeb `shouldBe` Nothing

  describe "verifyRslv" $ do
    let cfgWith regs =
          NamesConfig
            { ethereumEndpoint = "http://stub",
              tldRegistries = regs,
              rpcAuth = Nothing,
              rpcTimeoutMs = 1000,
              rpcMaxResponseBytes = 65536,
              rpcMaxConcurrency = 4
            }
        mkEnv regs = newNamesEnvWith (cfgWith regs) (\_ _ -> pure (Right "")) Nothing

    it "accepts a valid name with matching TLD-specific contract" $ do
      env <- mkEnv $ TldRegistries {tldSimplex = Just addr1, tldTesting = Nothing, tldAll = Nothing}
      let req = RslvRequest {name = "privacy.simplex", contract = addr1}
      case verifyRslv env req of
        Just (a, d) -> do
          a `shouldBe` addr1
          nameTLD d `shouldBe` TLDSimplex
          domain d `shouldBe` "privacy"
        Nothing -> expectationFailure "expected Just"

    it "normalizes case across all labels (Alice.SIMPLEX ≡ alice.simplex for namehash)" $ do
      env <- mkEnv $ TldRegistries {tldSimplex = Just addr1, tldTesting = Nothing, tldAll = Nothing}
      let lower = RslvRequest {name = "alice.simplex", contract = addr1}
          mixed = RslvRequest {name = "Alice.SIMPLEX", contract = addr1}
      case (verifyRslv env lower, verifyRslv env mixed) of
        (Just (_, dL), Just (_, dM)) -> dL `shouldBe` dM
        _ -> expectationFailure "both should parse"

    it "rejects mismatched contract address" $ do
      env <- mkEnv $ TldRegistries {tldSimplex = Just addr1, tldTesting = Nothing, tldAll = Nothing}
      let req = RslvRequest {name = "privacy.simplex", contract = addr2}
      verifyRslv env req `shouldBe` Nothing

    it "rejects TLD with no whitelist entry" $ do
      env <- mkEnv $ TldRegistries {tldSimplex = Just addr1, tldTesting = Nothing, tldAll = Nothing}
      let req = RslvRequest {name = "test.testing", contract = addr1}
      verifyRslv env req `shouldBe` Nothing

    it "accepts via _all fallback" $ do
      env <- mkEnv $ TldRegistries {tldSimplex = Nothing, tldTesting = Nothing, tldAll = Just addr3}
      let req = RslvRequest {name = "test.testing", contract = addr3}
      case verifyRslv env req of
        Just (a, _) -> a `shouldBe` addr3
        Nothing -> expectationFailure "expected Just"

    it "rejects bare (no-TLD) name (SimplexNameDomain.strP requires TLD)" $ do
      env <- mkEnv $ TldRegistries {tldSimplex = Just addr1, tldTesting = Nothing, tldAll = Nothing}
      let req = RslvRequest {name = "privacy", contract = addr1}
      verifyRslv env req `shouldBe` Nothing

resolverSpec :: Spec
resolverSpec = do
  let mkEnv ethCall = do
        let cfg =
              NamesConfig
                { ethereumEndpoint = "http://stub",
                  tldRegistries = TldRegistries {tldSimplex = Just (either error id (mkNameOwner twentyOnes)), tldTesting = Nothing, tldAll = Nothing},
                  rpcAuth = Nothing,
                  rpcTimeoutMs = 1000,
                  rpcMaxResponseBytes = 65536,
                  rpcMaxConcurrency = 4
                }
        newNamesEnvWith cfg ethCall Nothing
      aliceDomain = SimplexNameDomain {nameTLD = TLDSimplex, domain = "alice", subDomain = []}
      aliceAddr = either error id (mkNameOwner twentyOnes)

  it "maps stub zero-owner response to NotFound" $ do
    env <- mkEnv $ \_ _ -> pure (Right (B.replicate (32 * 8) '\NUL'))
    r <- resolveName env aliceAddr aliceDomain
    r `shouldBe` Left NotFound

  it "every lookup hits the endpoint (no cache)" $ do
    callCount <- newIORef (0 :: Int)
    env <- mkEnv $ \_ _ -> do
      atomicModifyIORef' callCount (\v -> (v + 1, ()))
      pure (Right (B.replicate (32 * 8) '\NUL'))
    _ <- resolveName env aliceAddr aliceDomain
    _ <- resolveName env aliceAddr aliceDomain
    n <- readIORef callCount
    n `shouldBe` 2
