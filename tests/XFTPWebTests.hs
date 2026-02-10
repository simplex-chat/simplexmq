{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Per-function tests for the xftp-web TypeScript XFTP client library.
-- Each test calls the Haskell function and the corresponding TypeScript function
-- via node, then asserts byte-identical output.
--
-- Prerequisites: cd xftp-web && npm install && npm run build
-- Run: cabal test --test-option=--match="/XFTP Web Client/"
module XFTPWebTests (xftpWebTests) where

import Control.Concurrent (forkIO, newEmptyMVar, putMVar, takeMVar)
import Control.Monad (replicateM, when)
import Crypto.Error (throwCryptoError)
import qualified Crypto.PubKey.Curve25519 as X25519
import qualified Crypto.PubKey.Ed25519 as Ed25519
import qualified Data.ByteArray as BA
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as LB
import Data.Int (Int64)
import Data.List (intercalate)
import qualified Data.List.NonEmpty as NE
import Data.Word (Word8, Word16, Word32)
import System.Random (randomIO)
import Data.X509.Validation (Fingerprint (..))
import Simplex.FileTransfer.Client (prepareChunkSizes)
import Simplex.FileTransfer.Description (FileDescription (..), FileSize (..), ValidFileDescription, pattern ValidFileDescription)
import Simplex.FileTransfer.Protocol (FileParty (..), xftpBlockSize)
import Simplex.FileTransfer.Transport (XFTPClientHello (..))
import Simplex.FileTransfer.Types (FileHeader (..))
import qualified Simplex.Messaging.Crypto as C
import qualified Simplex.Messaging.Crypto.Lazy as LC
import Simplex.Messaging.Encoding
import Simplex.Messaging.Encoding.String (strDecode, strEncode)
import Simplex.Messaging.Transport.Server (loadFileFingerprint)
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, removeDirectoryRecursive)
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..))
import System.Process (CreateProcess (..), StdStream (..), createProcess, proc, waitForProcess)
import Test.Hspec hiding (fit, it)
import Util
import Simplex.FileTransfer.Server.Env (XFTPServerConfig)
import XFTPClient (testXFTPServerConfigEd25519SNI, testXFTPServerConfigSNI, withXFTPServerCfg, xftpTestPort)
import AgentTests.FunctionalAPITests (rfGet, runRight, runRight_, sfGet, withAgent)
import Simplex.Messaging.Agent (AgentClient, xftpReceiveFile, xftpSendFile, xftpStartWorkers)
import Simplex.Messaging.Agent.Protocol (AEvent (..))
import SMPAgentClient (agentCfg, initAgentServers, testDB)
import XFTPCLI (recipientFiles, senderFiles)
import qualified Simplex.Messaging.Crypto.File as CF

xftpWebDir :: FilePath
xftpWebDir = "xftp-web"

-- | Run an inline ES module script via node, return stdout as ByteString.
callNode :: String -> IO B.ByteString
callNode script = do
  baseEnv <- getEnvironment
  let nodeEnv = ("NODE_TLS_REJECT_UNAUTHORIZED", "0") : baseEnv
  (_, Just hout, Just herr, ph) <-
    createProcess
      (proc "node" ["--input-type=module", "-e", script])
        { std_out = CreatePipe,
          std_err = CreatePipe,
          cwd = Just xftpWebDir,
          env = Just nodeEnv
        }
  errVar <- newEmptyMVar
  _ <- forkIO $ B.hGetContents herr >>= putMVar errVar
  out <- B.hGetContents hout
  err <- takeMVar errVar
  ec <- waitForProcess ph
  when (ec /= ExitSuccess) $
    expectationFailure $
      "node " <> show ec <> "\nstderr: " <> map (toEnum . fromIntegral) (B.unpack err)
  pure out

-- | Format a ByteString as a JS Uint8Array constructor.
jsUint8 :: B.ByteString -> String
jsUint8 bs = "new Uint8Array([" <> intercalate "," (map show (B.unpack bs)) <> "])"

-- Import helpers for inline scripts.
impEnc, impPad, impDig, impKey, impSb :: String
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
impSb =
  "import sodium from 'libsodium-wrappers-sumo';"
    <> "import * as S from './dist/crypto/secretbox.js';"
    <> "await sodium.ready;"
impFile :: String
impFile =
  "import sodium from 'libsodium-wrappers-sumo';"
    <> "import * as F from './dist/crypto/file.js';"
    <> "await sodium.ready;"
impCmd :: String
impCmd =
  "import sodium from 'libsodium-wrappers-sumo';"
    <> "import * as E from './dist/protocol/encoding.js';"
    <> "import * as Cmd from './dist/protocol/commands.js';"
    <> "await sodium.ready;"
impTx :: String
impTx =
  "import sodium from 'libsodium-wrappers-sumo';"
    <> "import * as E from './dist/protocol/encoding.js';"
    <> "import * as K from './dist/crypto/keys.js';"
    <> "import * as Tx from './dist/protocol/transmission.js';"
    <> "await sodium.ready;"
impHs :: String
impHs =
  "import sodium from 'libsodium-wrappers-sumo';"
    <> "import * as E from './dist/protocol/encoding.js';"
    <> "import * as K from './dist/crypto/keys.js';"
    <> "import * as Hs from './dist/protocol/handshake.js';"
    <> "await sodium.ready;"
impId :: String
impId =
  "import sodium from 'libsodium-wrappers-sumo';"
    <> "import * as E from './dist/protocol/encoding.js';"
    <> "import * as K from './dist/crypto/keys.js';"
    <> "import * as Id from './dist/crypto/identity.js';"
    <> "await sodium.ready;"
impDesc :: String
impDesc = "import * as Desc from './dist/protocol/description.js';"
impChk :: String
impChk =
  "import sodium from 'libsodium-wrappers-sumo';"
    <> "import * as Desc from './dist/protocol/description.js';"
    <> "import * as Chk from './dist/protocol/chunks.js';"
    <> "await sodium.ready;"
impCli :: String
impCli =
  "import sodium from 'libsodium-wrappers-sumo';"
    <> "import * as K from './dist/crypto/keys.js';"
    <> "import * as Cli from './dist/protocol/client.js';"
    <> "await sodium.ready;"
impDl :: String
impDl =
  "import sodium from 'libsodium-wrappers-sumo';"
    <> "import * as K from './dist/crypto/keys.js';"
    <> "import * as F from './dist/crypto/file.js';"
    <> "import * as Cli from './dist/protocol/client.js';"
    <> "import * as Dl from './dist/download.js';"
    <> "import * as Cmd from './dist/protocol/commands.js';"
    <> "import * as Tx from './dist/protocol/transmission.js';"
    <> "await sodium.ready;"

impAddr :: String
impAddr = "import * as Addr from './dist/protocol/address.js';"

-- | Wrap expression in process.stdout.write(Buffer.from(...)).
jsOut :: String -> String
jsOut expr = "process.stdout.write(Buffer.from(" <> expr <> "));"

xftpWebTests :: Spec
xftpWebTests = do
  distExists <- runIO $ doesDirectoryExist (xftpWebDir <> "/dist")
  if distExists
    then do
      tsEncodingTests
      tsPaddingTests
      tsDigestTests
      tsKeyTests
      tsSecretboxTests
      tsFileCryptoTests
      tsCommandTests
      tsTransmissionTests
      tsHandshakeTests
      tsIdentityTests
      tsDescriptionTests
      tsChunkTests
      tsClientTests
      tsDownloadTests
      tsAddressTests
      tsIntegrationTests
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

-- ── crypto/secretbox ──────────────────────────────────────────────

tsSecretboxTests :: Spec
tsSecretboxTests = describe "crypto/secretbox" $ do
  let key32 = B.pack [1 .. 32]
      nonce24 = B.pack [1 .. 24]
      cbNonceVal = C.cbNonce nonce24
      sbKeyVal = C.unsafeSbKey key32

  describe "NaCl secretbox (tag prepended)" $ do
    it "cbEncrypt matches Haskell sbEncrypt_" $ do
      let msg = "hello NaCl secretbox" :: B.ByteString
          paddedLen = 256 :: Int
          hsResult = either (error . show) id $ C.sbEncrypt_ key32 cbNonceVal msg paddedLen
      tsResult <-
        callNode $
          impSb <> jsOut ("S.cbEncrypt(" <> jsUint8 key32 <> "," <> jsUint8 nonce24 <> "," <> jsUint8 msg <> "," <> show paddedLen <> ")")
      tsResult `shouldBe` hsResult

    it "Haskell sbEncrypt_ -> TS cbDecrypt" $ do
      let msg = "cross-language decrypt" :: B.ByteString
          paddedLen = 128 :: Int
          cipher = either (error . show) id $ C.sbEncrypt_ key32 cbNonceVal msg paddedLen
      tsResult <-
        callNode $
          impSb <> jsOut ("S.cbDecrypt(" <> jsUint8 key32 <> "," <> jsUint8 nonce24 <> "," <> jsUint8 cipher <> ")")
      tsResult `shouldBe` msg

    it "TS cbEncrypt -> Haskell sbDecrypt_" $ do
      let msg = "ts-to-haskell NaCl" :: B.ByteString
          paddedLen = 64 :: Int
      tsCipher <-
        callNode $
          impSb <> jsOut ("S.cbEncrypt(" <> jsUint8 key32 <> "," <> jsUint8 nonce24 <> "," <> jsUint8 msg <> "," <> show paddedLen <> ")")
      let hsResult = either (error . show) id $ C.sbDecrypt_ key32 cbNonceVal tsCipher
      hsResult `shouldBe` msg

  describe "streaming tail-tag" $ do
    it "sbEncryptTailTag matches Haskell" $ do
      let msg = "hello streaming" :: B.ByteString
          msgLen = fromIntegral (B.length msg) :: Int64
          paddedLen = 64 :: Int64
          hsResult =
            either (error . show) id $
              LC.sbEncryptTailTag sbKeyVal cbNonceVal (LB.fromStrict msg) msgLen paddedLen
      tsResult <-
        callNode $
          impSb
            <> jsOut
              ( "S.sbEncryptTailTag("
                  <> jsUint8 key32
                  <> ","
                  <> jsUint8 nonce24
                  <> ","
                  <> jsUint8 msg
                  <> ","
                  <> show msgLen
                  <> "n,"
                  <> show paddedLen
                  <> "n)"
              )
      tsResult `shouldBe` LB.toStrict hsResult

    it "Haskell encrypt -> TS decrypt (tail tag)" $ do
      let msg = "haskell-to-ts streaming" :: B.ByteString
          msgLen = fromIntegral (B.length msg) :: Int64
          paddedLen = 128 :: Int64
          cipher =
            either (error . show) id $
              LC.sbEncryptTailTag sbKeyVal cbNonceVal (LB.fromStrict msg) msgLen paddedLen
      tsResult <-
        callNode $
          impSb
            <> "const r = S.sbDecryptTailTag("
            <> jsUint8 key32
            <> ","
            <> jsUint8 nonce24
            <> ","
            <> show paddedLen
            <> "n,"
            <> jsUint8 (LB.toStrict cipher)
            <> ");"
            <> jsOut "new Uint8Array([r.valid ? 1 : 0, ...r.content])"
      let (validByte, content) = B.splitAt 1 tsResult
      validByte `shouldBe` B.pack [1]
      content `shouldBe` msg

    it "TS encrypt -> Haskell decrypt (tail tag)" $ do
      let msg = "ts-to-haskell streaming" :: B.ByteString
          msgLen = fromIntegral (B.length msg) :: Int64
          paddedLen = 64 :: Int64
      tsCipher <-
        callNode $
          impSb
            <> jsOut
              ( "S.sbEncryptTailTag("
                  <> jsUint8 key32
                  <> ","
                  <> jsUint8 nonce24
                  <> ","
                  <> jsUint8 msg
                  <> ","
                  <> show msgLen
                  <> "n,"
                  <> show paddedLen
                  <> "n)"
              )
      let (valid, plaintext) =
            either (error . show) id $
              LC.sbDecryptTailTag sbKeyVal cbNonceVal paddedLen (LB.fromStrict tsCipher)
      valid `shouldBe` True
      LB.toStrict plaintext `shouldBe` msg

    it "tag tampering detection" $ do
      let msg = "tamper test" :: B.ByteString
          msgLen = fromIntegral (B.length msg) :: Int64
          paddedLen = 64 :: Int64
      tsResult <-
        callNode $
          impSb
            <> "const enc = S.sbEncryptTailTag("
            <> jsUint8 key32
            <> ","
            <> jsUint8 nonce24
            <> ","
            <> jsUint8 msg
            <> ","
            <> show msgLen
            <> "n,"
            <> show paddedLen
            <> "n);"
            <> "enc[enc.length - 1] ^= 1;"
            <> "const r = S.sbDecryptTailTag("
            <> jsUint8 key32
            <> ","
            <> jsUint8 nonce24
            <> ","
            <> show paddedLen
            <> "n, enc);"
            <> jsOut "new Uint8Array([r.valid ? 1 : 0])"
      tsResult `shouldBe` B.pack [0]

  describe "internal consistency" $ do
    it "streaming matches NaCl secretbox (TS-only)" $ do
      let msg = "salsa20 validation" :: B.ByteString
          msgLen = fromIntegral (B.length msg) :: Int64
          paddedLen = 64 :: Int64
      tsResult <-
        callNode $
          impPad
            <> impSb
            <> "const msg = "
            <> jsUint8 msg
            <> ";"
            <> "const key = "
            <> jsUint8 key32
            <> ";"
            <> "const nonce = "
            <> jsUint8 nonce24
            <> ";"
            <> "const padded = P.padLazy(msg, "
            <> show msgLen
            <> "n, "
            <> show paddedLen
            <> "n);"
            <> "const nacl = S.cryptoBox(key, nonce, padded);"
            <> "const stream = S.sbEncryptTailTag(key, nonce, msg, "
            <> show msgLen
            <> "n, "
            <> show paddedLen
            <> "n);"
            <> "const naclTag = nacl.subarray(0, 16);"
            <> "const naclCipher = nacl.subarray(16);"
            <> "const streamCipher = stream.subarray(0, "
            <> show paddedLen
            <> ");"
            <> "const streamTag = stream.subarray("
            <> show paddedLen
            <> ");"
            <> "const cipherMatch = naclCipher.length === streamCipher.length && naclCipher.every((b,i) => b === streamCipher[i]);"
            <> "const tagMatch = naclTag.length === streamTag.length && naclTag.every((b,i) => b === streamTag[i]);"
            <> jsOut "new Uint8Array([cipherMatch ? 1 : 0, tagMatch ? 1 : 0])"
      tsResult `shouldBe` B.pack [1, 1]

    it "multi-chunk matches single-shot (TS-only)" $ do
      let msg = B.pack [1 .. 200]
      tsResult <-
        callNode $
          impSb
            <> "const key = "
            <> jsUint8 key32
            <> ";"
            <> "const nonce = "
            <> jsUint8 nonce24
            <> ";"
            <> "const msg = "
            <> jsUint8 msg
            <> ";"
            <> "const st1 = S.sbInit(key, nonce);"
            <> "const c1 = S.sbEncryptChunk(st1, msg);"
            <> "const t1 = S.sbAuth(st1);"
            <> "const st2 = S.sbInit(key, nonce);"
            <> "const parts = [msg.subarray(0,50), msg.subarray(50,100), msg.subarray(100,150), msg.subarray(150)];"
            <> "const c2parts = parts.map(p => S.sbEncryptChunk(st2, p));"
            <> "const c2 = new Uint8Array(200); let off = 0; c2parts.forEach(p => { c2.set(p, off); off += p.length; });"
            <> "const t2 = S.sbAuth(st2);"
            <> "const cipherMatch = c1.length === c2.length && c1.every((b,i) => b === c2[i]);"
            <> "const tagMatch = t1.length === t2.length && t1.every((b,i) => b === t2[i]);"
            <> jsOut "new Uint8Array([cipherMatch ? 1 : 0, tagMatch ? 1 : 0])"
      tsResult `shouldBe` B.pack [1, 1]

