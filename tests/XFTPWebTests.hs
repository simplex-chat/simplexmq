{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Per-function tests for the xftp-web TypeScript XFTP client library.
-- Each test calls the Haskell function and the corresponding TypeScript function
-- via node, then asserts byte-identical output.
--
-- Prerequisites: cd xftp-web && npm install && npm run build
-- Run: cabal test --test-option=--match="/XFTP Web Client/"
module XFTPWebTests (xftpWebTests) where

import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as LB
import Data.Int (Int64)
import Data.List (intercalate)
import qualified Data.List.NonEmpty as NE
import Data.Word (Word16, Word32)
import Crypto.Error (throwCryptoError)
import qualified Crypto.PubKey.Curve25519 as X25519
import qualified Crypto.PubKey.Ed25519 as Ed25519
import qualified Data.ByteArray as BA
import qualified Simplex.Messaging.Crypto as C
import qualified Simplex.Messaging.Crypto.Lazy as LC
import Simplex.Messaging.Encoding
import System.Directory (doesDirectoryExist)
import System.Exit (ExitCode (..))
import System.Process (CreateProcess (..), StdStream (..), createProcess, proc, waitForProcess)
import Test.Hspec hiding (fit, it)
import Util

xftpWebDir :: FilePath
xftpWebDir = "xftp-web"

-- | Run an inline ES module script via node, return stdout as ByteString.
callNode :: String -> IO B.ByteString
callNode script = do
  (_, Just hout, _, ph) <-
    createProcess
      (proc "node" ["--input-type=module", "-e", script])
        { std_out = CreatePipe,
          cwd = Just xftpWebDir
        }
  out <- B.hGetContents hout
  ec <- waitForProcess ph
  ec `shouldBe` ExitSuccess
  pure out

-- | Format a ByteString as a JS Uint8Array constructor.
jsUint8 :: B.ByteString -> String
jsUint8 bs = "new Uint8Array([" <> intercalate "," (map show (B.unpack bs)) <> "])"

-- Import helpers for inline scripts.
impEnc, impPad, impDig, impKey :: String
impEnc = "import * as E from './dist/protocol/encoding.js';"
impPad = "import * as P from './dist/crypto/padding.js';"
impDig =
  "import sodium from 'libsodium-wrappers-sumo';"
    <> "import * as D from './dist/crypto/digest.js';"
    <> "await sodium.ready;"
impKey =
  "import sodium from 'libsodium-wrappers-sumo';"
    <> "import * as K from './dist/crypto/keys.js';"
    <> "await sodium.ready;"

-- | Wrap expression in process.stdout.write(Buffer.from(...)).
jsOut :: String -> String
jsOut expr = "process.stdout.write(Buffer.from(" <> expr <> "));"

xftpWebTests :: Spec
xftpWebTests = describe "XFTP Web Client" $ do
  distExists <- runIO $ doesDirectoryExist (xftpWebDir <> "/dist")
  if distExists
    then do
      tsEncodingTests
      tsPaddingTests
      tsDigestTests
      tsKeyTests
    else
      it "skipped (run 'cd xftp-web && npm install && npm run build' first)" $
        pendingWith "TS project not compiled"

-- ── protocol/encoding ──────────────────────────────────────────────

tsEncodingTests :: Spec
tsEncodingTests = describe "protocol/encoding" $ do
  describe "encode" $ do
    it "encodeWord16" $ do
      let val = 42 :: Word16
      actual <- callNode $ impEnc <> jsOut ("E.encodeWord16(" <> show val <> ")")
      actual `shouldBe` smpEncode val

    it "encodeWord16 max" $ do
      let val = 65535 :: Word16
      actual <- callNode $ impEnc <> jsOut ("E.encodeWord16(" <> show val <> ")")
      actual `shouldBe` smpEncode val

    it "encodeWord32" $ do
      let val = 100000 :: Word32
      actual <- callNode $ impEnc <> jsOut ("E.encodeWord32(" <> show val <> ")")
      actual `shouldBe` smpEncode val

    it "encodeInt64" $ do
      let val = 1234567890123456789 :: Int64
      actual <- callNode $ impEnc <> jsOut ("E.encodeInt64(" <> show val <> "n)")
      actual `shouldBe` smpEncode val

    it "encodeInt64 negative" $ do
      let val = -42 :: Int64
      actual <- callNode $ impEnc <> jsOut ("E.encodeInt64(" <> show val <> "n)")
      actual `shouldBe` smpEncode val

    it "encodeInt64 zero" $ do
      let val = 0 :: Int64
      actual <- callNode $ impEnc <> jsOut ("E.encodeInt64(" <> show val <> "n)")
      actual `shouldBe` smpEncode val

    it "encodeBytes" $ do
      let val = "hello" :: B.ByteString
      actual <- callNode $ impEnc <> jsOut ("E.encodeBytes(" <> jsUint8 val <> ")")
      actual `shouldBe` smpEncode val

    it "encodeBytes empty" $ do
      let val = "" :: B.ByteString
      actual <- callNode $ impEnc <> jsOut ("E.encodeBytes(" <> jsUint8 val <> ")")
      actual `shouldBe` smpEncode val

    it "encodeLarge" $ do
      let val = "test data for large encoding" :: B.ByteString
      actual <- callNode $ impEnc <> jsOut ("E.encodeLarge(" <> jsUint8 val <> ")")
      actual `shouldBe` smpEncode (Large val)

    it "encodeTail" $ do
      let val = "raw tail bytes" :: B.ByteString
      actual <- callNode $ impEnc <> jsOut ("E.encodeTail(" <> jsUint8 val <> ")")
      actual `shouldBe` smpEncode (Tail val)

    it "encodeBool True" $ do
      actual <- callNode $ impEnc <> jsOut "E.encodeBool(true)"
      actual `shouldBe` smpEncode True

    it "encodeBool False" $ do
      actual <- callNode $ impEnc <> jsOut "E.encodeBool(false)"
      actual `shouldBe` smpEncode False

    it "encodeString" $ do
      let val = "hello" :: String
      actual <- callNode $ impEnc <> jsOut "E.encodeString('hello')"
      actual `shouldBe` smpEncode val

    it "encodeMaybe Nothing" $ do
      actual <- callNode $ impEnc <> jsOut "E.encodeMaybe(E.encodeBytes, null)"
      actual `shouldBe` smpEncode (Nothing :: Maybe B.ByteString)

    it "encodeMaybe Just" $ do
      let val = "hello" :: B.ByteString
      actual <- callNode $ impEnc <> jsOut ("E.encodeMaybe(E.encodeBytes, " <> jsUint8 val <> ")")
      actual `shouldBe` smpEncode (Just val)

    it "encodeList" $ do
      let vals = ["ab", "cd", "ef"] :: [B.ByteString]
      actual <-
        callNode $
          impEnc
            <> "const xs = ["
            <> intercalate "," (map jsUint8 vals)
            <> "];"
            <> jsOut "E.encodeList(E.encodeBytes, xs)"
      actual `shouldBe` smpEncodeList vals

    it "encodeList empty" $ do
      let vals = [] :: [B.ByteString]
      actual <-
        callNode $
          impEnc <> jsOut "E.encodeList(E.encodeBytes, [])"
      actual `shouldBe` smpEncodeList vals

    it "encodeNonEmpty" $ do
      let vals = ["ab", "cd"] :: [B.ByteString]
      actual <-
        callNode $
          impEnc
            <> "const xs = ["
            <> intercalate "," (map jsUint8 vals)
            <> "];"
            <> jsOut "E.encodeNonEmpty(E.encodeBytes, xs)"
      actual `shouldBe` smpEncode (NE.fromList vals)

  describe "decode round-trips" $ do
    it "decodeWord16" $ do
      let encoded = smpEncode (42 :: Word16)
      actual <-
        callNode $
          impEnc
            <> "const d = new E.Decoder("
            <> jsUint8 encoded
            <> ");"
            <> jsOut "E.encodeWord16(E.decodeWord16(d))"
      actual `shouldBe` encoded

    it "decodeWord32" $ do
      let encoded = smpEncode (100000 :: Word32)
      actual <-
        callNode $
          impEnc
            <> "const d = new E.Decoder("
            <> jsUint8 encoded
            <> ");"
            <> jsOut "E.encodeWord32(E.decodeWord32(d))"
      actual `shouldBe` encoded

    it "decodeInt64" $ do
      let encoded = smpEncode (1234567890123456789 :: Int64)
      actual <-
        callNode $
          impEnc
            <> "const d = new E.Decoder("
            <> jsUint8 encoded
            <> ");"
            <> jsOut "E.encodeInt64(E.decodeInt64(d))"
      actual `shouldBe` encoded

    it "decodeInt64 negative" $ do
      let encoded = smpEncode (-42 :: Int64)
      actual <-
        callNode $
          impEnc
            <> "const d = new E.Decoder("
            <> jsUint8 encoded
            <> ");"
            <> jsOut "E.encodeInt64(E.decodeInt64(d))"
      actual `shouldBe` encoded

    it "decodeBytes" $ do
      let encoded = smpEncode ("hello" :: B.ByteString)
      actual <-
        callNode $
          impEnc
            <> "const d = new E.Decoder("
            <> jsUint8 encoded
            <> ");"
            <> jsOut "E.encodeBytes(E.decodeBytes(d))"
      actual `shouldBe` encoded

    it "decodeLarge" $ do
      let encoded = smpEncode (Large "large data")
      actual <-
        callNode $
          impEnc
            <> "const d = new E.Decoder("
            <> jsUint8 encoded
            <> ");"
            <> jsOut "E.encodeLarge(E.decodeLarge(d))"
      actual `shouldBe` encoded

    it "decodeBool" $ do
      let encoded = smpEncode True
      actual <-
        callNode $
          impEnc
            <> "const d = new E.Decoder("
            <> jsUint8 encoded
            <> ");"
            <> jsOut "E.encodeBool(E.decodeBool(d))"
      actual `shouldBe` encoded

    it "decodeString" $ do
      let encoded = smpEncode ("hello" :: String)
      actual <-
        callNode $
          impEnc
            <> "const d = new E.Decoder("
            <> jsUint8 encoded
            <> ");"
            <> jsOut "E.encodeString(E.decodeString(d))"
      actual `shouldBe` encoded

    it "decodeMaybe Just" $ do
      let encoded = smpEncode (Just ("hello" :: B.ByteString))
      actual <-
        callNode $
          impEnc
            <> "const d = new E.Decoder("
            <> jsUint8 encoded
            <> ");"
            <> jsOut "E.encodeMaybe(E.encodeBytes, E.decodeMaybe(E.decodeBytes, d))"
      actual `shouldBe` encoded

    it "decodeMaybe Nothing" $ do
      let encoded = smpEncode (Nothing :: Maybe B.ByteString)
      actual <-
        callNode $
          impEnc
            <> "const d = new E.Decoder("
            <> jsUint8 encoded
            <> ");"
            <> jsOut "E.encodeMaybe(E.encodeBytes, E.decodeMaybe(E.decodeBytes, d))"
      actual `shouldBe` encoded

    it "decodeList" $ do
      let encoded = smpEncodeList (["ab", "cd", "ef"] :: [B.ByteString])
      actual <-
        callNode $
          impEnc
            <> "const d = new E.Decoder("
            <> jsUint8 encoded
            <> ");"
            <> jsOut "E.encodeList(E.encodeBytes, E.decodeList(E.decodeBytes, d))"
      actual `shouldBe` encoded

-- ── crypto/padding ─────────────────────────────────────────────────

tsPaddingTests :: Spec
tsPaddingTests = describe "crypto/padding" $ do
  it "pad" $ do
    let msg = "hello" :: B.ByteString
        paddedLen = 256 :: Int
        expected = either (error . show) id $ C.pad msg paddedLen
    actual <- callNode $ impPad <> jsOut ("P.pad(" <> jsUint8 msg <> ", " <> show paddedLen <> ")")
    actual `shouldBe` expected

  it "pad minimal" $ do
    let msg = "ab" :: B.ByteString
        paddedLen = 16 :: Int
        expected = either (error . show) id $ C.pad msg paddedLen
    actual <- callNode $ impPad <> jsOut ("P.pad(" <> jsUint8 msg <> ", " <> show paddedLen <> ")")
    actual `shouldBe` expected

  it "Haskell pad -> TS unPad" $ do
    let msg = "cross-language test" :: B.ByteString
        paddedLen = 128 :: Int
        padded = either (error . show) id $ C.pad msg paddedLen
    actual <- callNode $ impPad <> jsOut ("P.unPad(" <> jsUint8 padded <> ")")
    actual `shouldBe` msg

  it "TS pad -> Haskell unPad" $ do
    let msg = "ts to haskell" :: B.ByteString
        paddedLen = 64 :: Int
    tsPadded <- callNode $ impPad <> jsOut ("P.pad(" <> jsUint8 msg <> ", " <> show paddedLen <> ")")
    let actual = either (error . show) id $ C.unPad tsPadded
    actual `shouldBe` msg

  it "padLazy" $ do
    let msg = "hello" :: B.ByteString
        msgLen = fromIntegral (B.length msg) :: Int64
        paddedLen = 64 :: Int64
        expected = either (error . show) id $ LC.pad (LB.fromStrict msg) msgLen paddedLen
    actual <-
      callNode $
        impPad <> jsOut ("P.padLazy(" <> jsUint8 msg <> ", " <> show msgLen <> "n, " <> show paddedLen <> "n)")
    actual `shouldBe` LB.toStrict expected

  it "Haskell padLazy -> TS unPadLazy" $ do
    let msg = "cross-language lazy" :: B.ByteString
        msgLen = fromIntegral (B.length msg) :: Int64
        paddedLen = 64 :: Int64
        padded = either (error . show) id $ LC.pad (LB.fromStrict msg) msgLen paddedLen
    actual <- callNode $ impPad <> jsOut ("P.unPadLazy(" <> jsUint8 (LB.toStrict padded) <> ")")
    actual `shouldBe` msg

  it "TS padLazy -> Haskell unPadLazy" $ do
    let msg = "ts to haskell lazy" :: B.ByteString
        msgLen = fromIntegral (B.length msg) :: Int64
        paddedLen = 128 :: Int64
    tsPadded <-
      callNode $
        impPad <> jsOut ("P.padLazy(" <> jsUint8 msg <> ", " <> show msgLen <> "n, " <> show paddedLen <> "n)")
    let actual = either (error . show) id $ LC.unPad (LB.fromStrict tsPadded)
    actual `shouldBe` LB.fromStrict msg

  it "splitLen" $ do
    let msg = "test content" :: B.ByteString
        msgLen = fromIntegral (B.length msg) :: Int64
        paddedLen = 64 :: Int64
        padded = either (error . show) id $ LC.pad (LB.fromStrict msg) msgLen paddedLen
    actual <-
      callNode $
        impEnc
          <> impPad
          <> "const r = P.splitLen("
          <> jsUint8 (LB.toStrict padded)
          <> ");"
          <> "const len = E.encodeInt64(r.len);"
          <> jsOut "E.concatBytes(len, r.content)"
    let (expectedLen, expectedContent) = either (error . show) id $ LC.splitLen padded
        expectedBytes = smpEncode expectedLen <> LB.toStrict expectedContent
    actual `shouldBe` expectedBytes

-- ── crypto/digest ──────────────────────────────────────────────────

tsDigestTests :: Spec
tsDigestTests = describe "crypto/digest" $ do
  it "sha256" $ do
    let input = "hello world" :: B.ByteString
    actual <- callNode $ impDig <> jsOut ("D.sha256(" <> jsUint8 input <> ")")
    actual `shouldBe` C.sha256Hash input

  it "sha256 empty" $ do
    let input = "" :: B.ByteString
    actual <- callNode $ impDig <> jsOut ("D.sha256(" <> jsUint8 input <> ")")
    actual `shouldBe` C.sha256Hash input

  it "sha512" $ do
    let input = "hello world" :: B.ByteString
    actual <- callNode $ impDig <> jsOut ("D.sha512(" <> jsUint8 input <> ")")
    actual `shouldBe` C.sha512Hash input

  it "sha512 empty" $ do
    let input = "" :: B.ByteString
    actual <- callNode $ impDig <> jsOut ("D.sha512(" <> jsUint8 input <> ")")
    actual `shouldBe` C.sha512Hash input

  it "sha256 binary" $ do
    let input = B.pack [0, 1, 2, 255, 254, 128]
    actual <- callNode $ impDig <> jsOut ("D.sha256(" <> jsUint8 input <> ")")
    actual `shouldBe` C.sha256Hash input

-- ── crypto/keys ──────────────────────────────────────────────────

tsKeyTests :: Spec
tsKeyTests = describe "crypto/keys" $ do
  describe "DER encoding" $ do
    it "encodePubKeyEd25519" $ do
      let rawPub = B.pack [1 .. 32]
          derPrefix = B.pack [0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00]
          expectedDer = derPrefix <> rawPub
      actual <- callNode $ impKey <> jsOut ("K.encodePubKeyEd25519(" <> jsUint8 rawPub <> ")")
      actual `shouldBe` expectedDer

    it "decodePubKeyEd25519" $ do
      let rawPub = B.pack [1 .. 32]
          derPrefix = B.pack [0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00]
          der = derPrefix <> rawPub
      actual <- callNode $ impKey <> jsOut ("K.decodePubKeyEd25519(" <> jsUint8 der <> ")")
      actual `shouldBe` rawPub

    it "encodePubKeyX25519" $ do
      let rawPub = B.pack [1 .. 32]
          derPrefix = B.pack [0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x6e, 0x03, 0x21, 0x00]
          expectedDer = derPrefix <> rawPub
      actual <- callNode $ impKey <> jsOut ("K.encodePubKeyX25519(" <> jsUint8 rawPub <> ")")
      actual `shouldBe` expectedDer

    it "encodePrivKeyEd25519" $ do
      let seed = B.pack [1 .. 32]
          derPrefix = B.pack [0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x04, 0x22, 0x04, 0x20]
          expectedDer = derPrefix <> seed
      actual <-
        callNode $
          impKey
            <> "const kp = K.ed25519KeyPairFromSeed("
            <> jsUint8 seed
            <> ");"
            <> jsOut "K.encodePrivKeyEd25519(kp.privateKey)"
      actual `shouldBe` expectedDer

    it "encodePrivKeyX25519" $ do
      let rawPriv = B.pack [1 .. 32]
          derPrefix = B.pack [0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x6e, 0x04, 0x22, 0x04, 0x20]
          expectedDer = derPrefix <> rawPriv
      actual <- callNode $ impKey <> jsOut ("K.encodePrivKeyX25519(" <> jsUint8 rawPriv <> ")")
      actual `shouldBe` expectedDer

    it "DER round-trip Ed25519 pubkey" $ do
      actual <-
        callNode $
          impKey
            <> "const kp = K.generateEd25519KeyPair();"
            <> "const der = K.encodePubKeyEd25519(kp.publicKey);"
            <> "const decoded = K.decodePubKeyEd25519(der);"
            <> "const match = decoded.length === kp.publicKey.length && decoded.every((b,i) => b === kp.publicKey[i]);"
            <> jsOut "new Uint8Array([match ? 1 : 0])"
      actual `shouldBe` B.pack [1]

    it "encodePubKeyEd25519 matches Haskell" $ do
      let seed = B.pack [1 .. 32]
          sk = throwCryptoError $ Ed25519.secretKey seed
          pk = Ed25519.toPublic sk
          rawPub = BA.convert pk :: B.ByteString
          haskellDer = C.encodePubKey (C.PublicKeyEd25519 pk)
      tsDer <- callNode $ impKey <> jsOut ("K.encodePubKeyEd25519(" <> jsUint8 rawPub <> ")")
      tsDer `shouldBe` haskellDer

    it "encodePubKeyX25519 matches Haskell" $ do
      let rawPriv = B.pack [1 .. 32]
          sk = throwCryptoError $ X25519.secretKey rawPriv
          pk = X25519.toPublic sk
          rawPub = BA.convert pk :: B.ByteString
          haskellDer = C.encodePubKey (C.PublicKeyX25519 pk)
      tsDer <- callNode $ impKey <> jsOut ("K.encodePubKeyX25519(" <> jsUint8 rawPub <> ")")
      tsDer `shouldBe` haskellDer

    it "encodePrivKeyEd25519 matches Haskell" $ do
      let seed = B.pack [1 .. 32]
          sk = throwCryptoError $ Ed25519.secretKey seed
          haskellDer = C.encodePrivKey (C.PrivateKeyEd25519 sk)
      tsDer <-
        callNode $
          impKey
            <> "const kp = K.ed25519KeyPairFromSeed("
            <> jsUint8 seed
            <> ");"
            <> jsOut "K.encodePrivKeyEd25519(kp.privateKey)"
      tsDer `shouldBe` haskellDer

    it "encodePrivKeyX25519 matches Haskell" $ do
      let rawPriv = B.pack [1 .. 32]
          sk = throwCryptoError $ X25519.secretKey rawPriv
          haskellDer = C.encodePrivKey (C.PrivateKeyX25519 sk)
      tsDer <- callNode $ impKey <> jsOut ("K.encodePrivKeyX25519(" <> jsUint8 rawPriv <> ")")
      tsDer `shouldBe` haskellDer

  describe "Ed25519 sign/verify" $ do
    it "sign determinism" $ do
      let seed = B.pack [1 .. 32]
          sk = throwCryptoError $ Ed25519.secretKey seed
          pk = Ed25519.toPublic sk
          msg = "deterministic test" :: B.ByteString
          sig = Ed25519.sign sk pk msg
          rawSig = BA.convert sig :: B.ByteString
      actual <-
        callNode $
          impKey
            <> "const kp = K.ed25519KeyPairFromSeed("
            <> jsUint8 seed
            <> ");"
            <> jsOut ("K.sign(kp.privateKey, " <> jsUint8 msg <> ")")
      actual `shouldBe` rawSig

    it "Haskell sign -> TS verify" $ do
      let seed = B.pack [1 .. 32]
          sk = throwCryptoError $ Ed25519.secretKey seed
          pk = Ed25519.toPublic sk
          msg = "cross-language sign test" :: B.ByteString
          sig = Ed25519.sign sk pk msg
          rawPub = BA.convert pk :: B.ByteString
          rawSig = BA.convert sig :: B.ByteString
      actual <-
        callNode $
          impKey
            <> "const ok = K.verify("
            <> jsUint8 rawPub
            <> ", "
            <> jsUint8 rawSig
            <> ", "
            <> jsUint8 msg
            <> ");"
            <> jsOut "new Uint8Array([ok ? 1 : 0])"
      actual `shouldBe` B.pack [1]

    it "TS sign -> Haskell verify" $ do
      let seed = B.pack [1 .. 32]
          sk = throwCryptoError $ Ed25519.secretKey seed
          pk = Ed25519.toPublic sk
          msg = "ts-to-haskell sign" :: B.ByteString
      rawSig <-
        callNode $
          impKey
            <> "const kp = K.ed25519KeyPairFromSeed("
            <> jsUint8 seed
            <> ");"
            <> jsOut ("K.sign(kp.privateKey, " <> jsUint8 msg <> ")")
      let sig = throwCryptoError $ Ed25519.signature rawSig
      Ed25519.verify pk msg sig `shouldBe` True

    it "verify rejects wrong message" $ do
      let seed = B.pack [1 .. 32]
          sk = throwCryptoError $ Ed25519.secretKey seed
          pk = Ed25519.toPublic sk
          msg = "original message" :: B.ByteString
          wrongMsg = "wrong message" :: B.ByteString
          sig = Ed25519.sign sk pk msg
          rawPub = BA.convert pk :: B.ByteString
          rawSig = BA.convert sig :: B.ByteString
      actual <-
        callNode $
          impKey
            <> "const ok = K.verify("
            <> jsUint8 rawPub
            <> ", "
            <> jsUint8 rawSig
            <> ", "
            <> jsUint8 wrongMsg
            <> ");"
            <> jsOut "new Uint8Array([ok ? 1 : 0])"
      actual `shouldBe` B.pack [0]

  describe "X25519 DH" $ do
    it "DH cross-language" $ do
      let seed1 = B.pack [1 .. 32]
          seed2 = B.pack [33 .. 64]
          sk1 = throwCryptoError $ X25519.secretKey seed1
          sk2 = throwCryptoError $ X25519.secretKey seed2
          pk2 = X25519.toPublic sk2
          dhHs = X25519.dh pk2 sk1
          rawPk2 = BA.convert pk2 :: B.ByteString
          rawDh = BA.convert dhHs :: B.ByteString
      actual <-
        callNode $
          impKey <> jsOut ("K.dh(" <> jsUint8 rawPk2 <> ", " <> jsUint8 seed1 <> ")")
      actual `shouldBe` rawDh

    it "DH commutativity" $ do
      let seed1 = B.pack [1 .. 32]
          seed2 = B.pack [33 .. 64]
          sk1 = throwCryptoError $ X25519.secretKey seed1
          pk1 = X25519.toPublic sk1
          sk2 = throwCryptoError $ X25519.secretKey seed2
          pk2 = X25519.toPublic sk2
          rawPk1 = BA.convert pk1 :: B.ByteString
          rawPk2 = BA.convert pk2 :: B.ByteString
      dh1 <-
        callNode $
          impKey <> jsOut ("K.dh(" <> jsUint8 rawPk2 <> ", " <> jsUint8 seed1 <> ")")
      dh2 <-
        callNode $
          impKey <> jsOut ("K.dh(" <> jsUint8 rawPk1 <> ", " <> jsUint8 seed2 <> ")")
      dh1 `shouldBe` dh2

  describe "keyHash" $ do
    it "keyHash matches Haskell sha256Hash of DER" $ do
      let rawPub = B.pack [1 .. 32]
          derPrefix = B.pack [0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00]
          der = derPrefix <> rawPub
          expectedHash = C.sha256Hash der
      actual <-
        callNode $
          impKey
            <> "const der = K.encodePubKeyEd25519("
            <> jsUint8 rawPub
            <> ");"
            <> jsOut "K.keyHash(der)"
      actual `shouldBe` expectedHash