-- ── crypto/file ─────────────────────────────────────────────────

tsFileCryptoTests :: Spec
tsFileCryptoTests = describe "crypto/file" $ do
  let key32 = B.pack [1 .. 32]
      nonce24 = B.pack [1 .. 24]
      cbNonceVal = C.cbNonce nonce24
      sbKeyVal = C.unsafeSbKey key32

  describe "FileHeader encoding" $ do
    it "encodeFileHeader matches Haskell" $ do
      let hdr = FileHeader "test.txt" Nothing
          hsEncoded = smpEncode hdr
      tsEncoded <- callNode $ impFile <> jsOut "F.encodeFileHeader({fileName: 'test.txt', fileExtra: null})"
      tsEncoded `shouldBe` hsEncoded

    it "encodeFileHeader with fileExtra" $ do
      let hdr = FileHeader "document.pdf" (Just "v2")
          hsEncoded = smpEncode hdr
      tsEncoded <- callNode $ impFile <> jsOut "F.encodeFileHeader({fileName: 'document.pdf', fileExtra: 'v2'})"
      tsEncoded `shouldBe` hsEncoded

    it "Haskell encode -> TS parseFileHeader" $ do
      let hdr = FileHeader "photo.jpg" (Just "extra")
          encoded = smpEncode hdr
          trailing = B.pack [10, 20, 30, 40, 50]
          input = encoded <> trailing
      tsResult <-
        callNode $
          impFile
            <> "const r = F.parseFileHeader("
            <> jsUint8 input
            <> ");"
            <> "const hdrBytes = F.encodeFileHeader(r.header);"
            <> jsOut "new Uint8Array([...hdrBytes, ...r.rest])"
      tsResult `shouldBe` input

  describe "file encryption" $ do
    it "encryptFile matches Haskell" $ do
      let source = "Hello, this is test file content!" :: B.ByteString
          hdr = FileHeader "test.txt" Nothing
          fileHdr = smpEncode hdr
          fileSize' = fromIntegral (B.length fileHdr + B.length source) :: Int64
          encSize = 256 :: Int64
          sb = either (error . show) id $ LC.sbInit sbKeyVal cbNonceVal
          lenStr = smpEncode fileSize'
          (hdrEnc, sb1) = LC.sbEncryptChunk sb (lenStr <> fileHdr)
          (srcEnc, sb2) = LC.sbEncryptChunk sb1 source
          padLen = encSize - 16 - fileSize' - 8
          padding = B.replicate (fromIntegral padLen) 0x23
          (padEnc, sb3) = LC.sbEncryptChunk sb2 padding
          tag = BA.convert (LC.sbAuth sb3) :: B.ByteString
          hsEncrypted = B.concat [hdrEnc, srcEnc, padEnc, tag]
      tsEncrypted <-
        callNode $
          impFile
            <> "const source = "
            <> jsUint8 source
            <> ";"
            <> "const fileHdr = F.encodeFileHeader({fileName: 'test.txt', fileExtra: null});"
            <> jsOut
              ( "F.encryptFile(source, fileHdr, "
                  <> jsUint8 key32
                  <> ","
                  <> jsUint8 nonce24
                  <> ","
                  <> show fileSize'
                  <> "n,"
                  <> show encSize
                  <> "n)"
              )
      tsEncrypted `shouldBe` hsEncrypted

    it "Haskell encrypt -> TS decryptChunks" $ do
      let source = "cross-language file test data" :: B.ByteString
          hdr = FileHeader "data.bin" (Just "meta")
          fileHdr = smpEncode hdr
          fileSize' = fromIntegral (B.length fileHdr + B.length source) :: Int64
          encSize = 128 :: Int64
          sb = either (error . show) id $ LC.sbInit sbKeyVal cbNonceVal
          lenStr = smpEncode fileSize'
          (hdrEnc, sb1) = LC.sbEncryptChunk sb (lenStr <> fileHdr)
          (srcEnc, sb2) = LC.sbEncryptChunk sb1 source
          padLen = encSize - 16 - fileSize' - 8
          padding = B.replicate (fromIntegral padLen) 0x23
          (padEnc, sb3) = LC.sbEncryptChunk sb2 padding
          tag = BA.convert (LC.sbAuth sb3) :: B.ByteString
          encrypted = B.concat [hdrEnc, srcEnc, padEnc, tag]
      tsResult <-
        callNode $
          impFile
            <> "const r = F.decryptChunks("
            <> show encSize
            <> "n, ["
            <> jsUint8 encrypted
            <> "], "
            <> jsUint8 key32
            <> ","
            <> jsUint8 nonce24
            <> ");"
            <> "const hdrBytes = F.encodeFileHeader(r.header);"
            <> jsOut "new Uint8Array([...hdrBytes, ...r.content])"
      tsResult `shouldBe` (fileHdr <> source)

    it "TS encryptFile -> Haskell decrypt" $ do
      let source = "ts-to-haskell file" :: B.ByteString
          hdr = FileHeader "note.txt" Nothing
          fileHdr = smpEncode hdr
          fileSize' = fromIntegral (B.length fileHdr + B.length source) :: Int64
          encSize = 128 :: Int64
          paddedLen = encSize - 16
      tsEncrypted <-
        callNode $
          impFile
            <> "const source = "
            <> jsUint8 source
            <> ";"
            <> "const fileHdr = F.encodeFileHeader({fileName: 'note.txt', fileExtra: null});"
            <> jsOut
              ( "F.encryptFile(source, fileHdr, "
                  <> jsUint8 key32
                  <> ","
                  <> jsUint8 nonce24
                  <> ","
                  <> show fileSize'
                  <> "n,"
                  <> show encSize
                  <> "n)"
              )
      let (valid, plaintext) =
            either (error . show) id $
              LC.sbDecryptTailTag sbKeyVal cbNonceVal paddedLen (LB.fromStrict tsEncrypted)
      valid `shouldBe` True
      LB.toStrict plaintext `shouldBe` (fileHdr <> source)

    it "multi-chunk decrypt" $ do
      let source = "multi-chunk file content" :: B.ByteString
          hdr = FileHeader "multi.bin" Nothing
          fileHdr = smpEncode hdr
          fileSize' = fromIntegral (B.length fileHdr + B.length source) :: Int64
          encSize = 128 :: Int64
          sb = either (error . show) id $ LC.sbInit sbKeyVal cbNonceVal
          lenStr = smpEncode fileSize'
          (hdrEnc, sb1) = LC.sbEncryptChunk sb (lenStr <> fileHdr)
          (srcEnc, sb2) = LC.sbEncryptChunk sb1 source
          padLen = encSize - 16 - fileSize' - 8
          padding = B.replicate (fromIntegral padLen) 0x23
          (padEnc, sb3) = LC.sbEncryptChunk sb2 padding
          tag = BA.convert (LC.sbAuth sb3) :: B.ByteString
          encrypted = B.concat [hdrEnc, srcEnc, padEnc, tag]
          (chunk1, rest) = B.splitAt 50 encrypted
          (chunk2, chunk3) = B.splitAt 50 rest
      tsResult <-
        callNode $
          impFile
            <> "const r = F.decryptChunks("
            <> show encSize
            <> "n, ["
            <> jsUint8 chunk1
            <> ","
            <> jsUint8 chunk2
            <> ","
            <> jsUint8 chunk3
            <> "], "
            <> jsUint8 key32
            <> ","
            <> jsUint8 nonce24
            <> ");"
            <> "const hdrBytes = F.encodeFileHeader(r.header);"
            <> jsOut "new Uint8Array([...hdrBytes, ...r.content])"
      tsResult `shouldBe` (fileHdr <> source)

    it "auth tag tampering detection" $ do
      let source = "tamper detection file" :: B.ByteString
          hdr = FileHeader "secret.dat" Nothing
          fileHdr = smpEncode hdr
          fileSize' = fromIntegral (B.length fileHdr + B.length source) :: Int64
          encSize = 128 :: Int64
          sb = either (error . show) id $ LC.sbInit sbKeyVal cbNonceVal
          lenStr = smpEncode fileSize'
          (hdrEnc, sb1) = LC.sbEncryptChunk sb (lenStr <> fileHdr)
          (srcEnc, sb2) = LC.sbEncryptChunk sb1 source
          padLen = encSize - 16 - fileSize' - 8
          padding = B.replicate (fromIntegral padLen) 0x23
          (padEnc, sb3) = LC.sbEncryptChunk sb2 padding
          tag = BA.convert (LC.sbAuth sb3) :: B.ByteString
          encrypted = B.concat [hdrEnc, srcEnc, padEnc, tag]
      tsResult <-
        callNode $
          impFile
            <> "const enc = "
            <> jsUint8 encrypted
            <> ";"
            <> "enc[enc.length - 1] ^= 1;"
            <> "let ok = 0;"
            <> "try { F.decryptChunks("
            <> show encSize
            <> "n, [enc], "
            <> jsUint8 key32
            <> ","
            <> jsUint8 nonce24
            <> "); ok = 1; } catch(e) { ok = 0; }"
            <> jsOut "new Uint8Array([ok])"
      tsResult `shouldBe` B.pack [0]

-- ── protocol/commands ────────────────────────────────────────────

tsCommandTests :: Spec
tsCommandTests = describe "protocol/commands" $ do
  let sndKey = B.pack [1 .. 8]
      rcvKey1 = B.pack [11 .. 18]
      rcvKey2 = B.pack [21 .. 28]
      digest = B.pack [31 .. 38]
      size32 = 12345 :: Word32
      authKey = B.pack [41 .. 48]
      dhKey = B.pack [51 .. 58]

  describe "encode" $ do
    it "encodeFileInfo" $ do
      let expected = smpEncode sndKey <> smpEncode size32 <> smpEncode digest
      tsResult <-
        callNode $
          impCmd
            <> "const fi = {sndKey: "
            <> jsUint8 sndKey
            <> ", size: "
            <> show size32
            <> ", digest: "
            <> jsUint8 digest
            <> "};"
            <> jsOut "Cmd.encodeFileInfo(fi)"
      tsResult `shouldBe` expected

    it "encodeFNEW with auth" $ do
      let fileInfo = smpEncode sndKey <> smpEncode size32 <> smpEncode digest
          rcvKeys = smpEncodeList [rcvKey1, rcvKey2]
          auth = B.singleton 0x31 <> smpEncode authKey
          expected = "FNEW " <> fileInfo <> rcvKeys <> auth
      tsResult <-
        callNode $
          impCmd
            <> "const fi = {sndKey: "
            <> jsUint8 sndKey
            <> ", size: "
            <> show size32
            <> ", digest: "
            <> jsUint8 digest
            <> "};"
            <> "const rks = ["
            <> jsUint8 rcvKey1
            <> ","
            <> jsUint8 rcvKey2
            <> "];"
            <> jsOut ("Cmd.encodeFNEW(fi, rks, " <> jsUint8 authKey <> ")")
      tsResult `shouldBe` expected

    it "encodeFNEW without auth" $ do
      let fileInfo = smpEncode sndKey <> smpEncode size32 <> smpEncode digest
          rcvKeys = smpEncodeList [rcvKey1]
          expected = "FNEW " <> fileInfo <> rcvKeys <> "0"
      tsResult <-
        callNode $
          impCmd
            <> "const fi = {sndKey: "
            <> jsUint8 sndKey
            <> ", size: "
            <> show size32
            <> ", digest: "
            <> jsUint8 digest
            <> "};"
            <> "const rks = ["
            <> jsUint8 rcvKey1
            <> "];"
            <> jsOut "Cmd.encodeFNEW(fi, rks, null)"
      tsResult `shouldBe` expected

    it "encodeFADD" $ do
      let expected = "FADD " <> smpEncodeList [rcvKey1, rcvKey2]
      tsResult <-
        callNode $
          impCmd
            <> jsOut ("Cmd.encodeFADD([" <> jsUint8 rcvKey1 <> "," <> jsUint8 rcvKey2 <> "])")
      tsResult `shouldBe` expected

    it "encodeFPUT" $ do
      tsResult <- callNode $ impCmd <> jsOut "Cmd.encodeFPUT()"
      tsResult `shouldBe` "FPUT"

    it "encodeFDEL" $ do
      tsResult <- callNode $ impCmd <> jsOut "Cmd.encodeFDEL()"
      tsResult `shouldBe` "FDEL"

    it "encodeFGET" $ do
      let expected = "FGET " <> smpEncode dhKey
      tsResult <-
        callNode $
          impCmd <> jsOut ("Cmd.encodeFGET(" <> jsUint8 dhKey <> ")")
      tsResult `shouldBe` expected

    it "encodePING" $ do
      tsResult <- callNode $ impCmd <> jsOut "Cmd.encodePING()"
      tsResult `shouldBe` "PING"

  describe "decode" $ do
    it "decodeResponse OK" $ do
      tsResult <-
        callNode $
          impCmd
            <> "const r = Cmd.decodeResponse("
            <> jsUint8 ("OK" :: B.ByteString)
            <> ");"
            <> jsOut "new Uint8Array([r.type === 'FROk' ? 1 : 0])"
      tsResult `shouldBe` B.pack [1]

    it "decodeResponse PONG" $ do
      tsResult <-
        callNode $
          impCmd
            <> "const r = Cmd.decodeResponse("
            <> jsUint8 ("PONG" :: B.ByteString)
            <> ");"
            <> jsOut "new Uint8Array([r.type === 'FRPong' ? 1 : 0])"
      tsResult `shouldBe` B.pack [1]

    it "decodeResponse ERR AUTH" $ do
      tsResult <-
        callNode $
          impCmd
            <> "const r = Cmd.decodeResponse("
            <> jsUint8 ("ERR AUTH" :: B.ByteString)
            <> ");"
            <> jsOut "new Uint8Array([r.type === 'FRErr' && r.err.type === 'AUTH' ? 1 : 0])"
      tsResult `shouldBe` B.pack [1]

    it "decodeResponse ERR CMD SYNTAX" $ do
      tsResult <-
        callNode $
          impCmd
            <> "const r = Cmd.decodeResponse("
            <> jsUint8 ("ERR CMD SYNTAX" :: B.ByteString)
            <> ");"
            <> jsOut "new Uint8Array([r.type === 'FRErr' && r.err.type === 'CMD' && r.err.cmdErr === 'SYNTAX' ? 1 : 0])"
      tsResult `shouldBe` B.pack [1]

    it "decodeResponse SIDS" $ do
      let senderId = B.pack [1 .. 24]
          rId1 = B.pack [25 .. 48]
          rId2 = B.pack [49 .. 72]
          sidsBytes = "SIDS " <> smpEncode senderId <> smpEncodeList [rId1, rId2]
      tsResult <-
        callNode $
          impCmd
            <> "const r = Cmd.decodeResponse("
            <> jsUint8 sidsBytes
            <> ");"
            <> "if (r.type !== 'FRSndIds') throw new Error('wrong type');"
            <> jsOut "E.concatBytes(r.senderId, ...r.recipientIds)"
      tsResult `shouldBe` (senderId <> rId1 <> rId2)

    it "decodeResponse RIDS" $ do
      let rId1 = B.pack [1 .. 16]
          rId2 = B.pack [17 .. 32]
          ridsBytes = "RIDS " <> smpEncodeList [rId1, rId2]
      tsResult <-
        callNode $
          impCmd
            <> "const r = Cmd.decodeResponse("
            <> jsUint8 ridsBytes
            <> ");"
            <> "if (r.type !== 'FRRcvIds') throw new Error('wrong type');"
            <> jsOut "E.concatBytes(...r.recipientIds)"
      tsResult `shouldBe` (rId1 <> rId2)

    it "decodeResponse FILE" $ do
      let rawPub = B.pack [1 .. 32]
          x25519Der = B.pack [0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x6e, 0x03, 0x21, 0x00]
          derKey = x25519Der <> rawPub
          nonce = B.pack [201 .. 224]
          fileBytes = "FILE " <> smpEncode derKey <> nonce
      tsResult <-
        callNode $
          impCmd
            <> "const r = Cmd.decodeResponse("
            <> jsUint8 fileBytes
            <> ");"
            <> "if (r.type !== 'FRFile') throw new Error('wrong type: ' + r.type);"
            <> jsOut "E.concatBytes(r.rcvDhKey, r.nonce)"
      tsResult `shouldBe` (rawPub <> nonce)

-- ── protocol/transmission ──────────────────────────────────────────

tsTransmissionTests :: Spec
tsTransmissionTests = describe "protocol/transmission" $ do
  describe "blockPad / blockUnpad" $ do
    it "blockPad matches C.pad" $ do
      let msg = "hello pad test" :: B.ByteString
          blockSize = 256 :: Int
          hsPadded = either (error . show) id $ C.pad msg blockSize
      tsPadded <-
        callNode $
          impTx <> jsOut ("Tx.blockPad(" <> jsUint8 msg <> ", " <> show blockSize <> ")")
      tsPadded `shouldBe` hsPadded

    it "Haskell C.pad -> TS blockUnpad" $ do
      let msg = "cross-language unpad" :: B.ByteString
          blockSize = 128 :: Int
          hsPadded = either (error . show) id $ C.pad msg blockSize
      tsResult <-
        callNode $
          impTx <> jsOut ("Tx.blockUnpad(" <> jsUint8 hsPadded <> ")")
      tsResult `shouldBe` msg

    it "TS blockPad -> Haskell C.unPad" $ do
      let msg = "ts-to-haskell pad" :: B.ByteString
          blockSize = 128 :: Int
      tsPadded <-
        callNode $
          impTx <> jsOut ("Tx.blockPad(" <> jsUint8 msg <> ", " <> show blockSize <> ")")
      let hsResult = either (error . show) id $ C.unPad tsPadded
      hsResult `shouldBe` msg

  describe "transmission encoding" $ do
    it "encodeTransmission unsigned (PING)" $ do
      let sessionId = B.pack [201 .. 232]
          corrId = "abc" :: B.ByteString
          entityId = "" :: B.ByteString
          cmdBytes = "PING" :: B.ByteString
          -- implySessId = False: sessionId on wire
          tWire = smpEncode sessionId <> smpEncode corrId <> smpEncode entityId <> cmdBytes
          authenticator = smpEncode ("" :: B.ByteString)
          encoded = authenticator <> tWire
          batch = B.singleton 1 <> smpEncode (Large encoded)
          expected = either (error . show) id $ C.pad batch 16384
      tsResult <-
        callNode $
          impTx
            <> jsOut
              ( "Tx.encodeTransmission("
                  <> jsUint8 sessionId
                  <> ", "
                  <> jsUint8 corrId
                  <> ", "
                  <> jsUint8 entityId
                  <> ", "
                  <> jsUint8 cmdBytes
                  <> ")"
              )
      tsResult `shouldBe` expected

    it "encodeAuthTransmission signed" $ do
      let seed = B.pack [1 .. 32]
          sk = throwCryptoError $ Ed25519.secretKey seed
          pk = Ed25519.toPublic sk
          sessionId = B.pack [101 .. 132]
          corrId = "xyz" :: B.ByteString
          entityId = B.pack [1 .. 24]
          cmdBytes = "FPUT" :: B.ByteString
          tInner = smpEncode corrId <> smpEncode entityId <> cmdBytes
          tForAuth = smpEncode sessionId <> tInner
          sig = Ed25519.sign sk pk tForAuth
          rawSig = BA.convert sig :: B.ByteString
          authenticator = smpEncode rawSig
          -- implySessId = False: tToSend = tForAuth (sessionId on wire)
          encoded = authenticator <> tForAuth
          batch = B.singleton 1 <> smpEncode (Large encoded)
          expected = either (error . show) id $ C.pad batch 16384
      tsResult <-
        callNode $
          impTx
            <> "const kp = K.ed25519KeyPairFromSeed("
            <> jsUint8 seed
            <> ");"
            <> jsOut
              ( "Tx.encodeAuthTransmission("
                  <> jsUint8 sessionId
                  <> ", "
                  <> jsUint8 corrId
                  <> ", "
                  <> jsUint8 entityId
                  <> ", "
                  <> jsUint8 cmdBytes
                  <> ", kp.privateKey)"
              )
      tsResult `shouldBe` expected

    it "decodeTransmission" $ do
      let sessionId = B.pack [201 .. 232]
          corrId = "r01" :: B.ByteString
          entityId = B.pack [1 .. 16]
          cmdBytes = "OK" :: B.ByteString
          -- implySessId = False: sessionId on wire
          tWire = smpEncode sessionId <> smpEncode corrId <> smpEncode entityId <> cmdBytes
          authenticator = smpEncode ("" :: B.ByteString)
          encoded = authenticator <> tWire
          batch = B.singleton 1 <> smpEncode (Large encoded)
          block = either (error . show) id $ C.pad batch 256
      tsResult <-
        callNode $
          impTx
            <> "const t = Tx.decodeTransmission("
            <> jsUint8 sessionId
            <> ", "
            <> jsUint8 block
            <> ");"
            <> jsOut "E.concatBytes(t.corrId, t.entityId, t.command)"
      tsResult `shouldBe` (corrId <> entityId <> cmdBytes)

-- ── protocol/handshake ────────────────────────────────────────────

tsHandshakeTests :: Spec
tsHandshakeTests = describe "protocol/handshake" $ do
  describe "version range" $ do
    it "encodeVersionRange" $ do
      let expected = smpEncode (1 :: Word16) <> smpEncode (3 :: Word16)
      tsResult <-
        callNode $
          impHs
            <> jsOut "Hs.encodeVersionRange({minVersion: 1, maxVersion: 3})"
      tsResult `shouldBe` expected

    it "decodeVersionRange" $ do
      let vrBytes = smpEncode (2 :: Word16) <> smpEncode (5 :: Word16)
      tsResult <-
        callNode $
          impHs
            <> "const d = new E.Decoder("
            <> jsUint8 vrBytes
            <> ");"
            <> "const vr = Hs.decodeVersionRange(d);"
            <> jsOut "E.concatBytes(E.encodeWord16(vr.minVersion), E.encodeWord16(vr.maxVersion))"
      tsResult `shouldBe` vrBytes

    it "compatibleVRange (compatible)" $ do
      -- intersection of [1,3] and [2,5] = [2,3]
      let expected = smpEncode (2 :: Word16) <> smpEncode (3 :: Word16)
      tsResult <-
        callNode $
          impHs
            <> "const r = Hs.compatibleVRange({minVersion:1,maxVersion:3},{minVersion:2,maxVersion:5});"
            <> "if (!r) throw new Error('expected compatible');"
            <> jsOut "Hs.encodeVersionRange(r)"
      tsResult `shouldBe` expected

    it "compatibleVRange (incompatible)" $ do
      tsResult <-
        callNode $
          impHs
            <> "const r = Hs.compatibleVRange({minVersion:1,maxVersion:2},{minVersion:3,maxVersion:5});"
            <> jsOut "new Uint8Array([r === null ? 1 : 0])"
      tsResult `shouldBe` B.pack [1]

  describe "client handshake" $ do
    it "encodeClientHandshake" $ do
      let kh = B.pack [1 .. 32]
          body = smpEncode (3 :: Word16) <> smpEncode kh
          expected = either (error . show) id $ C.pad body 16384
      tsResult <-
        callNode $
          impHs
            <> jsOut ("Hs.encodeClientHandshake({xftpVersion:3,keyHash:" <> jsUint8 kh <> "})")
      tsResult `shouldBe` expected

  describe "client hello" $ do
    it "encodeClientHello (Nothing)" $ do
      let expected = smpEncode (XFTPClientHello {webChallenge = Nothing})
      tsResult <-
        callNode $
          impHs
            <> jsOut "Hs.encodeClientHello({webChallenge: null})"
      tsResult `shouldBe` expected

    it "encodeClientHello (Just challenge)" $ do
      let challenge = B.pack [1 .. 32]
          expected = either (error . show) id $ C.pad (smpEncode (XFTPClientHello {webChallenge = Just challenge})) xftpBlockSize
      tsResult <-
        callNode $
          impHs
            <> jsOut ("Hs.encodeClientHello({webChallenge:" <> jsUint8 challenge <> "})")
      tsResult `shouldBe` expected

  describe "server handshake" $ do
    it "decodeServerHandshake" $ do
      let sessId = B.pack [1 .. 32]
          cert1 = B.pack [101 .. 200] -- 100 bytes
          cert2 = B.pack [201 .. 232] -- 32 bytes
          signedKeyBytes = B.pack [1 .. 120]
          -- Encode server handshake body matching Haskell wire format:
          -- smpEncode (versionRange, sessionId, certChainPubKey)
          -- where certChainPubKey = (NonEmpty Large certChain, Large signedKey)
          body =
            smpEncode (1 :: Word16)
              <> smpEncode (3 :: Word16)
              <> smpEncode sessId
              <> smpEncode (NE.fromList [Large cert1, Large cert2])
              <> smpEncode (Large signedKeyBytes)
          serverBlock = either (error . show) id $ C.pad body 16384
      tsResult <-
        callNode $
          impHs
            <> "const hs = Hs.decodeServerHandshake("
            <> jsUint8 serverBlock
            <> ");"
            <> jsOut
              ( "E.concatBytes("
                  <> "E.encodeWord16(hs.xftpVersionRange.minVersion),"
                  <> "E.encodeWord16(hs.xftpVersionRange.maxVersion),"
                  <> "hs.sessionId,"
                  <> "...hs.certChainDer,"
                  <> "hs.signedKeyDer)"
              )
      -- Expected: vmin(2) + vmax(2) + sessId(32) + cert1(100) + cert2(32) + signedKey(120) = 288 bytes
      tsResult
        `shouldBe` ( smpEncode (1 :: Word16)
                      <> smpEncode (3 :: Word16)
                      <> sessId
                      <> cert1
                      <> cert2
                      <> signedKeyBytes
                   )

    it "decodeServerHandshake with webIdentityProof" $ do
      let sessId = B.pack [1 .. 32]
          cert1 = B.pack [101 .. 200]
          cert2 = B.pack [201 .. 232]
          signedKeyBytes = B.pack [1 .. 120]
          sigBytes = B.pack [1 .. 64]
          body =
            smpEncode (1 :: Word16)
              <> smpEncode (3 :: Word16)
              <> smpEncode sessId
              <> smpEncode (NE.fromList [Large cert1, Large cert2])
              <> smpEncode (Large signedKeyBytes)
              <> smpEncode sigBytes
          serverBlock = either (error . show) id $ C.pad body 16384
      tsResult <-
        callNode $
          impHs
            <> "const hs = Hs.decodeServerHandshake("
            <> jsUint8 serverBlock
            <> ");"
            <> jsOut "hs.webIdentityProof || new Uint8Array(0)"
      tsResult `shouldBe` sigBytes

    it "decodeServerHandshake without webIdentityProof" $ do
      let sessId = B.pack [1 .. 32]
          cert1 = B.pack [101 .. 200]
          cert2 = B.pack [201 .. 232]
          signedKeyBytes = B.pack [1 .. 120]
          body =
            smpEncode (1 :: Word16)
              <> smpEncode (3 :: Word16)
              <> smpEncode sessId
              <> smpEncode (NE.fromList [Large cert1, Large cert2])
              <> smpEncode (Large signedKeyBytes)
              <> smpEncode ("" :: B.ByteString)
          serverBlock = either (error . show) id $ C.pad body 16384
      tsResult <-
        callNode $
          impHs
            <> "const hs = Hs.decodeServerHandshake("
            <> jsUint8 serverBlock
            <> ");"
            <> jsOut "new Uint8Array([hs.webIdentityProof === null ? 1 : 0])"
      tsResult `shouldBe` B.pack [1]

  describe "certificate utilities" $ do
    it "caFingerprint" $ do
      let cert1 = B.pack [101 .. 200]
          cert2 = B.pack [201 .. 232]
          expected = C.sha256Hash cert2
      tsResult <-
        callNode $
          impHs
            <> "const chain = ["
            <> jsUint8 cert1
            <> ","
            <> jsUint8 cert2
            <> "];"
            <> jsOut "Hs.caFingerprint(chain)"
      tsResult `shouldBe` expected

    it "caFingerprint 3 certs" $ do
      let cert1 = B.pack [1 .. 10]
          cert2 = B.pack [11 .. 20]
          cert3 = B.pack [21 .. 30]
          expected = C.sha256Hash cert2
      tsResult <-
        callNode $
          impHs
            <> "const chain = ["
            <> jsUint8 cert1
            <> ","
            <> jsUint8 cert2
            <> ","
            <> jsUint8 cert3
            <> "];"
            <> jsOut "Hs.caFingerprint(chain)"
      tsResult `shouldBe` expected

    it "chainIdCaCerts 2 certs" $ do
      let cert1 = B.pack [1 .. 10]
          cert2 = B.pack [11 .. 20]
      tsResult <-
        callNode $
          impHs
            <> "const cc = Hs.chainIdCaCerts(["
            <> jsUint8 cert1
            <> ","
            <> jsUint8 cert2
            <> "]);"
            <> "if (cc.type !== 'valid') throw new Error('expected valid');"
            <> jsOut "E.concatBytes(cc.leafCert, cc.idCert, cc.caCert)"
      tsResult `shouldBe` (cert1 <> cert2 <> cert2)

    it "chainIdCaCerts 3 certs" $ do
      let cert1 = B.pack [1 .. 10]
          cert2 = B.pack [11 .. 20]
          cert3 = B.pack [21 .. 30]
      tsResult <-
        callNode $
          impHs
            <> "const cc = Hs.chainIdCaCerts(["
            <> jsUint8 cert1
            <> ","
            <> jsUint8 cert2
            <> ","
            <> jsUint8 cert3
            <> "]);"
            <> "if (cc.type !== 'valid') throw new Error('expected valid');"
            <> jsOut "E.concatBytes(cc.leafCert, cc.idCert, cc.caCert)"
      tsResult `shouldBe` (cert1 <> cert2 <> cert3)

    it "chainIdCaCerts 4 certs" $ do
      let cert1 = B.pack [1 .. 10]
          cert2 = B.pack [11 .. 20]
          cert3 = B.pack [21 .. 30]
          cert4 = B.pack [31 .. 40]
      tsResult <-
        callNode $
          impHs
            <> "const cc = Hs.chainIdCaCerts(["
            <> jsUint8 cert1
            <> ","
            <> jsUint8 cert2
            <> ","
            <> jsUint8 cert3
            <> ","
            <> jsUint8 cert4
            <> "]);"
            <> "if (cc.type !== 'valid') throw new Error('expected valid');"
            <> jsOut "E.concatBytes(cc.leafCert, cc.idCert, cc.caCert)"
      tsResult `shouldBe` (cert1 <> cert2 <> cert4)

  describe "SignedExact parsing" $ do
    it "extractSignedKey" $ do
      -- Generate signing key (Ed25519)
      let signSeed = B.pack [1 .. 32]
          signSk = throwCryptoError $ Ed25519.secretKey signSeed
          signPk = Ed25519.toPublic signSk
          signPkRaw = BA.convert signPk :: B.ByteString
          -- Generate DH key (X25519)
          dhSeed = B.pack [41 .. 72]
          dhSk = throwCryptoError $ X25519.secretKey dhSeed
          dhPk = X25519.toPublic dhSk
          dhPkRaw = BA.convert dhPk :: B.ByteString
          -- SubjectPublicKeyInfo DER for X25519 (44 bytes)
          x25519Prefix = B.pack [0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x6e, 0x03, 0x21, 0x00]
          spkiDer = x25519Prefix <> dhPkRaw
          -- Sign the SPKI with Ed25519
          sig = Ed25519.sign signSk signPk spkiDer
          sigRaw = BA.convert sig :: B.ByteString
          -- AlgorithmIdentifier for Ed25519 (7 bytes)
          algId = B.pack [0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70]
          -- BIT STRING wrapper (3 + 64 = 67 bytes)
          bitString = B.pack [0x03, 0x41, 0x00] <> sigRaw
          -- Outer SEQUENCE: content = 44 + 7 + 67 = 118 = 0x76
          content = spkiDer <> algId <> bitString
          signedExactDer = B.pack [0x30, 0x76] <> content
      tsResult <-
        callNode $
          impHs
            <> "const sk = Hs.extractSignedKey("
            <> jsUint8 signedExactDer
            <> ");"
            <> jsOut "E.concatBytes(sk.dhKey, sk.signature)"
      -- dhKey (32) + signature (64) = 96 bytes
      tsResult `shouldBe` (dhPkRaw <> sigRaw)

    it "extractSignedKey signature verifies" $ do
      let signSeed = B.pack [1 .. 32]
          signSk = throwCryptoError $ Ed25519.secretKey signSeed
          signPk = Ed25519.toPublic signSk
          signPkRaw = BA.convert signPk :: B.ByteString
          dhSeed = B.pack [41 .. 72]
          dhSk = throwCryptoError $ X25519.secretKey dhSeed
          dhPk = X25519.toPublic dhSk
          dhPkRaw = BA.convert dhPk :: B.ByteString
          x25519Prefix = B.pack [0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x6e, 0x03, 0x21, 0x00]
          spkiDer = x25519Prefix <> dhPkRaw
          sig = Ed25519.sign signSk signPk spkiDer
          sigRaw = BA.convert sig :: B.ByteString
          algId = B.pack [0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70]
          bitString = B.pack [0x03, 0x41, 0x00] <> sigRaw
          content = spkiDer <> algId <> bitString
          signedExactDer = B.pack [0x30, 0x76] <> content
      tsResult <-
        callNode $
          impHs
            <> "const sk = Hs.extractSignedKey("
            <> jsUint8 signedExactDer
            <> ");"
            <> "const ok = K.verify("
            <> jsUint8 signPkRaw
            <> ", sk.signature, sk.objectDer);"
            <> jsOut "new Uint8Array([ok ? 1 : 0])"
      tsResult `shouldBe` B.pack [1]

-- ── crypto/identity ──────────────────────────────────────────────

-- Construct a minimal X.509 certificate DER with an Ed25519 public key.
-- Structurally valid for DER navigation but not a real certificate.
mkFakeCertDer :: B.ByteString -> B.ByteString
mkFakeCertDer pubKey32 =
  let spki = B.pack [0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00] <> pubKey32
      tbsContents =
        B.concat
          [ B.pack [0xa0, 0x03, 0x02, 0x01, 0x02],
            B.pack [0x02, 0x01, 0x01],
            B.pack [0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70],
            B.pack [0x30, 0x00],
            B.pack [0x30, 0x00],
            B.pack [0x30, 0x00],
            spki
          ]
      tbs = B.pack [0x30, fromIntegral $ B.length tbsContents] <> tbsContents
      certContents =
        B.concat
          [ tbs,
            B.pack [0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70],
            B.pack [0x03, 0x41, 0x00] <> B.replicate 64 0
          ]
      certLen = B.length certContents
   in B.pack [0x30, 0x81, fromIntegral certLen] <> certContents

tsIdentityTests :: Spec
tsIdentityTests = describe "crypto/identity" $ do
  describe "extractCertPublicKeyInfo" $ do
    it "extracts SPKI from X.509 DER" $ do
      let pubKey = B.pack [1 .. 32]
          certDer = mkFakeCertDer pubKey
          expectedSpki = B.pack [0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00] <> pubKey
      tsResult <-
        callNode $
          impId
            <> jsOut ("Id.extractCertPublicKeyInfo(" <> jsUint8 certDer <> ")")
      tsResult `shouldBe` expectedSpki

    it "extractCertPublicKeyInfo + decodePubKey returns raw 32-byte key" $ do
      let pubKey = B.pack [1 .. 32]
          certDer = mkFakeCertDer pubKey
      tsResult <-
        callNode $
          impId
            <> jsOut ("K.decodePubKeyEd25519(Id.extractCertPublicKeyInfo(" <> jsUint8 certDer <> "))")
      tsResult `shouldBe` pubKey

  describe "verifyIdentityProof" $ do
    it "valid proof returns true" $ do
      let signSeed = B.pack [1 .. 32]
          signSk = throwCryptoError $ Ed25519.secretKey signSeed
          signPk = Ed25519.toPublic signSk
          signPkRaw = BA.convert signPk :: B.ByteString
          leafCertDer = mkFakeCertDer signPkRaw
          idCertDer = B.pack [1 .. 50]
          keyHash = C.sha256Hash idCertDer
          -- DH key SignedExact
          dhSeed = B.pack [41 .. 72]
          dhSk = throwCryptoError $ X25519.secretKey dhSeed
          dhPk = X25519.toPublic dhSk
          dhPkRaw = BA.convert dhPk :: B.ByteString
          x25519Prefix = B.pack [0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x6e, 0x03, 0x21, 0x00]
          spkiDer = x25519Prefix <> dhPkRaw
          dhSig = Ed25519.sign signSk signPk spkiDer
          dhSigRaw = BA.convert dhSig :: B.ByteString
          algId = B.pack [0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70]
          bitString = B.pack [0x03, 0x41, 0x00] <> dhSigRaw
          signedKeyDer = B.pack [0x30, 0x76] <> spkiDer <> algId <> bitString
          -- Challenge signature
          challenge = B.pack [101 .. 132]
          sessionId = B.pack [201 .. 232]
          challengeSig = Ed25519.sign signSk signPk (challenge <> sessionId)
          challengeSigRaw = BA.convert challengeSig :: B.ByteString
      tsResult <-
        callNode $
          impId
            <> "const ok = Id.verifyIdentityProof({"
            <> "certChainDer: ["
            <> jsUint8 leafCertDer
            <> ","
            <> jsUint8 idCertDer
            <> "],"
            <> "signedKeyDer: "
            <> jsUint8 signedKeyDer
            <> ","
            <> "sigBytes: "
            <> jsUint8 challengeSigRaw
            <> ","
            <> "challenge: "
            <> jsUint8 challenge
            <> ","
            <> "sessionId: "
            <> jsUint8 sessionId
            <> ","
            <> "keyHash: "
            <> jsUint8 keyHash
            <> "});"
            <> jsOut "new Uint8Array([ok ? 1 : 0])"
      tsResult `shouldBe` B.pack [1]

    it "wrong keyHash returns false" $ do
      let signSeed = B.pack [1 .. 32]
          signSk = throwCryptoError $ Ed25519.secretKey signSeed
          signPk = Ed25519.toPublic signSk
          signPkRaw = BA.convert signPk :: B.ByteString
          leafCertDer = mkFakeCertDer signPkRaw
          idCertDer = B.pack [1 .. 50]
          wrongKeyHash = B.replicate 32 0xff
          -- DH key SignedExact
          dhSeed = B.pack [41 .. 72]
          dhSk = throwCryptoError $ X25519.secretKey dhSeed
          dhPk = X25519.toPublic dhSk
          dhPkRaw = BA.convert dhPk :: B.ByteString
          x25519Prefix = B.pack [0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x6e, 0x03, 0x21, 0x00]
          spkiDer = x25519Prefix <> dhPkRaw
          dhSig = Ed25519.sign signSk signPk spkiDer
          dhSigRaw = BA.convert dhSig :: B.ByteString
          algId = B.pack [0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70]
          bitString = B.pack [0x03, 0x41, 0x00] <> dhSigRaw
          signedKeyDer = B.pack [0x30, 0x76] <> spkiDer <> algId <> bitString
          challenge = B.pack [101 .. 132]
          sessionId = B.pack [201 .. 232]
          challengeSig = Ed25519.sign signSk signPk (challenge <> sessionId)
          challengeSigRaw = BA.convert challengeSig :: B.ByteString
      tsResult <-
        callNode $
          impId
            <> "const ok = Id.verifyIdentityProof({"
            <> "certChainDer: ["
            <> jsUint8 leafCertDer
            <> ","
            <> jsUint8 idCertDer
            <> "],"
            <> "signedKeyDer: "
            <> jsUint8 signedKeyDer
            <> ","
            <> "sigBytes: "
            <> jsUint8 challengeSigRaw
            <> ","
            <> "challenge: "
            <> jsUint8 challenge
            <> ","
            <> "sessionId: "
            <> jsUint8 sessionId
            <> ","
            <> "keyHash: "
            <> jsUint8 wrongKeyHash
            <> "});"
            <> jsOut "new Uint8Array([ok ? 1 : 0])"
      tsResult `shouldBe` B.pack [0]

    it "wrong challenge sig returns false" $ do
      let signSeed = B.pack [1 .. 32]
          signSk = throwCryptoError $ Ed25519.secretKey signSeed
          signPk = Ed25519.toPublic signSk
          signPkRaw = BA.convert signPk :: B.ByteString
          leafCertDer = mkFakeCertDer signPkRaw
          idCertDer = B.pack [1 .. 50]
          keyHash = C.sha256Hash idCertDer
          -- DH key SignedExact
          dhSeed = B.pack [41 .. 72]
          dhSk = throwCryptoError $ X25519.secretKey dhSeed
          dhPk = X25519.toPublic dhSk
          dhPkRaw = BA.convert dhPk :: B.ByteString
          x25519Prefix = B.pack [0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x6e, 0x03, 0x21, 0x00]
          spkiDer = x25519Prefix <> dhPkRaw
          dhSig = Ed25519.sign signSk signPk spkiDer
          dhSigRaw = BA.convert dhSig :: B.ByteString
          algId = B.pack [0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70]
          bitString = B.pack [0x03, 0x41, 0x00] <> dhSigRaw
          signedKeyDer = B.pack [0x30, 0x76] <> spkiDer <> algId <> bitString
          challenge = B.pack [101 .. 132]
          sessionId = B.pack [201 .. 232]
          wrongChallenge = B.pack [1 .. 32]
          wrongSig = Ed25519.sign signSk signPk (wrongChallenge <> sessionId)
          wrongSigRaw = BA.convert wrongSig :: B.ByteString
      tsResult <-
        callNode $
          impId
            <> "const ok = Id.verifyIdentityProof({"
            <> "certChainDer: ["
            <> jsUint8 leafCertDer
            <> ","
            <> jsUint8 idCertDer
            <> "],"
            <> "signedKeyDer: "
            <> jsUint8 signedKeyDer
            <> ","
            <> "sigBytes: "
            <> jsUint8 wrongSigRaw
            <> ","
            <> "challenge: "
            <> jsUint8 challenge
            <> ","
            <> "sessionId: "
            <> jsUint8 sessionId
            <> ","
            <> "keyHash: "
            <> jsUint8 keyHash
            <> "});"
            <> jsOut "new Uint8Array([ok ? 1 : 0])"
      tsResult `shouldBe` B.pack [0]

    it "wrong DH key sig returns false" $ do
      let signSeed = B.pack [1 .. 32]
          signSk = throwCryptoError $ Ed25519.secretKey signSeed
          signPk = Ed25519.toPublic signSk
          signPkRaw = BA.convert signPk :: B.ByteString
          leafCertDer = mkFakeCertDer signPkRaw
          idCertDer = B.pack [1 .. 50]
          keyHash = C.sha256Hash idCertDer
          -- DH key signed by a DIFFERENT key
          otherSeed = B.pack [51 .. 82]
          otherSk = throwCryptoError $ Ed25519.secretKey otherSeed
          otherPk = Ed25519.toPublic otherSk
          dhSeed = B.pack [41 .. 72]
          dhSk = throwCryptoError $ X25519.secretKey dhSeed
          dhPk = X25519.toPublic dhSk
          dhPkRaw = BA.convert dhPk :: B.ByteString
          x25519Prefix = B.pack [0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x6e, 0x03, 0x21, 0x00]
          spkiDer = x25519Prefix <> dhPkRaw
          dhSig = Ed25519.sign otherSk otherPk spkiDer
          dhSigRaw = BA.convert dhSig :: B.ByteString
          algId = B.pack [0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70]
          bitString = B.pack [0x03, 0x41, 0x00] <> dhSigRaw
          signedKeyDer = B.pack [0x30, 0x76] <> spkiDer <> algId <> bitString
          challenge = B.pack [101 .. 132]
          sessionId = B.pack [201 .. 232]
          challengeSig = Ed25519.sign signSk signPk (challenge <> sessionId)
          challengeSigRaw = BA.convert challengeSig :: B.ByteString
      tsResult <-
        callNode $
          impId
            <> "const ok = Id.verifyIdentityProof({"
            <> "certChainDer: ["
            <> jsUint8 leafCertDer
            <> ","
            <> jsUint8 idCertDer
            <> "],"
            <> "signedKeyDer: "
            <> jsUint8 signedKeyDer
            <> ","
            <> "sigBytes: "
            <> jsUint8 challengeSigRaw
            <> ","
            <> "challenge: "
            <> jsUint8 challenge
            <> ","
            <> "sessionId: "
            <> jsUint8 sessionId
            <> ","
            <> "keyHash: "
            <> jsUint8 keyHash
            <> "});"
            <> jsOut "new Uint8Array([ok ? 1 : 0])"
      tsResult `shouldBe` B.pack [0]

-- ── protocol/description ──────────────────────────────────────────

tsDescriptionTests :: Spec
tsDescriptionTests = describe "protocol/description" $ do
  describe "base64url" $ do
    it "encode matches Haskell strEncode" $ do
      let bs = B.pack [0 .. 31]
      tsResult <-
        callNode $
          impDesc
            <> jsOut ("new TextEncoder().encode(Desc.base64urlEncode(" <> jsUint8 bs <> "))")
      tsResult `shouldBe` strEncode bs

    it "decode recovers original" $ do
      let bs = B.pack [0 .. 31]
          encoded = strEncode bs
      tsResult <-
        callNode $
          impDesc
            <> "const s = new TextDecoder().decode("
            <> jsUint8 encoded
            <> ");"
            <> jsOut "Desc.base64urlDecode(s)"
      tsResult `shouldBe` bs

    it "round-trip 256 bytes" $ do
      let bs = B.pack [0 .. 255]
      tsResult <-
        callNode $
          impDesc
            <> "const data = "
            <> jsUint8 bs
            <> ";"
            <> "const encoded = Desc.base64urlEncode(data);"
            <> jsOut "Desc.base64urlDecode(encoded)"
      tsResult `shouldBe` bs

  describe "FileSize" $ do
    it "encodeFileSize" $ do
      let sizes = [500, 1024, 2048, 1048576, 8388608, 1073741824, 27262976 :: Int64]
          expected = B.intercalate "," $ map (strEncode . FileSize) sizes
      tsResult <-
        callNode $
          impDesc
            <> "const sizes = [500, 1024, 2048, 1048576, 8388608, 1073741824, 27262976];"
            <> jsOut "new TextEncoder().encode(sizes.map(Desc.encodeFileSize).join(','))"
      tsResult `shouldBe` expected

    it "decodeFileSize" $ do
      tsResult <-
        callNode $
          impDesc
            <> "const strs = ['500','1kb','2kb','1mb','8mb','1gb'];"
            <> jsOut "new TextEncoder().encode(strs.map(s => String(Desc.decodeFileSize(s))).join(','))"
      tsResult `shouldBe` "500,1024,2048,1048576,8388608,1073741824"

  describe "FileDescription" $ do
    it "fixture YAML round-trip" $ do
      fixture <- B.readFile "tests/fixtures/file_description.yaml"
      tsResult <-
        callNode $
          impDesc
            <> "const yaml = new TextDecoder().decode("
            <> jsUint8 fixture
            <> ");"
            <> "const fd = Desc.decodeFileDescription(yaml);"
            <> "const reEncoded = Desc.encodeFileDescription(fd);"
            <> jsOut "new TextEncoder().encode(reEncoded)"
      tsResult `shouldBe` fixture

    it "fixture parsed structure" $ do
      fixture <- B.readFile "tests/fixtures/file_description.yaml"
      tsResult <-
        callNode $
          impDesc
            <> "const yaml = new TextDecoder().decode("
            <> jsUint8 fixture
            <> ");"
            <> "const fd = Desc.decodeFileDescription(yaml);"
            <> "const r = ["
            <> "fd.party,"
            <> "String(fd.size),"
            <> "String(fd.chunkSize),"
            <> "String(fd.chunks.length),"
            <> "String(fd.chunks[0].replicas.length),"
            <> "String(fd.chunks[3].chunkSize),"
            <> "fd.redirect === null ? 'null' : 'redirect'"
            <> "].join(',');"
            <> jsOut "new TextEncoder().encode(r)"
      tsResult `shouldBe` "recipient,27262976,8388608,4,2,2097152,null"

    it "encode with redirect round-trips" $ do
      tsResult <-
        callNode $
          impDesc
            <> "const fd = {"
            <> "  party: 'sender',"
            <> "  size: 1024,"
            <> "  digest: new Uint8Array([1,2,3]),"
            <> "  key: new Uint8Array(32),"
            <> "  nonce: new Uint8Array(24),"
            <> "  chunkSize: 1024,"
            <> "  chunks: [{chunkNo: 1, chunkSize: 1024, digest: new Uint8Array([4,5,6]),"
            <> "    replicas: [{server: 'xftp://abc=@example.com', replicaId: new Uint8Array([7,8,9]),"
            <> "      replicaKey: new Uint8Array([10,11,12])}]}],"
            <> "  redirect: {size: 512, digest: new Uint8Array([13,14,15])}"
            <> "};"
            <> "const yaml = Desc.encodeFileDescription(fd);"
            <> "const fd2 = Desc.decodeFileDescription(yaml);"
            <> "const r = ["
            <> "fd2.party,"
            <> "String(fd2.redirect !== null),"
            <> "String(fd2.redirect?.size),"
            <> "Desc.base64urlEncode(fd2.redirect?.digest || new Uint8Array())"
            <> "].join(',');"
            <> jsOut "new TextEncoder().encode(r)"
      tsResult `shouldBe` "sender,true,512,DQ4P"

    it "fdSeparator" $ do
      tsResult <-
        callNode $
          impDesc
            <> jsOut "new TextEncoder().encode(Desc.fdSeparator)"
      tsResult `shouldBe` "################################\n"

  describe "validation" $ do
    it "valid description" $ do
      fixture <- B.readFile "tests/fixtures/file_description.yaml"
      tsResult <-
        callNode $
          impDesc
            <> "const yaml = new TextDecoder().decode("
            <> jsUint8 fixture
            <> ");"
            <> "const fd = Desc.decodeFileDescription(yaml);"
            <> "const r = Desc.validateFileDescription(fd);"
            <> jsOut "new TextEncoder().encode(r === null ? 'ok' : r)"
      tsResult `shouldBe` "ok"

    it "non-sequential chunks" $ do
      fixture <- B.readFile "tests/fixtures/file_description.yaml"
      tsResult <-
        callNode $
          impDesc
            <> "const yaml = new TextDecoder().decode("
            <> jsUint8 fixture
            <> ");"
            <> "const fd = Desc.decodeFileDescription(yaml);"
            <> "fd.chunks[1].chunkNo = 5;"
            <> "const r = Desc.validateFileDescription(fd);"
            <> jsOut "new TextEncoder().encode(r || 'ok')"
      tsResult `shouldBe` "chunk numbers are not sequential"

    it "mismatched size" $ do
      fixture <- B.readFile "tests/fixtures/file_description.yaml"
      tsResult <-
        callNode $
          impDesc
            <> "const yaml = new TextDecoder().decode("
            <> jsUint8 fixture
            <> ");"
            <> "const fd = Desc.decodeFileDescription(yaml);"
            <> "fd.size = 999;"
            <> "const r = Desc.validateFileDescription(fd);"
            <> jsOut "new TextEncoder().encode(r || 'ok')"
      tsResult `shouldBe` "chunks total size is different than file size"

-- ── protocol/chunks ───────────────────────────────────────────────

tsChunkTests :: Spec
tsChunkTests = describe "protocol/chunks" $ do
  describe "prepareChunkSizes" $ do
    it "matches Haskell for various sizes" $ do
      let sizes = [100, 65536, 130000, 200000, 500000, 800000, 5000000, 27262976 :: Int64]
          hsResults = map prepareChunkSizes sizes
          expected = B.intercalate "|" $ map (\cs -> B.intercalate "," $ map (strEncode . FileSize) cs) hsResults
      tsResult <-
        callNode $
          impChk
            <> "const sizes = [100, 65536, 130000, 200000, 500000, 800000, 5000000, 27262976];"
            <> "const results = sizes.map(s => Chk.prepareChunkSizes(s).map(Desc.encodeFileSize).join(','));"
            <> jsOut "new TextEncoder().encode(results.join('|'))"
      tsResult `shouldBe` expected

    it "zero size" $ do
      tsResult <-
        callNode $
          impChk
            <> jsOut "new TextEncoder().encode(Chk.prepareChunkSizes(0).join(','))"
      tsResult `shouldBe` ""

  describe "singleChunkSize" $ do
    it "finds smallest fitting chunk size" $ do
      tsResult <-
        callNode $
          impChk
            <> "const sizes = [100, 65536, 262144, 300000, 1048576, 4194304, 5000000];"
            <> "const results = sizes.map(s => {"
            <> "  const r = Chk.singleChunkSize(s);"
            <> "  return r === null ? 'null' : Desc.encodeFileSize(r);"
            <> "});"
            <> jsOut "new TextEncoder().encode(results.join(','))"
      tsResult `shouldBe` "64kb,64kb,256kb,1mb,1mb,4mb,null"

  describe "prepareChunkSpecs" $ do
    it "generates correct offsets" $ do
      tsResult <-
        callNode $
          impChk
            <> "const specs = Chk.prepareChunkSpecs([4194304, 4194304, 1048576]);"
            <> "const r = specs.map(s => s.chunkOffset + ':' + s.chunkSize).join(',');"
            <> jsOut "new TextEncoder().encode(r)"
      tsResult `shouldBe` "0:4194304,4194304:4194304,8388608:1048576"

  describe "getChunkDigest" $ do
    it "matches Haskell sha256Hash" $ do
      let chunk = B.pack [0 .. 63]
          expected = C.sha256Hash chunk
      tsResult <-
        callNode $
          impChk
            <> jsOut ("Chk.getChunkDigest(" <> jsUint8 chunk <> ")")
      tsResult `shouldBe` expected

  describe "constants" $ do
    it "serverChunkSizes" $ do
      tsResult <-
        callNode $
          impChk
            <> jsOut "new TextEncoder().encode(Chk.serverChunkSizes.map(Desc.encodeFileSize).join(','))"
      tsResult `shouldBe` "64kb,256kb,1mb,4mb"

    it "fileSizeLen and authTagSize" $ do
      tsResult <-
        callNode $
          impChk
            <> jsOut "new TextEncoder().encode(Chk.fileSizeLen + ',' + Chk.authTagSize)"
      tsResult `shouldBe` "8,16"

-- ── protocol/client ─────────────────────────────────────────────

tsClientTests :: Spec
tsClientTests = describe "protocol/client" $ do
  -- Fixed X25519 key pairs for deterministic tests
  let privARaw = B.pack [1 .. 32]
      privA = throwCryptoError $ X25519.secretKey privARaw
      pubA = X25519.toPublic privA
      pubARaw = BA.convert pubA :: B.ByteString
      privBRaw = B.pack [33 .. 64]
      privB = throwCryptoError $ X25519.secretKey privBRaw
      pubB = X25519.toPublic privB
      pubBRaw = BA.convert pubB :: B.ByteString
      nonce24 = B.pack [0 .. 23]

  describe "cbAuthenticate" $ do
    it "matches Haskell output" $ do
      let msg = "hello world authenticator test"
          C.CbAuthenticator expected =
            C.cbAuthenticate
              (C.PublicKeyX25519 pubA)
              (C.PrivateKeyX25519 privB)
              (C.cbNonce nonce24)
              msg
      tsResult <-
        callNode $
          impCli
            <> "const auth = Cli.cbAuthenticate("
            <> jsUint8 pubARaw
            <> ","
            <> jsUint8 privBRaw
            <> ","
            <> jsUint8 nonce24
            <> ","
            <> jsUint8 msg
            <> ");"
            <> jsOut "auth"
      tsResult `shouldBe` expected

    it "is 80 bytes" $ do
      let msg = "size test"
          C.CbAuthenticator expected =
            C.cbAuthenticate
              (C.PublicKeyX25519 pubA)
              (C.PrivateKeyX25519 privB)
              (C.cbNonce nonce24)
              msg
      B.length expected `shouldBe` 80

  describe "cbVerify" $ do
    it "validates Haskell authenticator" $ do
      let msg = "test message for verify"
          C.CbAuthenticator authBytes_ =
            C.cbAuthenticate
              (C.PublicKeyX25519 pubA)
              (C.PrivateKeyX25519 privB)
              (C.cbNonce nonce24)
              msg
      tsResult <-
        callNode $
          impCli
            <> "const valid = Cli.cbVerify("
            <> jsUint8 pubBRaw
            <> ","
            <> jsUint8 privARaw
            <> ","
            <> jsUint8 nonce24
            <> ","
            <> jsUint8 authBytes_
            <> ","
            <> jsUint8 msg
            <> ");"
            <> jsOut "new Uint8Array([valid ? 1 : 0])"
      tsResult `shouldBe` B.pack [1]

    it "rejects wrong message" $ do
      let msg = "correct message"
          wrongMsg = "wrong message"
          C.CbAuthenticator authBytes_ =
            C.cbAuthenticate
              (C.PublicKeyX25519 pubA)
              (C.PrivateKeyX25519 privB)
              (C.cbNonce nonce24)
              msg
      tsResult <-
        callNode $
          impCli
            <> "const valid = Cli.cbVerify("
            <> jsUint8 pubBRaw
            <> ","
            <> jsUint8 privARaw
            <> ","
            <> jsUint8 nonce24
            <> ","
            <> jsUint8 authBytes_
            <> ","
            <> jsUint8 wrongMsg
            <> ");"
            <> jsOut "new Uint8Array([valid ? 1 : 0])"
      tsResult `shouldBe` B.pack [0]

    it "round-trip: TS authenticate, Haskell verify" $ do
      let msg = "round trip test"
      tsAuth <-
        callNode $
          impCli
            <> "const auth = Cli.cbAuthenticate("
            <> jsUint8 pubARaw
            <> ","
            <> jsUint8 privBRaw
            <> ","
            <> jsUint8 nonce24
            <> ","
            <> jsUint8 msg
            <> ");"
            <> jsOut "auth"
      let hsValid =
            C.cbVerify
              (C.PublicKeyX25519 pubB)
              (C.PrivateKeyX25519 privA)
              (C.cbNonce nonce24)
              (C.CbAuthenticator tsAuth)
              msg
      hsValid `shouldBe` True

  describe "transport chunk encryption" $ do
    let dhSecret = C.dh' (C.PublicKeyX25519 pubA) (C.PrivateKeyX25519 privB)
        dhSecretBytes = case dhSecret of C.DhSecretX25519 k -> BA.convert k :: B.ByteString

    it "encryptTransportChunk matches Haskell" $ do
      let plaintext = B.pack [100 .. 199]
          state0 = either (error . show) id $ LC.cbInit dhSecret (C.cbNonce nonce24)
          (cipher, state1) = LC.sbEncryptChunk state0 plaintext
          tag = BA.convert $ LC.sbAuth state1 :: B.ByteString
          expected = cipher <> tag
      tsResult <-
        callNode $
          impCli
            <> "const enc = Cli.encryptTransportChunk("
            <> jsUint8 dhSecretBytes
            <> ","
            <> jsUint8 nonce24
            <> ","
            <> jsUint8 plaintext
            <> ");"
            <> jsOut "enc"
      tsResult `shouldBe` expected

    it "decryptTransportChunk decrypts Haskell-encrypted data" $ do
      let plaintext = B.pack ([200 .. 255] <> [0 .. 99])
          state0 = either (error . show) id $ LC.cbInit dhSecret (C.cbNonce nonce24)
          (cipher, state1) = LC.sbEncryptChunk state0 plaintext
          tag = BA.convert $ LC.sbAuth state1 :: B.ByteString
          encData = cipher <> tag
      tsResult <-
        callNode $
          impCli
            <> "const r = Cli.decryptTransportChunk("
            <> jsUint8 dhSecretBytes
            <> ","
            <> jsUint8 nonce24
            <> ","
            <> jsUint8 encData
            <> ");"
            <> "if (!r.valid) throw new Error('invalid');"
            <> jsOut "r.content"
      tsResult `shouldBe` plaintext

    it "round-trip encrypt then decrypt" $ do
      let plaintext = B.pack [42, 42, 42, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9]
      tsResult <-
        callNode $
          impCli
            <> "const plain = "
            <> jsUint8 plaintext
            <> ";"
            <> "const enc = Cli.encryptTransportChunk("
            <> jsUint8 dhSecretBytes
            <> ","
            <> jsUint8 nonce24
            <> ",plain);"
            <> "const r = Cli.decryptTransportChunk("
            <> jsUint8 dhSecretBytes
            <> ","
            <> jsUint8 nonce24
            <> ",enc);"
            <> "if (!r.valid) throw new Error('invalid');"
            <> jsOut "r.content"
      tsResult `shouldBe` plaintext

    it "rejects tampered ciphertext" $ do
      let plaintext = B.pack [10 .. 40]
      tsResult <-
        callNode $
          impCli
            <> "const enc = Cli.encryptTransportChunk("
            <> jsUint8 dhSecretBytes
            <> ","
            <> jsUint8 nonce24
            <> ","
            <> jsUint8 plaintext
            <> ");"
            <> "enc[0] ^= 0xff;"
            <> "const r = Cli.decryptTransportChunk("
            <> jsUint8 dhSecretBytes
            <> ","
            <> jsUint8 nonce24
            <> ",enc);"
            <> jsOut "new Uint8Array([r.valid ? 1 : 0])"
      tsResult `shouldBe` B.pack [0]

  describe "constants" $ do
    it "cbAuthenticatorSize" $ do
      tsResult <-
        callNode $
          impCli <> jsOut "new TextEncoder().encode(String(Cli.cbAuthenticatorSize))"
      tsResult `shouldBe` "80"

-- ── download (integration) ──────────────────────────────────────────

tsDownloadTests :: Spec
tsDownloadTests = describe "download" $ do
  -- Fixed X25519 key pairs (same as client tests)
  let privARaw = B.pack [1 .. 32]
      privA = throwCryptoError $ X25519.secretKey privARaw
      pubA = X25519.toPublic privA
      pubARaw = BA.convert pubA :: B.ByteString
      privBRaw = B.pack [33 .. 64]
      privB = throwCryptoError $ X25519.secretKey privBRaw
      pubB = X25519.toPublic privB
      pubBRaw = BA.convert pubB :: B.ByteString
      nonce24 = B.pack [0 .. 23]
      -- File-level key/nonce (different from transport)
      fileKey32 = B.pack [1 .. 32]
      fileNonce24 = B.pack [1 .. 24]
      fileCbNonce = C.cbNonce fileNonce24
      fileSbKey = C.unsafeSbKey fileKey32

  describe "processFileResponse" $ do
    it "derives DH secret matching Haskell" $ do
      -- Simulate: client has privA, server sends pubB
      let hsDhSecret = C.dh' (C.PublicKeyX25519 pubB) (C.PrivateKeyX25519 privA)
          hsDhBytes = case hsDhSecret of C.DhSecretX25519 k -> BA.convert k :: B.ByteString
      tsDhSecret <-
        callNode $
          impDl
            <> "const dh = Dl.processFileResponse("
            <> jsUint8 privARaw
            <> ","
            <> jsUint8 pubBRaw
            <> ");"
            <> jsOut "dh"
      tsDhSecret `shouldBe` hsDhBytes

  describe "decryptReceivedChunk" $ do
    it "transport decrypt with digest verification" $ do
      -- Haskell: transport-encrypt a chunk
      let dhSecret = C.dh' (C.PublicKeyX25519 pubA) (C.PrivateKeyX25519 privB)
          dhSecretBytes = case dhSecret of C.DhSecretX25519 k -> BA.convert k :: B.ByteString
          chunkData = B.pack [50 .. 149]
          chunkDigest = C.sha256Hash chunkData
          state0 = either (error . show) id $ LC.cbInit dhSecret (C.cbNonce nonce24)
          (cipher, state1) = LC.sbEncryptChunk state0 chunkData
          tag = BA.convert (LC.sbAuth state1) :: B.ByteString
          encData = cipher <> tag
      tsResult <-
        callNode $
          impDl
            <> "const r = Dl.decryptReceivedChunk("
            <> jsUint8 dhSecretBytes
            <> ","
            <> jsUint8 nonce24
            <> ","
            <> jsUint8 encData
            <> ","
            <> jsUint8 chunkDigest
            <> ");"
            <> jsOut "r"
      tsResult `shouldBe` chunkData

    it "rejects wrong digest" $ do
      let dhSecret = C.dh' (C.PublicKeyX25519 pubA) (C.PrivateKeyX25519 privB)
          dhSecretBytes = case dhSecret of C.DhSecretX25519 k -> BA.convert k :: B.ByteString
          chunkData = B.pack [50 .. 149]
          wrongDigest = B.replicate 32 0xff
          state0 = either (error . show) id $ LC.cbInit dhSecret (C.cbNonce nonce24)
          (cipher, state1) = LC.sbEncryptChunk state0 chunkData
          tag = BA.convert (LC.sbAuth state1) :: B.ByteString
          encData = cipher <> tag
      tsResult <-
        callNode $
          impDl
            <> "let ok = false; try { Dl.decryptReceivedChunk("
            <> jsUint8 dhSecretBytes
            <> ","
            <> jsUint8 nonce24
            <> ","
            <> jsUint8 encData
            <> ","
            <> jsUint8 wrongDigest
            <> "); } catch(e) { ok = e.message.includes('digest'); }"
            <> jsOut "new Uint8Array([ok ? 1 : 0])"
      tsResult `shouldBe` B.pack [1]

    it "allows null digest (skip verification)" $ do
      let dhSecret = C.dh' (C.PublicKeyX25519 pubA) (C.PrivateKeyX25519 privB)
          dhSecretBytes = case dhSecret of C.DhSecretX25519 k -> BA.convert k :: B.ByteString
          chunkData = B.pack [10 .. 50]
          state0 = either (error . show) id $ LC.cbInit dhSecret (C.cbNonce nonce24)
          (cipher, state1) = LC.sbEncryptChunk state0 chunkData
          tag = BA.convert (LC.sbAuth state1) :: B.ByteString
          encData = cipher <> tag
      tsResult <-
        callNode $
          impDl
            <> "const r = Dl.decryptReceivedChunk("
            <> jsUint8 dhSecretBytes
            <> ","
            <> jsUint8 nonce24
            <> ","
            <> jsUint8 encData
            <> ",null);"
            <> jsOut "r"
      tsResult `shouldBe` chunkData

  describe "full pipeline" $ do
    it "Haskell file-encrypt + transport-encrypt -> TS transport-decrypt + file-decrypt" $ do
      -- Step 1: file-level encryption (matches Haskell encryptFile)
      let source = "Integration test: full download pipeline!" :: B.ByteString
          hdr = FileHeader "pipeline.txt" Nothing
          fileHdr = smpEncode hdr
          fileSize' = fromIntegral (B.length fileHdr + B.length source) :: Int64
          encSize = 256 :: Int64
          sb = either (error . show) id $ LC.sbInit fileSbKey fileCbNonce
          lenStr = smpEncode fileSize'
          (hdrEnc, sb1) = LC.sbEncryptChunk sb (lenStr <> fileHdr)
          (srcEnc, sb2) = LC.sbEncryptChunk sb1 source
          padLen = encSize - 16 - fileSize' - 8
          padding = B.replicate (fromIntegral padLen) 0x23
          (padEnc, sb3) = LC.sbEncryptChunk sb2 padding
          fileTag = BA.convert (LC.sbAuth sb3) :: B.ByteString
          fileEncrypted = B.concat [hdrEnc, srcEnc, padEnc, fileTag]
      -- Step 2: transport-level encryption (simulates server sending chunk)
      let dhSecret = C.dh' (C.PublicKeyX25519 pubA) (C.PrivateKeyX25519 privB)
          dhSecretBytes = case dhSecret of C.DhSecretX25519 k -> BA.convert k :: B.ByteString
          ts0 = either (error . show) id $ LC.cbInit dhSecret (C.cbNonce nonce24)
          (transportCipher, ts1) = LC.sbEncryptChunk ts0 fileEncrypted
          transportTag = BA.convert (LC.sbAuth ts1) :: B.ByteString
          transportEncData = transportCipher <> transportTag
      -- Step 3: TS decrypts transport, then file-level
      tsResult <-
        callNode $
          impDl
            <> "const chunk = Dl.decryptReceivedChunk("
            <> jsUint8 dhSecretBytes
            <> ","
            <> jsUint8 nonce24
            <> ","
            <> jsUint8 transportEncData
            <> ",null);"
            <> "const r = F.decryptChunks("
            <> show encSize
            <> "n,[chunk],"
            <> jsUint8 fileKey32
            <> ","
            <> jsUint8 fileNonce24
            <> ");"
            <> "const hdrBytes = F.encodeFileHeader(r.header);"
            <> jsOut "new Uint8Array([...hdrBytes, ...r.content])"
      tsResult `shouldBe` (fileHdr <> source)

    it "multi-chunk file: Haskell encrypt -> TS decrypt" $ do
      -- File content that spans two chunks when file-encrypted
      let source = B.pack (take 200 $ cycle [0 .. 255])
          hdr = FileHeader "multi.bin" Nothing
          fileHdr = smpEncode hdr
          fileSize' = fromIntegral (B.length fileHdr + B.length source) :: Int64
          encSize = 512 :: Int64
          sb = either (error . show) id $ LC.sbInit fileSbKey fileCbNonce
          lenStr = smpEncode fileSize'
          (hdrEnc, sb1) = LC.sbEncryptChunk sb (lenStr <> fileHdr)
          (srcEnc, sb2) = LC.sbEncryptChunk sb1 source
          padLen = encSize - 16 - fileSize' - 8
          padding = B.replicate (fromIntegral padLen) 0x23
          (padEnc, sb3) = LC.sbEncryptChunk sb2 padding
          fileTag = BA.convert (LC.sbAuth sb3) :: B.ByteString
          fileEncrypted = B.concat [hdrEnc, srcEnc, padEnc, fileTag]
      -- Split file-encrypted data into two "chunks" and transport-encrypt each
      let splitPt = B.length fileEncrypted `div` 2
          fileChunk1 = B.take splitPt fileEncrypted
          fileChunk2 = B.drop splitPt fileEncrypted
          -- Transport encrypt chunk 1 (with separate DH / nonce per chunk)
          dhSecret1 = C.dh' (C.PublicKeyX25519 pubA) (C.PrivateKeyX25519 privB)
          dhSecret1Bytes = case dhSecret1 of C.DhSecretX25519 k -> BA.convert k :: B.ByteString
          nonce1 = nonce24
          t1s0 = either (error . show) id $ LC.cbInit dhSecret1 (C.cbNonce nonce1)
          (t1cipher, t1s1) = LC.sbEncryptChunk t1s0 fileChunk1
          t1tag = BA.convert (LC.sbAuth t1s1) :: B.ByteString
          transportEnc1 = t1cipher <> t1tag
          -- Transport encrypt chunk 2 (different nonce)
          nonce2 = B.pack [24 .. 47]
          dhSecret2 = C.dh' (C.PublicKeyX25519 pubB) (C.PrivateKeyX25519 privA)
          dhSecret2Bytes = case dhSecret2 of C.DhSecretX25519 k -> BA.convert k :: B.ByteString
          t2s0 = either (error . show) id $ LC.cbInit dhSecret2 (C.cbNonce nonce2)
          (t2cipher, t2s1) = LC.sbEncryptChunk t2s0 fileChunk2
          t2tag = BA.convert (LC.sbAuth t2s1) :: B.ByteString
          transportEnc2 = t2cipher <> t2tag
      -- TS: transport-decrypt each chunk, then file-level decrypt the concatenation
      tsResult <-
        callNode $
          impDl
            <> "const c1 = Dl.decryptReceivedChunk("
            <> jsUint8 dhSecret1Bytes
            <> ","
            <> jsUint8 nonce1
            <> ","
            <> jsUint8 transportEnc1
            <> ",null);"
            <> "const c2 = Dl.decryptReceivedChunk("
            <> jsUint8 dhSecret2Bytes
            <> ","
            <> jsUint8 nonce2
            <> ","
            <> jsUint8 transportEnc2
            <> ",null);"
            <> "const r = F.decryptChunks("
            <> show encSize
            <> "n,[c1,c2],"
            <> jsUint8 fileKey32
            <> ","
            <> jsUint8 fileNonce24
            <> ");"
            <> "const hdrBytes = F.encodeFileHeader(r.header);"
            <> jsOut "new Uint8Array([...hdrBytes, ...r.content])"
      tsResult `shouldBe` (fileHdr <> source)

  describe "FGET + FRFile round-trip" $ do
    it "encode FGET -> decode FRFile -> process -> transport decrypt" $ do
      -- Client side: generate FGET command
      let dhSecret = C.dh' (C.PublicKeyX25519 pubA) (C.PrivateKeyX25519 privB)
          chunkData = "FGET round-trip test data" :: B.ByteString
          state0 = either (error . show) id $ LC.cbInit dhSecret (C.cbNonce nonce24)
          (cipher, state1) = LC.sbEncryptChunk state0 chunkData
          tag = BA.convert (LC.sbAuth state1) :: B.ByteString
          encData = cipher <> tag
          -- Simulate server response: FILE <serverPubKey> <nonce>
          -- Server sends pubA (client has privB to do DH)
          serverPubDer = C.encodePubKey (C.PublicKeyX25519 pubA)
          fileResponseBytes = "FILE " <> smpEncode serverPubDer <> nonce24
      -- TS: parse FRFile response, derive DH secret, decrypt transport chunk
      tsResult <-
        callNode $
          impDl
            <> "const resp = Cmd.decodeResponse("
            <> jsUint8 fileResponseBytes
            <> ");"
            <> "if (resp.type !== 'FRFile') throw new Error('expected FRFile');"
            <> "const dhSecret = Dl.processFileResponse("
            <> jsUint8 privBRaw
            <> ",resp.rcvDhKey);"
            <> "const r = Dl.decryptReceivedChunk(dhSecret,"
            <> "resp.nonce,"
            <> jsUint8 encData
            <> ",null);"
            <> jsOut "r"
      tsResult `shouldBe` chunkData

  describe "processDownloadedFile" $ do
    it "decrypts file from transport-decrypted chunks" $ do
      let source = "processDownloadedFile test" :: B.ByteString
          hdr = FileHeader "download.txt" (Just "v1")
          fileHdr = smpEncode hdr
          fileSize' = fromIntegral (B.length fileHdr + B.length source) :: Int64
          encSize = 256 :: Int64
          sb = either (error . show) id $ LC.sbInit fileSbKey fileCbNonce
          lenStr = smpEncode fileSize'
          (hdrEnc, sb1) = LC.sbEncryptChunk sb (lenStr <> fileHdr)
          (srcEnc, sb2) = LC.sbEncryptChunk sb1 source
          padLen = encSize - 16 - fileSize' - 8
          padding = B.replicate (fromIntegral padLen) 0x23
          (padEnc, sb3) = LC.sbEncryptChunk sb2 padding
          fileTag = BA.convert (LC.sbAuth sb3) :: B.ByteString
          fileEncrypted = B.concat [hdrEnc, srcEnc, padEnc, fileTag]
      -- TS: call processDownloadedFile with a minimal FileDescription-like object
      tsResult <-
        callNode $
          impDl
            <> "const fd = {size: "
            <> show encSize
            <> ","
            <> "key: "
            <> jsUint8 fileKey32
            <> ","
            <> "nonce: "
            <> jsUint8 fileNonce24
            <> "};"
            <> "const r = Dl.processDownloadedFile(fd, ["
            <> jsUint8 fileEncrypted
            <> "]);"
            <> "const hdrBytes = F.encodeFileHeader(r.header);"
            <> jsOut "new Uint8Array([...hdrBytes, ...r.content])"
      tsResult `shouldBe` (fileHdr <> source)

-- ── protocol/address ──────────────────────────────────────────────

tsAddressTests :: Spec
tsAddressTests = describe "protocol/address" $ do
  it "parseXFTPServer with port" $ do
    let addr = "xftp://LcJUMfVhwD8yxjAiSaDzzGF3-kLG4Uh0Fl_ZIjrRwjI=@localhost:8000" :: String
        expectedKH :: B.ByteString
        expectedKH = either error id $ strDecode "LcJUMfVhwD8yxjAiSaDzzGF3-kLG4Uh0Fl_ZIjrRwjI="
    result <-
      callNode $
        impAddr
          <> "const s = Addr.parseXFTPServer('"
          <> addr
          <> "');"
          <> jsOut "new Uint8Array([...s.keyHash, ...new TextEncoder().encode(s.host + ':' + s.port)])"
    let (kh, hostPort) = B.splitAt 32 result
    kh `shouldBe` expectedKH
    hostPort `shouldBe` "localhost:8000"

  it "parseXFTPServer default port" $ do
    result <-
      callNode $
        impAddr
          <> "const s = Addr.parseXFTPServer('xftp://LcJUMfVhwD8yxjAiSaDzzGF3-kLG4Uh0Fl_ZIjrRwjI=@example.com');"
          <> jsOut "new TextEncoder().encode(s.host + ':' + s.port)"
    result `shouldBe` "example.com:443"

  it "parseXFTPServer multi-host takes first" $ do
    result <-
      callNode $
        impAddr
          <> "const s = Addr.parseXFTPServer('xftp://LcJUMfVhwD8yxjAiSaDzzGF3-kLG4Uh0Fl_ZIjrRwjI=@host1.com:5000,host2.com');"
          <> jsOut "new TextEncoder().encode(s.host + ':' + s.port)"
    result `shouldBe` "host1.com:5000"

-- ── integration ───────────────────────────────────────────────────

tsIntegrationTests :: Spec
tsIntegrationTests = describe "integration" $ do
  it "web handshake with Ed25519 identity verification" $
    webHandshakeTest testXFTPServerConfigEd25519SNI "tests/fixtures/ed25519/ca.crt"
  it "web handshake with Ed448 identity verification" $
    webHandshakeTest testXFTPServerConfigSNI "tests/fixtures/ca.crt"
  it "connectXFTP + pingXFTP" $
    pingTest testXFTPServerConfigEd25519SNI "tests/fixtures/ed25519/ca.crt"
  it "full round-trip: create, upload, download, ack, addRecipients, delete" $
    fullRoundTripTest testXFTPServerConfigEd25519SNI "tests/fixtures/ed25519/ca.crt"
  it "agent URI round-trip" agentURIRoundTripTest
  it "agent upload + download round-trip" $
    agentUploadDownloadTest testXFTPServerConfigEd25519SNI "tests/fixtures/ed25519/ca.crt"
  it "agent delete + verify gone" $
    agentDeleteTest testXFTPServerConfigEd25519SNI "tests/fixtures/ed25519/ca.crt"
  it "agent redirect: upload with redirect, download" $
    agentRedirectTest testXFTPServerConfigEd25519SNI "tests/fixtures/ed25519/ca.crt"
  it "cross-language: TS upload, Haskell download" $
    tsUploadHaskellDownloadTest testXFTPServerConfigSNI "tests/fixtures/ca.crt"
  it "cross-language: TS upload with redirect, Haskell download" $
    tsUploadRedirectHaskellDownloadTest testXFTPServerConfigSNI "tests/fixtures/ca.crt"
  it "cross-language: Haskell upload, TS download" $
    haskellUploadTsDownloadTest testXFTPServerConfigSNI

webHandshakeTest :: XFTPServerConfig -> FilePath -> Expectation
webHandshakeTest cfg caFile = do
  withXFTPServerCfg cfg $ \_ -> do
    Fingerprint fp <- loadFileFingerprint caFile
    let fpStr = map (toEnum . fromIntegral) $ B.unpack $ strEncode fp
        addr = "xftp://" <> fpStr <> "@localhost:" <> xftpTestPort
    result <-
      callNode $
        "import http2 from 'node:http2';\
        \import crypto from 'node:crypto';\
        \import sodium from 'libsodium-wrappers-sumo';\
        \import * as Addr from './dist/protocol/address.js';\
        \import * as Hs from './dist/protocol/handshake.js';\
        \import * as Id from './dist/crypto/identity.js';\
        \await sodium.ready;\
        \const server = Addr.parseXFTPServer('"
          <> addr
          <> "');\
             \const readBody = s => new Promise((ok, err) => {\
             \const c = [];\
             \s.on('data', d => c.push(d));\
             \s.on('end', () => ok(Buffer.concat(c)));\
             \s.on('error', err);\
             \});\
             \const client = http2.connect('https://' + server.host + ':' + server.port, {rejectUnauthorized: false});\
             \const challenge = new Uint8Array(crypto.randomBytes(32));\
             \const s1 = client.request({':method': 'POST', ':path': '/', 'xftp-web-hello': '1'});\
             \s1.end(Buffer.from(Hs.encodeClientHello({webChallenge: challenge})));\
             \const hs = Hs.decodeServerHandshake(new Uint8Array(await readBody(s1)));\
             \const idOk = hs.webIdentityProof\
             \ ? Id.verifyIdentityProof({certChainDer: hs.certChainDer, signedKeyDer: hs.signedKeyDer,\
             \sigBytes: hs.webIdentityProof, challenge, sessionId: hs.sessionId, keyHash: server.keyHash})\
             \ : false;\
             \const ver = hs.xftpVersionRange.maxVersion;\
             \const s2 = client.request({':method': 'POST', ':path': '/', 'xftp-handshake': '1'});\
             \s2.end(Buffer.from(Hs.encodeClientHandshake({xftpVersion: ver, keyHash: server.keyHash})));\
             \const ack = await readBody(s2);\
             \client.close();"
          <> jsOut "new Uint8Array([idOk ? 1 : 0, ack.length === 0 ? 1 : 0])"
    result `shouldBe` B.pack [1, 1]

pingTest :: XFTPServerConfig -> FilePath -> Expectation
pingTest cfg caFile = do
  withXFTPServerCfg cfg $ \_ -> do
    Fingerprint fp <- loadFileFingerprint caFile
    let fpStr = map (toEnum . fromIntegral) $ B.unpack $ strEncode fp
        addr = "xftp://" <> fpStr <> "@localhost:" <> xftpTestPort
    result <-
      callNode $
        "import sodium from 'libsodium-wrappers-sumo';\
        \import * as Addr from './dist/protocol/address.js';\
        \import {connectXFTP, pingXFTP, closeXFTP} from './dist/client.js';\
        \await sodium.ready;\
        \const server = Addr.parseXFTPServer('"
          <> addr
          <> "');\
             \const c = await connectXFTP(server);\
             \await pingXFTP(c);\
             \closeXFTP(c);"
          <> jsOut "new Uint8Array([1])"
    result `shouldBe` B.pack [1]

fullRoundTripTest :: XFTPServerConfig -> FilePath -> Expectation
fullRoundTripTest cfg caFile = do
  createDirectoryIfMissing False "tests/tmp/xftp-server-files"
  withXFTPServerCfg cfg $ \_ -> do
    Fingerprint fp <- loadFileFingerprint caFile
    let fpStr = map (toEnum . fromIntegral) $ B.unpack $ strEncode fp
        addr = "xftp://" <> fpStr <> "@localhost:" <> xftpTestPort
    result <-
      callNode $
        "import sodium from 'libsodium-wrappers-sumo';\
        \import crypto from 'node:crypto';\
        \import * as Addr from './dist/protocol/address.js';\
        \import * as K from './dist/crypto/keys.js';\
        \import {sha256} from './dist/crypto/digest.js';\
        \import {connectXFTP, createXFTPChunk, uploadXFTPChunk, downloadXFTPChunk,\
        \ addXFTPRecipients, deleteXFTPChunk, closeXFTP} from './dist/client.js';\
        \await sodium.ready;\
        \const server = Addr.parseXFTPServer('"
          <> addr
          <> "');\
             \const c = await connectXFTP(server);\
             \const sndKp = K.generateEd25519KeyPair();\
             \const rcvKp1 = K.generateEd25519KeyPair();\
             \const rcvKp2 = K.generateEd25519KeyPair();\
             \const chunkData = new Uint8Array(crypto.randomBytes(65536));\
             \const digest = sha256(chunkData);\
             \const file = {\
             \  sndKey: K.encodePubKeyEd25519(sndKp.publicKey),\
             \  size: chunkData.length,\
             \  digest\
             \};\
             \const rcvKeys = [K.encodePubKeyEd25519(rcvKp1.publicKey)];\
             \const {senderId, recipientIds} = await createXFTPChunk(c, sndKp.privateKey, file, rcvKeys, null);\
             \await uploadXFTPChunk(c, sndKp.privateKey, senderId, chunkData);\
             \const dl1 = await downloadXFTPChunk(c, rcvKp1.privateKey, recipientIds[0], digest);\
             \const match1 = dl1.length === chunkData.length && dl1.every((b, i) => b === chunkData[i]);\
             \const newIds = await addXFTPRecipients(c, sndKp.privateKey, senderId,\
             \  [K.encodePubKeyEd25519(rcvKp2.publicKey)]);\
             \const dl2 = await downloadXFTPChunk(c, rcvKp2.privateKey, newIds[0], digest);\
             \const match2 = dl2.length === chunkData.length && dl2.every((b, i) => b === chunkData[i]);\
             \await deleteXFTPChunk(c, sndKp.privateKey, senderId);\
             \closeXFTP(c);"
          <> jsOut "new Uint8Array([match1 ? 1 : 0, match2 ? 1 : 0])"
    result `shouldBe` B.pack [1, 1]

agentURIRoundTripTest :: Expectation
agentURIRoundTripTest = do
  result <-
    callNode $
      "import sodium from 'libsodium-wrappers-sumo';\
      \import * as Agent from './dist/agent.js';\
      \import * as Desc from './dist/protocol/description.js';\
      \await sodium.ready;\
      \const fd = {\
      \  party: 'recipient',\
      \  size: 65536,\
      \  digest: new Uint8Array(64).fill(0xab),\
      \  key: new Uint8Array(32).fill(0x01),\
      \  nonce: new Uint8Array(24).fill(0x02),\
      \  chunkSize: 65536,\
      \  chunks: [{\
      \    chunkNo: 1,\
      \    chunkSize: 65536,\
      \    digest: new Uint8Array(32).fill(0xcd),\
      \    replicas: [{\
      \      server: 'xftp://AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=@example.com:443',\
      \      replicaId: new Uint8Array([1,2,3]),\
      \      replicaKey: new Uint8Array([48,46,2,1,0,48,5,6,3,43,101,112,4,34,4,32,\
      \        1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32])\
      \    }]\
      \  }],\
      \  redirect: null\
      \};\
      \const uri = Agent.encodeDescriptionURI(fd);\
      \const fd2 = Agent.decodeDescriptionURI(uri);\
      \const yaml1 = Desc.encodeFileDescription(fd);\
      \const yaml2 = Desc.encodeFileDescription(fd2);\
      \const match = yaml1 === yaml2 ? 1 : 0;"
        <> jsOut "new Uint8Array([match])"
  result `shouldBe` B.pack [1]

agentUploadDownloadTest :: XFTPServerConfig -> FilePath -> Expectation
agentUploadDownloadTest cfg caFile = do
  createDirectoryIfMissing False "tests/tmp/xftp-server-files"
  withXFTPServerCfg cfg $ \_ -> do
    Fingerprint fp <- loadFileFingerprint caFile
    let fpStr = map (toEnum . fromIntegral) $ B.unpack $ strEncode fp
        addr = "xftp://" <> fpStr <> "@localhost:" <> xftpTestPort
    result <-
      callNode $
        "import sodium from 'libsodium-wrappers-sumo';\
        \import crypto from 'node:crypto';\
        \import * as Addr from './dist/protocol/address.js';\
        \import * as Agent from './dist/agent.js';\
        \await sodium.ready;\
        \const server = Addr.parseXFTPServer('"
          <> addr
          <> "');\
             \const agent = Agent.newXFTPAgent();\
             \const originalData = new Uint8Array(crypto.randomBytes(50000));\
             \const encrypted = Agent.encryptFileForUpload(originalData, 'test-file.bin');\
             \const {rcvDescription, sndDescription, uri} = await Agent.uploadFile(agent, server, encrypted);\
             \const fd = Agent.decodeDescriptionURI(uri);\
             \const {header, content} = await Agent.downloadFile(agent, fd);\
             \Agent.closeXFTPAgent(agent);\
             \const nameMatch = header.fileName === 'test-file.bin' ? 1 : 0;\
             \const sizeMatch = content.length === originalData.length ? 1 : 0;\
             \let dataMatch = 1;\
             \for (let i = 0; i < content.length; i++) {\
             \  if (content[i] !== originalData[i]) { dataMatch = 0; break; }\
             \};"
          <> jsOut "new Uint8Array([nameMatch, sizeMatch, dataMatch])"
    result `shouldBe` B.pack [1, 1, 1]

agentDeleteTest :: XFTPServerConfig -> FilePath -> Expectation
agentDeleteTest cfg caFile = do
  createDirectoryIfMissing False "tests/tmp/xftp-server-files"
  withXFTPServerCfg cfg $ \_ -> do
    Fingerprint fp <- loadFileFingerprint caFile
    let fpStr = map (toEnum . fromIntegral) $ B.unpack $ strEncode fp
        addr = "xftp://" <> fpStr <> "@localhost:" <> xftpTestPort
    result <-
      callNode $
        "import sodium from 'libsodium-wrappers-sumo';\
        \import crypto from 'node:crypto';\
        \import * as Addr from './dist/protocol/address.js';\
        \import * as Agent from './dist/agent.js';\
        \await sodium.ready;\
        \const server = Addr.parseXFTPServer('"
          <> addr
          <> "');\
             \const agent = Agent.newXFTPAgent();\
             \const originalData = new Uint8Array(crypto.randomBytes(50000));\
             \const encrypted = Agent.encryptFileForUpload(originalData, 'del-test.bin');\
             \const {rcvDescription, sndDescription} = await Agent.uploadFile(agent, server, encrypted);\
             \await Agent.deleteFile(agent, sndDescription);\
             \let deleted = 0;\
             \try {\
             \  await Agent.downloadFile(agent, rcvDescription);\
             \} catch (e) {\
             \  deleted = 1;\
             \}\
             \Agent.closeXFTPAgent(agent);"
          <> jsOut "new Uint8Array([deleted])"
    result `shouldBe` B.pack [1]

agentRedirectTest :: XFTPServerConfig -> FilePath -> Expectation
agentRedirectTest cfg caFile = do
  createDirectoryIfMissing False "tests/tmp/xftp-server-files"
  withXFTPServerCfg cfg $ \_ -> do
    Fingerprint fp <- loadFileFingerprint caFile
    let fpStr = map (toEnum . fromIntegral) $ B.unpack $ strEncode fp
        addr = "xftp://" <> fpStr <> "@localhost:" <> xftpTestPort
    result <-
      callNode $
        "import sodium from 'libsodium-wrappers-sumo';\
        \import crypto from 'node:crypto';\
        \import * as Addr from './dist/protocol/address.js';\
        \import * as Agent from './dist/agent.js';\
        \await sodium.ready;\
        \const server = Addr.parseXFTPServer('"
          <> addr
          <> "');\
             \const agent = Agent.newXFTPAgent();\
             \const originalData = new Uint8Array(crypto.randomBytes(100000));\
             \const encrypted = Agent.encryptFileForUpload(originalData, 'redirect-test.bin');\
             \const {rcvDescription, uri} = await Agent.uploadFile(agent, server, encrypted, {redirectThreshold: 50});\
             \const fd = Agent.decodeDescriptionURI(uri);\
             \const hasRedirect = fd.redirect !== null ? 1 : 0;\
             \const {header, content} = await Agent.downloadFile(agent, fd);\
             \Agent.closeXFTPAgent(agent);\
             \const nameMatch = header.fileName === 'redirect-test.bin' ? 1 : 0;\
             \const sizeMatch = content.length === originalData.length ? 1 : 0;\
             \let dataMatch = 1;\
             \for (let i = 0; i < content.length; i++) {\
             \  if (content[i] !== originalData[i]) { dataMatch = 0; break; }\
             \};"
          <> jsOut "new Uint8Array([hasRedirect, nameMatch, sizeMatch, dataMatch])"
    result `shouldBe` B.pack [1, 1, 1, 1]

tsUploadHaskellDownloadTest :: XFTPServerConfig -> FilePath -> Expectation
tsUploadHaskellDownloadTest cfg caFile = do
  createDirectoryIfMissing False "tests/tmp/xftp-server-files"
  createDirectoryIfMissing False recipientFiles
  withXFTPServerCfg cfg $ \_ -> do
    Fingerprint fp <- loadFileFingerprint caFile
    let fpStr = map (toEnum . fromIntegral) $ B.unpack $ strEncode fp
        addr = "xftp://" <> fpStr <> "@localhost:" <> xftpTestPort
    (yamlDesc, originalData) <-
      callNode2 $
        "import sodium from 'libsodium-wrappers-sumo';\
        \import crypto from 'node:crypto';\
        \import * as Addr from './dist/protocol/address.js';\
        \import * as Agent from './dist/agent.js';\
        \import {encodeFileDescription} from './dist/protocol/description.js';\
        \await sodium.ready;\
        \const server = Addr.parseXFTPServer('"
          <> addr
          <> "');\
             \const agent = Agent.newXFTPAgent();\
             \const originalData = new Uint8Array(crypto.randomBytes(50000));\
             \const encrypted = Agent.encryptFileForUpload(originalData, 'ts-to-hs.bin');\
             \const {rcvDescription} = await Agent.uploadFile(agent, server, encrypted);\
             \Agent.closeXFTPAgent(agent);\
             \const yaml = encodeFileDescription(rcvDescription);"
          <> jsOut2 "Buffer.from(yaml)" "Buffer.from(originalData)"
    let vfd :: ValidFileDescription 'FRecipient = either error id $ strDecode yamlDesc
    withAgent 1 agentCfg initAgentServers testDB $ \rcp -> do
      runRight_ $ xftpStartWorkers rcp (Just recipientFiles)
      _ <- runRight $ xftpReceiveFile rcp 1 vfd Nothing True
      rfProgress rcp 50000
      (_, _, RFDONE outPath) <- rfGet rcp
      downloadedData <- B.readFile outPath
      downloadedData `shouldBe` originalData

tsUploadRedirectHaskellDownloadTest :: XFTPServerConfig -> FilePath -> Expectation
tsUploadRedirectHaskellDownloadTest cfg caFile = do
  createDirectoryIfMissing False "tests/tmp/xftp-server-files"
  createDirectoryIfMissing False recipientFiles
  withXFTPServerCfg cfg $ \_ -> do
    Fingerprint fp <- loadFileFingerprint caFile
    let fpStr = map (toEnum . fromIntegral) $ B.unpack $ strEncode fp
        addr = "xftp://" <> fpStr <> "@localhost:" <> xftpTestPort
    (yamlDesc, originalData) <-
      callNode2 $
        "import sodium from 'libsodium-wrappers-sumo';\
        \import crypto from 'node:crypto';\
        \import * as Addr from './dist/protocol/address.js';\
        \import * as Agent from './dist/agent.js';\
        \import {encodeFileDescription} from './dist/protocol/description.js';\
        \await sodium.ready;\
        \const server = Addr.parseXFTPServer('"
          <> addr
          <> "');\
             \const agent = Agent.newXFTPAgent();\
             \const originalData = new Uint8Array(crypto.randomBytes(100000));\
             \const encrypted = Agent.encryptFileForUpload(originalData, 'ts-redirect-to-hs.bin');\
             \const {rcvDescription} = await Agent.uploadFile(agent, server, encrypted, {redirectThreshold: 50});\
             \Agent.closeXFTPAgent(agent);\
             \const yaml = encodeFileDescription(rcvDescription);"
          <> jsOut2 "Buffer.from(yaml)" "Buffer.from(originalData)"
    let vfd@(ValidFileDescription fd) :: ValidFileDescription 'FRecipient = either error id $ strDecode yamlDesc
    redirect fd `shouldSatisfy` (/= Nothing)
    withAgent 1 agentCfg initAgentServers testDB $ \rcp -> do
      runRight_ $ xftpStartWorkers rcp (Just recipientFiles)
      _ <- runRight $ xftpReceiveFile rcp 1 vfd Nothing True
      outPath <- waitRfDone rcp
      downloadedData <- B.readFile outPath
      downloadedData `shouldBe` originalData

haskellUploadTsDownloadTest :: XFTPServerConfig -> Expectation
haskellUploadTsDownloadTest cfg = do
  createDirectoryIfMissing False "tests/tmp/xftp-server-files"
  createDirectoryIfMissing False senderFiles
  let filePath = senderFiles <> "/hs-to-ts.bin"
  originalData <- B.pack <$> replicateM 50000 (randomIO :: IO Word8)
  B.writeFile filePath originalData
  withXFTPServerCfg cfg $ \_ -> do
    vfd <- withAgent 1 agentCfg initAgentServers testDB $ \sndr -> do
      runRight_ $ xftpStartWorkers sndr (Just senderFiles)
      _ <- runRight $ xftpSendFile sndr 1 (CF.plain filePath) 1
      sfProgress sndr 50000
      (_, _, SFDONE _ [rfd]) <- sfGet sndr
      pure rfd
    let yamlDesc = strEncode vfd
        tmpYaml = "tests/tmp/hs-to-ts-desc.yaml"
        tmpData = "tests/tmp/hs-to-ts-data.bin"
    B.writeFile tmpYaml yamlDesc
    B.writeFile tmpData originalData
    result <-
      callNode $
        "import fs from 'node:fs';\
        \import sodium from 'libsodium-wrappers-sumo';\
        \import * as Agent from './dist/agent.js';\
        \import {decodeFileDescription, validateFileDescription} from './dist/protocol/description.js';\
        \await sodium.ready;\
        \const yaml = fs.readFileSync('../tests/tmp/hs-to-ts-desc.yaml', 'utf-8');\
        \const expected = new Uint8Array(fs.readFileSync('../tests/tmp/hs-to-ts-data.bin'));\
        \const fd = decodeFileDescription(yaml);\
        \const err = validateFileDescription(fd);\
        \if (err) throw new Error(err);\
        \const agent = Agent.newXFTPAgent();\
        \const {header, content} = await Agent.downloadFile(agent, fd);\
        \Agent.closeXFTPAgent(agent);\
        \const nameMatch = header.fileName === 'hs-to-ts.bin' ? 1 : 0;\
        \const sizeMatch = content.length === expected.length ? 1 : 0;\
        \let dataMatch = 1;\
        \for (let i = 0; i < content.length; i++) {\
        \  if (content[i] !== expected[i]) { dataMatch = 0; break; }\
        \};"
          <> jsOut "new Uint8Array([nameMatch, sizeMatch, dataMatch])"
    result `shouldBe` B.pack [1, 1, 1]

rfProgress :: AgentClient -> Int64 -> IO ()
rfProgress c _expected = loop 0
  where
    loop prev = do
      (_, _, RFPROG rcvd total) <- rfGet c
      when (rcvd < total && rcvd > prev) $ loop rcvd

sfProgress :: AgentClient -> Int64 -> IO ()
sfProgress c _expected = loop 0
  where
    loop prev = do
      (_, _, SFPROG sent total) <- sfGet c
      when (sent < total && sent > prev) $ loop sent

waitRfDone :: AgentClient -> IO FilePath
waitRfDone c = do
  ev <- rfGet c
  case ev of
    (_, _, RFDONE outPath) -> pure outPath
    (_, _, RFPROG _ _) -> waitRfDone c
    (_, _, RFERR e) -> error $ "RFERR: " <> show e
    _ -> error $ "Unexpected event: " <> show ev

callNode2 :: String -> IO (B.ByteString, B.ByteString)
callNode2 script = do
  out <- callNode script
  let (len1Bytes, rest1) = B.splitAt 4 out
      len1 = fromIntegral (B.index len1Bytes 0) + fromIntegral (B.index len1Bytes 1) * 256 + fromIntegral (B.index len1Bytes 2) * 65536 + fromIntegral (B.index len1Bytes 3) * 16777216
      (data1, rest2) = B.splitAt len1 rest1
      (len2Bytes, rest3) = B.splitAt 4 rest2
      len2 = fromIntegral (B.index len2Bytes 0) + fromIntegral (B.index len2Bytes 1) * 256 + fromIntegral (B.index len2Bytes 2) * 65536 + fromIntegral (B.index len2Bytes 3) * 16777216
      data2 = B.take len2 rest3
  pure (data1, data2)

jsOut2 :: String -> String -> String
jsOut2 a b = "const __a = " <> a <> "; const __b = " <> b <> "; const __buf = Buffer.alloc(8 + __a.length + __b.length); __buf.writeUInt32LE(__a.length, 0); __a.copy(__buf, 4); __buf.writeUInt32LE(__b.length, 4 + __a.length); __b.copy(__buf, 8 + __a.length); process.stdout.write(__buf);"
