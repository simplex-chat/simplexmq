{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

-- | Per-function tests for the smp-web TypeScript SMP client library.
-- Each test calls the Haskell function and the corresponding TypeScript function
-- via node, then asserts byte-identical output.
--
-- Prerequisites: cd smp-web && npm install && npm run build
-- Run: cabal test --test-option=--match="/SMP Web Client/"
module SMPWebTests (smpWebTests) where

import Control.Concurrent.STM (atomically)
import Control.Monad.Except (ExceptT, runExceptT)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC
import Data.List.NonEmpty (NonEmpty (..))
import System.Directory (doesDirectoryExist)
import Data.Word (Word16)
import qualified Simplex.Messaging.Agent as A
import qualified Simplex.Messaging.Agent.Protocol as AP
import Simplex.Messaging.Agent.Protocol (CreatedConnLink (..), UserLinkData (..), UserContactData (..), UserConnLinkData (..))
import Simplex.Messaging.Client (pattern NRMInteractive)
import Simplex.Messaging.Version (mkVersionRange)
import Simplex.Messaging.Version.Internal (Version (..))
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Crypto (Algorithm (..))
import qualified Simplex.Messaging.Crypto.Ratchet as CR
import Simplex.Messaging.Crypto.SNTRUP761.Bindings (KEMPublicKey (..), KEMSecretKey, KEMCiphertext (..), KEMSharedKey (..), sntrup761Keypair, sntrup761Enc, sntrup761Dec)
import qualified Crypto.Cipher.Types as AES
import qualified Data.Map.Strict as M
import qualified Data.ByteArray as BA
import Simplex.Messaging.Crypto.ShortLink (contactShortLinkKdf, invShortLinkKdf)
import Simplex.Messaging.Encoding
import Simplex.Messaging.Encoding.String (Str (..), strEncode)
import Simplex.Messaging.Protocol (EntityId (..), SMPServer, SubscriptionMode (..), MsgFlags (..), pattern SMPServer, encodeProtocol, Command (..), NewQueueReq (..), BrokerMsg (..), RcvMessage (..), EncRcvMsgBody (..), QueueIdsKeys (..))
import Simplex.Messaging.Server.Env.STM (AStoreType (..))
import Simplex.Messaging.Server.MsgStore.Types (SMSType (..), SQSType (..))
import Simplex.Messaging.Server.Web (attachStaticAndWS)
import Simplex.Messaging.Transport (TLS, smpBlockSize, currentServerSMPRelayVersion)
import Simplex.Messaging.Transport.Client (TransportHost (..))
import SMPAgentClient (agentCfg, initAgentServers, testDB)
import SMPClient (cfgWebOn, testKeyHash, testPort, withSmpServerConfig)
import AgentTests.FunctionalAPITests (withAgent)
import Test.Hspec hiding (it)
import Util
import XFTPWebTests (callNode_, jsOut, jsUint8)

smpWebDir :: FilePath
smpWebDir = "smp-web"

callNode :: String -> IO B.ByteString
callNode = callNode_ smpWebDir

impEnc :: String
impEnc = "import { Decoder, decodeBytes, decodeLarge, encodeBytes, encodeWord16 } from '@simplex-chat/xftp-web/dist/protocol/encoding.js';"

impProto_ :: String
impProto_ = "import { encodeTransmission, encodeBatch, decodeTransmission, encodeLGET, decodeLNK, decodeResponse, encodeNEW, encodeKEY, encodeSKEY, encodeSUB, encodeACK, encodeSEND, encodeOFF, encodeDEL } from './dist/protocol.js';"

impProto :: String
impProto = impEnc <> impProto_

impTransport :: String
impTransport = "import { decodeSMPServerHandshake, encodeSMPClientHandshake } from './dist/transport.js';"
  <> "import { Decoder, encodeWord16 } from '@simplex-chat/xftp-web/dist/protocol/encoding.js';"

impWS :: String
impWS = "import { connectSMP, sendBlock, receiveBlock } from './dist/transport/websockets.js';"
  <> "import { blockPad, blockUnpad } from '@simplex-chat/xftp-web/dist/protocol/transmission.js';"

impAgentProto_ :: String
impAgentProto_ = "import { connShortLinkStrP, decodeConnLinkData, decodeFixedLinkData, decodeProtocolServer, decodeConnShortLink, decodeOwnerAuth, decodeUserLinkData, parseProfile } from './dist/agent/protocol.js';"

impAgentProto :: String
impAgentProto = impEnc <> impAgentProto_

impCryptoShortLink :: String
impCryptoShortLink = "import { contactShortLinkKdf, invShortLinkKdf, decryptLinkData } from './dist/crypto/shortLink.js';"

impRatchet :: String
impRatchet = "import { generateX448KeyPair, pqX3dhSnd, pqX3dhRcv, x448DH, encodePubKeyX448, decodePubKeyX448, chainKdf, rootKdf, initSndRatchet, initRcvRatchet, rcEncrypt, rcDecrypt } from './dist/crypto/ratchet.js';"
  <> "import { encryptAEAD, decryptAEAD } from './dist/crypto.js';"

impSntrup :: String
impSntrup = "import { initSntrup761, sntrup761Keypair, sntrup761Enc, sntrup761Dec } from './dist/crypto/sntrup761.js'; await initSntrup761();"

impCrypto :: String
impCrypto = "import { sbcInit, sbcHkdf, sbEncryptBlock, sbDecryptBlock } from './dist/crypto.js';"

-- Init sodium from xftp-web's copy (same instance secretbox.ts uses)
impSodium :: String
impSodium = "import sodium from '@simplex-chat/xftp-web/node_modules/libsodium-wrappers-sumo/dist/modules-sumo/libsodium-wrappers.js'; await sodium.ready;"

jsStr :: B.ByteString -> String
jsStr bs = "'" <> BC.unpack bs <> "'"

paddedMsgLen :: Int
paddedMsgLen = 100

runRight :: (Show e, HasCallStack) => ExceptT e IO a -> IO a
runRight action = runExceptT action >>= either (error . ("Unexpected error: " <>) . show) pure

smpWebTests :: SpecWith ()
smpWebTests = describe "SMP Web Client" $ do
  distExists <- runIO $ doesDirectoryExist (smpWebDir <> "/dist")
  if distExists
    then smpWebTests_
    else
      it "skipped (run 'cd smp-web && npm install && npm run build' first)" $
        pendingWith "TS project not compiled"

smpWebTests_ :: SpecWith ()
smpWebTests_ = do
  describe "protocol" $ do
    describe "transmission" $ do
      it "encodeTransmission matches Haskell" $ do
        let corrId = "1"
            entityId = B.pack [1..24]
            command = "LGET"
            hsEncoded = smpEncode (corrId :: B.ByteString, entityId :: B.ByteString) <> command
        tsEncoded <- callNode $ impProto
          <> jsOut ("encodeTransmission("
          <> jsUint8 corrId <> ","
          <> jsUint8 entityId <> ","
          <> "new Uint8Array([0x4C,0x47,0x45,0x54])"
          <> ")")
        tsEncoded `shouldBe` (B.singleton 0 <> hsEncoded)

      it "decodeTransmission parses Haskell-encoded" $ do
        let corrId = "abc"
            entityId = B.pack [10..33]
            command = "TEST"
            encoded = smpEncode (B.empty :: B.ByteString)
              <> smpEncode corrId
              <> smpEncode entityId
              <> command
        tsResult <- callNode $ impProto
          <> "const t = decodeTransmission(new Decoder(" <> jsUint8 encoded <> "));"
          <> jsOut ("new Uint8Array([...t.corrId, ...t.entityId, ...t.command])")
        tsResult `shouldBe` (corrId <> entityId <> command)

    describe "LGET" $ do
      it "encodeLGET produces correct bytes" $ do
        tsResult <- callNode $ impProto <> jsOut "encodeLGET()"
        tsResult `shouldBe` "LGET"

    describe "LNK" $ do
      it "decodeLNK parses correctly" $ do
        let senderId = B.pack [1..24]
            fixedData = B.pack [100..110]
            userData = B.pack [200..220]
            encoded = smpEncode senderId <> smpEncode (Large fixedData) <> smpEncode (Large userData)
        tsResult <- callNode $ impProto
          <> "const r = decodeLNK(new Decoder(" <> jsUint8 encoded <> "));"
          <> jsOut ("new Uint8Array([...r.senderId, ...r.encFixedData, ...r.encUserData])")
        tsResult `shouldBe` (senderId <> fixedData <> userData)

    describe "decodeResponse" $ do
      it "decodes LNK response" $ do
        let senderId = B.pack [1..24]
            fixedData = B.pack [100..110]
            userData = B.pack [200..220]
            commandBytes = "LNK " <> smpEncode senderId <> smpEncode (Large fixedData) <> smpEncode (Large userData)
        tsResult <- callNode $ impProto
          <> "const r = decodeResponse(new Decoder(" <> jsUint8 commandBytes <> "));"
          <> "if (r.type !== 'LNK') throw new Error('expected LNK, got ' + r.type);"
          <> jsOut ("new Uint8Array([...r.response.senderId])")
        tsResult `shouldBe` senderId

      it "decodes OK response" $ do
        tsResult <- callNode $ impProto
          <> "const r = decodeResponse(new Decoder(new Uint8Array([0x4F, 0x4B])));"
          <> jsOut ("new Uint8Array([r.type === 'OK' ? 1 : 0])")
        tsResult `shouldBe` B.singleton 1

    describe "commands" $ do
      let v = currentServerSMPRelayVersion

      it "encodeSUB matches Haskell" $ do
        let hsEncoded = encodeProtocol v SUB
        tsEncoded <- callNode $ impProto <> jsOut "encodeSUB()"
        tsEncoded `shouldBe` hsEncoded

      it "encodeKEY matches Haskell" $ do
        let keyDer = B.pack [0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x6e, 0x03, 0x21, 0x00] <> B.pack [1..32]
            hsEncoded = "KEY " <> smpEncode keyDer
        tsEncoded <- callNode $ impProto
          <> jsOut ("encodeKEY(" <> jsUint8 keyDer <> ")")
        tsEncoded `shouldBe` hsEncoded

      it "encodeSKEY matches Haskell" $ do
        let keyDer = B.pack [0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x6e, 0x03, 0x21, 0x00] <> B.pack [1..32]
            hsEncoded = "SKEY " <> smpEncode keyDer
        tsEncoded <- callNode $ impProto
          <> jsOut ("encodeSKEY(" <> jsUint8 keyDer <> ")")
        tsEncoded `shouldBe` hsEncoded

      it "encodeACK matches Haskell" $ do
        let msgId = B.pack [1..24]
            hsEncoded = encodeProtocol v (ACK msgId)
        tsEncoded <- callNode $ impProto
          <> jsOut ("encodeACK(" <> jsUint8 msgId <> ")")
        tsEncoded `shouldBe` hsEncoded

      it "encodeSEND matches Haskell" $ do
        let flags = MsgFlags {notification = True}
            body = "hello world"
            hsEncoded = encodeProtocol v (SEND flags body)
        tsEncoded <- callNode $ impProto
          <> jsOut ("encodeSEND(true, new TextEncoder().encode('hello world'))")
        tsEncoded `shouldBe` hsEncoded

      it "decodes IDS response" $ do
        let rcvId = B.pack [1..24]
            sndId = B.pack [25..48]
            srvDhKey = B.pack [0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x6e, 0x03, 0x21, 0x00] <> B.pack [50..81]
            -- Manually encode IDS response: "IDS " <> rcvId <> sndId <> srvDhKey <> Maybe queueMode <> Maybe linkId ...
            encoded = "IDS " <> smpEncode (EntityId rcvId) <> smpEncode (EntityId sndId) <> smpEncode srvDhKey
              <> smpEncode (Nothing :: Maybe B.ByteString) <> smpEncode (Nothing :: Maybe B.ByteString)
              <> smpEncode (Nothing :: Maybe B.ByteString) <> smpEncode (Nothing :: Maybe B.ByteString)
        tsResult <- callNode $ impProto
          <> "const r = decodeResponse(new Decoder(" <> jsUint8 encoded <> "));"
          <> "if (r.type !== 'IDS') throw new Error('expected IDS, got ' + r.type);"
          <> jsOut ("new Uint8Array([...r.response.rcvId, ...r.response.sndId])")
        tsResult `shouldBe` (rcvId <> sndId)

      it "decodes Haskell-encoded MSG response" $ do
        let msgId = B.pack [1..24]
            body = "encrypted message body"
            hsEncoded = "MSG " <> smpEncode msgId <> body
        tsResult <- callNode $ impProto
          <> "const r = decodeResponse(new Decoder(" <> jsUint8 hsEncoded <> "));"
          <> "if (r.type !== 'MSG') throw new Error('expected MSG, got ' + r.type);"
          <> jsOut ("new Uint8Array([...r.response.msgId, ...r.response.msgBody])")
        tsResult `shouldBe` (msgId <> body)

  describe "transport" $ do
    describe "SMPServerHandshake" $ do
      it "TypeScript parses Haskell-encoded server handshake (no authPubKey)" $ do
        -- Manually construct: smpEncode (versionRange, sessionId) <> "" (no authPubKey)
        let vRange = (6 :: Word16, 18 :: Word16)
            sessId = B.pack [1..32]
            encoded = smpEncode vRange <> smpEncode sessId
        tsResult <- callNode $ impTransport
          <> "const hs = decodeSMPServerHandshake(new Decoder(" <> jsUint8 encoded <> "));"
          <> jsOut ("new Uint8Array(["
          <> "hs.smpVersionRange.min, hs.smpVersionRange.max,"
          <> "hs.authPubKey === null ? 1 : 0,"
          <> "hs.sessionId.length"
          <> "])")
        tsResult `shouldBe` B.pack [6, 18, 1, 32]

    describe "SMPClientHandshake" $ do
      it "TypeScript-encoded client handshake matches Haskell (no authPubKey)" $ do
        -- Haskell encoding: smpEncode (v18, keyHash) <> "" (no authPubKey) <> smpEncode False <> smpEncode (Nothing :: Maybe ())
        let v = 18 :: Word16
            keyHash = B.pack [1..32]
            hsEncoded = smpEncode (v, keyHash)
              <> ""  -- authPubKey Nothing = empty
              <> smpEncode False  -- proxyServer
              <> smpEncode (Nothing :: Maybe B.ByteString) -- clientService
        tsEncoded <- callNode $ impTransport
          <> jsOut ("encodeSMPClientHandshake({"
          <> "smpVersion: 18,"
          <> "keyHash: " <> jsUint8 keyHash <> ","
          <> "authPubKey: null,"
          <> "proxyServer: false,"
          <> "clientService: null"
          <> "})")
        tsEncoded `shouldBe` hsEncoded

  describe "crypto/shortLink" $ do
    describe "contactShortLinkKdf" $ do
      it "TypeScript produces same linkId and sbKey as Haskell" $ do
        let linkKey = AP.LinkKey $ B.pack [1..32]
            (EntityId hsLinkId, C.SbKey hsKey) = contactShortLinkKdf linkKey
        tsResult <- callNode $ impCryptoShortLink
          <> "const r = contactShortLinkKdf(" <> jsUint8 (B.pack [1..32]) <> ");"
          <> jsOut ("new Uint8Array([...r.linkId, ...r.sbKey])")
        tsResult `shouldBe` (hsLinkId <> hsKey)

    describe "invShortLinkKdf" $ do
      it "TypeScript produces same sbKey as Haskell" $ do
        let linkKey = AP.LinkKey $ B.pack [50..81]
            C.SbKey hsKey = invShortLinkKdf linkKey
        tsResult <- callNode $ impCryptoShortLink
          <> jsOut ("invShortLinkKdf(" <> jsUint8 (B.pack [50..81]) <> ")")
        tsResult `shouldBe` hsKey

    describe "decryptLinkData" $ do
      it "TypeScript decrypts Haskell-encrypted data" $ do
        let sbKey = C.unsafeSbKey $ B.pack [1..32]
            nonce = C.cbNonce $ B.pack [1..24]
            -- Simulate encodeSign: smpEncode signature <> plaintext
            fakeSig = B.pack [1..64] -- 64-byte "signature"
            fixedPlain = "fixed-data-here"
            userPlain = "user-data-here"
            signedFixed = smpEncode fakeSig <> fixedPlain
            signedUser = smpEncode fakeSig <> userPlain
        case (,) <$> C.sbEncrypt sbKey nonce signedFixed 2008
                 <*> C.sbEncrypt sbKey nonce signedUser 13784 of
          Left e -> expectationFailure $ "encrypt failed: " <> show e
          Right (ctFixed, ctUser) -> do
            let encFixed = C.unCbNonce nonce <> ctFixed
                encUser = C.unCbNonce nonce <> ctUser
            tsResult <- callNode $ impSodium <> impCryptoShortLink
              <> "const r = decryptLinkData("
              <> jsUint8 (C.unSbKey sbKey) <> ","
              <> jsUint8 encFixed <> ","
              <> jsUint8 encUser <> ");"
              <> jsOut ("new Uint8Array([...r.fixedData, 0, ...r.userData])")
            tsResult `shouldBe` (fixedPlain <> B.singleton 0 <> userPlain)

  describe "crypto/sntrup761" $ do
    it "TypeScript encapsulates, Haskell decapsulates - shared secret matches" $ do
      g <- C.newRandom
      (KEMPublicKey pkBytes, sk) <- sntrup761Keypair g
      tsResult <- callNode $ impSntrup
        <> "const enc = sntrup761Enc(" <> jsUint8 pkBytes <> ");"
        <> jsOut ("new Uint8Array([...enc.ciphertext, ...enc.sharedSecret])")
      let (ctBytes, tsSharedSecret) = B.splitAt 1039 tsResult
      KEMSharedKey hsSharedSecret <- sntrup761Dec (KEMCiphertext ctBytes) sk
      (BA.convert hsSharedSecret :: B.ByteString) `shouldBe` tsSharedSecret

    it "Haskell encapsulates, TypeScript decapsulates - shared secret matches" $ do
      -- TypeScript generates keypair, passes public key to Haskell via stdout,
      -- but callNode is one-shot. So: TypeScript generates keypair, outputs (pk, sk).
      -- Then Haskell encapsulates against pk, passes (ct) to TypeScript.
      -- TypeScript decapsulates with sk, outputs shared secret.
      -- We compare with Haskell's shared secret.
      --
      -- Two callNode calls: first to get keypair, second to decapsulate.
      kpResult <- callNode $ impSntrup
        <> "const kp = sntrup761Keypair();"
        <> jsOut ("new Uint8Array([...kp.publicKey, ...kp.secretKey])")
      let (tsPk, tsSk) = B.splitAt 1158 kpResult
      g <- C.newRandom
      (KEMCiphertext ctBytes, KEMSharedKey hsSharedSecret) <- sntrup761Enc g (KEMPublicKey tsPk)
      tsResult <- callNode $ impSntrup
        <> "const ss = sntrup761Dec(" <> jsUint8 ctBytes <> "," <> jsUint8 tsSk <> ");"
        <> jsOut ("ss")
      tsResult `shouldBe` (BA.convert hsSharedSecret :: B.ByteString)

  describe "crypto/aesGcm" $ do
    it "Haskell encryptAEAD (16-byte IV), TypeScript decrypts" $ do
      let key = C.Key $ B.pack [1..32]
          iv = C.IV $ B.pack [1..16]
          ad = "associated data"
          msg = "hello from haskell aes-gcm"
      Right (C.AuthTag authTag, ct) <- runExceptT $ C.encryptAEAD key iv 64 ad msg
      let tagBytes = BA.convert authTag :: B.ByteString
      tsResult <- callNode $ impEnc
        <> "import { gcm } from '@noble/ciphers/aes.js';"
        <> "const key = " <> jsUint8 (B.pack [1..32]) <> ";"
        <> "const iv = " <> jsUint8 (B.pack [1..16]) <> ";"
        <> "const ad = new TextEncoder().encode('associated data');"
        <> "const ct = " <> jsUint8 ct <> ";"
        <> "const tag = " <> jsUint8 tagBytes <> ";"
        <> "const cipher = gcm(key, iv, ad);"
        <> "const encrypted = new Uint8Array([...ct, ...tag]);"
        <> "const decrypted = cipher.decrypt(encrypted);"
        -- unpad: 2-byte BE length prefix + message + '#' padding
        <> "const len = (decrypted[0] << 8) | decrypted[1];"
        <> jsOut ("decrypted.subarray(2, 2 + len)")
      tsResult `shouldBe` msg

  describe "crypto/ratchet" $ do
    describe "X3DH" $ do
      it "pqX3dhSnd and pqX3dhRcv produce same ratchetKey" $ do
        -- TypeScript generates two key pairs, computes X3DH from both sides, verifies match
        tsResult <- callNode $ impSodium <> impRatchet
          <> "const alice1 = generateX448KeyPair();"
          <> "const alice2 = generateX448KeyPair();"
          <> "const bob1 = generateX448KeyPair();"
          <> "const bob2 = generateX448KeyPair();"
          -- Bob (joiner) inits sending ratchet with Alice's public keys
          <> "const snd = pqX3dhSnd(bob1.privateKey, bob2.privateKey, alice1.publicKey, alice2.publicKey);"
          -- Alice (initiator) inits receiving ratchet with Bob's public keys
          <> "const rcv = pqX3dhRcv(alice1.privateKey, alice2.privateKey, bob1.publicKey, bob2.publicKey);"
          -- ratchetKey, sndHK, rcvNextHK should match
          <> "const match = snd.ratchetKey.every((b, i) => b === rcv.ratchetKey[i]) && snd.sndHK.every((b, i) => b === rcv.sndHK[i]) && snd.rcvNextHK.every((b, i) => b === rcv.rcvNextHK[i]);"
          <> jsOut ("new Uint8Array([match ? 1 : 0, snd.ratchetKey.length, snd.sndHK.length, snd.rcvNextHK.length])")
        tsResult `shouldBe` B.pack [1, 32, 32, 32]

    describe "chainKdf" $ do
      it "TypeScript chainKdf produces correct output via HKDF" $ do
        -- chainKdf is hkdf3("", ck, "SimpleXChainRatchet") split into 32+32+16+16
        -- Since hkdf is already tested against Haskell, test the split logic
        tsResult <- callNode $ impRatchet
          <> "const r = chainKdf(" <> jsUint8 (B.pack [1..32]) <> ");"
          <> jsOut ("new Uint8Array([r.ck.length, r.mk.length, r.iv.length, r.ehIV.length])")
        tsResult `shouldBe` B.pack [32, 32, 16, 16]

    describe "encryptAEAD" $ do
      it "TypeScript encrypt matches Haskell encrypt (same ciphertext)" $ do
        let key = C.Key $ B.pack [1..32]
            iv = C.IV $ B.pack [1..16]
            ad = "test associated data"
            msg = "ratchet plaintext"
        Right (C.AuthTag hsTag, hsCt) <- runExceptT $ C.encryptAEAD key iv 64 ad msg
        let hsTagBytes = BA.convert hsTag :: B.ByteString
        tsResult <- callNode $ impRatchet
          <> "const r = encryptAEAD(" <> jsUint8 (B.pack [1..32]) <> "," <> jsUint8 (B.pack [1..16]) <> ",64,"
          <> "new TextEncoder().encode('test associated data'),"
          <> "new TextEncoder().encode('ratchet plaintext'));"
          <> jsOut ("new Uint8Array([...r.authTag, ...r.ciphertext])")
        tsResult `shouldBe` (hsTagBytes <> hsCt)

      it "TypeScript decrypts Haskell-encrypted" $ do
        let key = C.Key $ B.pack [10..41]
            iv = C.IV $ B.pack [10..25]
            ad = "ad for decrypt test"
            msg = "hello from haskell ratchet"
        Right (C.AuthTag hsTag, hsCt) <- runExceptT $ C.encryptAEAD key iv 64 ad msg
        let hsTagBytes = BA.convert hsTag :: B.ByteString
        tsResult <- callNode $ impRatchet
          <> "const plain = decryptAEAD(" <> jsUint8 (B.pack [10..41]) <> "," <> jsUint8 (B.pack [10..25]) <> ","
          <> "new TextEncoder().encode('ad for decrypt test'),"
          <> jsUint8 hsCt <> "," <> jsUint8 hsTagBytes <> ");"
          <> jsOut ("plain")
        tsResult `shouldBe` msg

      it "Haskell decrypts TypeScript-encrypted" $ do
        let key = C.Key $ B.pack [20..51]
            iv = C.IV $ B.pack [20..35]
            ad = "ad for ts encrypt"
            msg = "hello from typescript ratchet"
        tsResult <- callNode $ impRatchet
          <> "const r = encryptAEAD(" <> jsUint8 (B.pack [20..51]) <> "," <> jsUint8 (B.pack [20..35]) <> ",64,"
          <> "new TextEncoder().encode('ad for ts encrypt'),"
          <> "new TextEncoder().encode('hello from typescript ratchet'));"
          <> jsOut ("new Uint8Array([...r.authTag, ...r.ciphertext])")
        let (tsTag, tsCt) = B.splitAt 16 tsResult
        Right hsPlain <- runExceptT $ C.decryptAEAD key iv ad tsCt (C.AuthTag $ AES.AuthTag $ BA.convert tsTag)
        hsPlain `shouldBe` msg

    describe "ratchet encrypt/decrypt" $ do
      it "TypeScript ratchet self-consistency: encrypt, decrypt, ratchet advance, skipped" $ do
        tsResult <- callNode $ impRatchet
          <> "const a1 = generateX448KeyPair(), a2 = generateX448KeyPair();"
          <> "const b1 = generateX448KeyPair(), b2 = generateX448KeyPair();"
          <> "const bp = pqX3dhSnd(b1.privateKey, b2.privateKey, a1.publicKey, a2.publicKey);"
          <> "const ap = pqX3dhRcv(a1.privateKey, a2.privateKey, b1.publicKey, b2.publicKey);"
          <> "const b3 = generateX448KeyPair();"
          <> "let bob = initSndRatchet({current:3,maxSupported:3}, a2.publicKey, b3.privateKey, bp, null);"
          <> "let alice = initRcvRatchet({current:3,maxSupported:3}, a2.privateKey, ap, null, false);"
          <> "let sk = new Map();"
          -- Bob sends 3
          <> "const e1 = rcEncrypt(bob, new TextEncoder().encode('msg1'), 100); bob = e1.state;"
          <> "const e2 = rcEncrypt(bob, new TextEncoder().encode('msg2'), 100); bob = e2.state;"
          <> "const e3 = rcEncrypt(bob, new TextEncoder().encode('msg3'), 100); bob = e3.state;"
          -- Alice decrypts msg3 first (skip 1,2)
          <> "let d3 = rcDecrypt(alice, sk, e3.ciphertext); alice = d3.state; sk = d3.skippedKeys;"
          -- Alice decrypts msg1 from skipped
          <> "let d1 = rcDecrypt(alice, sk, e1.ciphertext); alice = d1.state; sk = d1.skippedKeys;"
          -- Alice responds
          <> "const ea = rcEncrypt(alice, new TextEncoder().encode('reply'), 100); alice = ea.state;"
          <> "const da = rcDecrypt(bob, new Map(), ea.ciphertext); bob = da.state;"
          -- Verify
          <> "const ok = new TextDecoder().decode(d3.plaintext) === 'msg3'"
          <> " && new TextDecoder().decode(d1.plaintext) === 'msg1'"
          <> " && new TextDecoder().decode(da.plaintext) === 'reply';"
          <> jsOut ("new Uint8Array([ok ? 1 : 0])")
        tsResult `shouldBe` B.singleton 1

      it "cross-language: Haskell encrypts, TypeScript decrypts" $ do
        -- Round 1: TypeScript generates alice's keys, outputs private keys + smpEncoded E2E params
        tsAliceOutput <- callNode $ impEnc <> impRatchet
          <> "const a1 = generateX448KeyPair(), a2 = generateX448KeyPair();"
          -- smpEncode E2ERatchetParams v3: (version, pk1, pk2, Maybe KEMParams)
          -- Nothing = 0x30 ('0')
          <> "const e2e = new Uint8Array([...encodeWord16(3), ...encodeBytes(encodePubKeyX448(a1.publicKey)), ...encodeBytes(encodePubKeyX448(a2.publicKey)), 0x30]);"
          -- Output: a1.privateKey(56) + a2.privateKey(56) + e2e_len(2) + e2e_bytes
          <> "const lenBuf = new Uint8Array(2); lenBuf[0] = (e2e.length >> 8) & 0xff; lenBuf[1] = e2e.length & 0xff;"
          <> jsOut ("new Uint8Array([...a1.privateKey, ...a2.privateKey, ...lenBuf, ...e2e])")
        let (alicePriv1, rest1) = B.splitAt 56 tsAliceOutput
            (alicePriv2, rest2) = B.splitAt 56 rest1
            e2eLen = fromIntegral (B.index rest2 0) * 256 + fromIntegral (B.index rest2 1)
            aliceE2EBytes = B.take e2eLen $ B.drop 2 rest2

        -- Round 2: Haskell decodes alice's E2E params, generates bob, encrypts
        g <- C.newRandom
        let v = CR.currentE2EEncryptVersion
        Right (aliceE2E@(CR.E2ERatchetParams _ _ alicePk2 _) :: CR.E2ERatchetParams 'CR.RKSProposed 'X448) <- pure $ smpDecode aliceE2EBytes
        (bobPk1, bobPk2, _pKem, CR.AE2ERatchetParams _ bobE2E) <- CR.generateSndE2EParams @'X448 g v Nothing
        Right (bobInitParams, _) <- pure $ CR.pqX3dhSnd bobPk1 bobPk2 Nothing aliceE2E
        (_, bobDHRs) <- atomically $ C.generateKeyPair @'X448 g
        let bobRatchet = CR.initSndRatchet (CR.RatchetVersions v v) alicePk2 bobDHRs (bobInitParams, Nothing)
        Right (mek, _) <- runExceptT $ CR.rcEncryptHeader bobRatchet Nothing v
        Right ciphertext <- runExceptT $ CR.rcEncryptMsg mek paddedMsgLen "hello from haskell ratchet"
        let bobE2EBytes = smpEncode bobE2E

        -- Round 3: TypeScript decodes bob's params, inits ratchet, decrypts
        tsResult <- callNode $ impEnc <> impRatchet
          -- Parse bob's E2E params
          <> "const d = new Decoder(" <> jsUint8 bobE2EBytes <> ");"
          <> "const bobV = d.anyByte() * 256 + d.anyByte();"
          <> "const bobPk1Raw = decodePubKeyX448(decodeBytes(d));"
          <> "const bobPk2Raw = decodePubKeyX448(decodeBytes(d));"
          <> "const a1Priv = " <> jsUint8 alicePriv1 <> ";"
          <> "const a2Priv = " <> jsUint8 alicePriv2 <> ";"
          <> "const ap = pqX3dhRcv(a1Priv, a2Priv, bobPk1Raw, bobPk2Raw);"
          <> "const alice = initRcvRatchet({current:3,maxSupported:3}, a2Priv, ap, null, false);"
          <> "const dec = rcDecrypt(alice, new Map(), " <> jsUint8 ciphertext <> ");"
          <> jsOut ("dec.plaintext")
        tsResult `shouldBe` "hello from haskell ratchet"

      it "cross-language: TypeScript encrypts, Haskell decrypts" $ do
        -- Round 1: Haskell generates alice's keys, outputs encoded E2E params
        g <- C.newRandom
        let v = CR.currentE2EEncryptVersion
        (alicePk1, alicePk2, _pKem, aliceE2E) <- CR.generateRcvE2EParams @'X448 g v CR.PQSupportOff
        let aliceE2EBytes = smpEncode aliceE2E

        -- Round 2: TypeScript generates bob's keys, does X3DH, inits snd ratchet, encrypts
        tsOutput <- callNode $ impEnc <> impRatchet
          -- Parse alice's E2E params
          <> "const d = new Decoder(" <> jsUint8 aliceE2EBytes <> ");"
          <> "const aliceV = d.anyByte() * 256 + d.anyByte();"
          <> "const alicePk1Raw = decodePubKeyX448(decodeBytes(d));"
          <> "const alicePk2Raw = decodePubKeyX448(decodeBytes(d));"
          -- Bob generates keys
          <> "const b1 = generateX448KeyPair(), b2 = generateX448KeyPair();"
          <> "const b3 = generateX448KeyPair();"
          -- X3DH (bob is sender)
          <> "const bp = pqX3dhSnd(b1.privateKey, b2.privateKey, alicePk1Raw, alicePk2Raw);"
          -- Init sending ratchet
          <> "let bob = initSndRatchet({current:3,maxSupported:3}, alicePk2Raw, b3.privateKey, bp, null);"
          -- Encrypt
          <> "const enc = rcEncrypt(bob, new TextEncoder().encode('hello from typescript ratchet'), 100);"
          -- Output: bob's E2E params (version + 2 DER keys + Nothing KEM) + ciphertext
          <> "const bobE2E = new Uint8Array([...encodeWord16(3), ...encodeBytes(encodePubKeyX448(b1.publicKey)), ...encodeBytes(encodePubKeyX448(b2.publicKey)), 0x30]);"
          <> "const lenBuf = new Uint8Array(2); lenBuf[0] = (bobE2E.length >> 8) & 0xff; lenBuf[1] = bobE2E.length & 0xff;"
          <> "const ctLenBuf = new Uint8Array(2); ctLenBuf[0] = (enc.ciphertext.length >> 8) & 0xff; ctLenBuf[1] = enc.ciphertext.length & 0xff;"
          <> jsOut ("new Uint8Array([...lenBuf, ...bobE2E, ...ctLenBuf, ...enc.ciphertext])")
        -- Parse output: [2 bytes e2e len][e2e bytes][2 bytes ct len][ct bytes]
        let (e2eLenBs, rest1) = B.splitAt 2 tsOutput
            bobE2ELen = fromIntegral (B.index e2eLenBs 0) * 256 + fromIntegral (B.index e2eLenBs 1)
            (bobE2EBytes, rest2) = B.splitAt bobE2ELen rest1
            (ctLenBs, rest3) = B.splitAt 2 rest2
            ctLen = fromIntegral (B.index ctLenBs 0) * 256 + fromIntegral (B.index ctLenBs 1)
            ciphertext = B.take ctLen rest3

        -- Round 3: Haskell decodes bob's params, does X3DH, inits rcv ratchet, decrypts
        Right (CR.AE2ERatchetParams _ bobE2EParams :: CR.AE2ERatchetParams 'X448) <- pure $ smpDecode bobE2EBytes
        Right (aliceInitParams, _) <- runExceptT $ CR.pqX3dhRcv alicePk1 alicePk2 Nothing bobE2EParams
        let aliceRatchet = CR.initRcvRatchet (CR.RatchetVersions v v) alicePk2 (aliceInitParams, Nothing) CR.PQSupportOff
        gAlice <- C.newRandom
        Right (msg, _, _) <- runExceptT $ CR.rcDecrypt gAlice aliceRatchet M.empty ciphertext
        msg `shouldBe` Right "hello from typescript ratchet"

      it "cross-language: PQ X3DH - Haskell proposes KEM, TypeScript accepts, encrypts" $ do
        -- Round 1: Haskell (alice) generates keys with PQ KEM proposal
        g <- C.newRandom
        let v = CR.currentE2EEncryptVersion
        (alicePk1, alicePk2, alicePKem_@(Just _), aliceE2E) <- CR.generateRcvE2EParams @'X448 g v CR.PQSupportOn
        let aliceE2EBytes = smpEncode aliceE2E

        -- Round 2: TypeScript (bob) accepts KEM, does X3DH, inits snd ratchet, encrypts
        tsOutput <- callNode $ impEnc <> impSodium <> impRatchet <> impSntrup
          -- Parse alice's E2E params (v3: version + pk1 + pk2 + Maybe ARKEMParams)
          <> "const d = new Decoder(" <> jsUint8 aliceE2EBytes <> ");"
          <> "const aliceV = d.anyByte() * 256 + d.anyByte();"
          <> "const alicePk1Raw = decodePubKeyX448(decodeBytes(d));"
          <> "const alicePk2Raw = decodePubKeyX448(decodeBytes(d));"
          -- Parse Maybe ARKEMParams: '1' + 'P' + KEMPublicKey(Large)
          <> "const maybeByte = d.anyByte();"
          <> "if (maybeByte !== 0x31) throw new Error('expected Just KEM');"
          <> "const kemTag = d.anyByte();"
          <> "if (kemTag !== 0x50) throw new Error('expected P (proposed), got ' + kemTag);"
          <> "const aliceKemPk = decodeLarge(d);"
          -- Bob generates DH keys
          <> "const b1 = generateX448KeyPair(), b2 = generateX448KeyPair();"
          <> "const b3 = generateX448KeyPair();"
          -- Bob encapsulates against alice's KEM public key
          <> "const kemEnc = sntrup761Enc(aliceKemPk);"
          -- Bob generates his own KEM keypair for future ratchet steps
          <> "const bobKem = sntrup761Keypair();"
          -- Construct kemAccepted matching Haskell RatchetKEMAccepted:
          -- rcPQRr = alice's KEM public key (received)
          -- rcPQRss = shared secret (from encapsulation)
          -- rcPQRct = ciphertext (sent to alice)
          <> "const kemAccepted = {rcPQRr: aliceKemPk, rcPQRss: kemEnc.sharedSecret, rcPQRct: kemEnc.ciphertext};"
          -- X3DH with kemAccepted (folds shared secret into HKDF AND stores in RatchetInitParams)
          <> "const bp = pqX3dhSnd(b1.privateKey, b2.privateKey, alicePk1Raw, alicePk2Raw, kemAccepted);"
          -- Init sending ratchet with bob's KEM keypair
          <> "let bob = initSndRatchet({current:3,maxSupported:3}, alicePk2Raw, b3.privateKey, bp, bobKem);"
          -- Encrypt
          <> "const enc = rcEncrypt(bob, new TextEncoder().encode('hello with PQ'), 100);"
          -- Build bob's E2E params: version + pk1 + pk2 + Just(Accepted(ct, bobKemPk))
          -- smpEncode ('A', ct, bobKemPk) where ct and pk are Large-encoded
          <> "const bobE2E = new Uint8Array(["
          <> "  ...encodeWord16(3),"
          <> "  ...encodeBytes(encodePubKeyX448(b1.publicKey)),"
          <> "  ...encodeBytes(encodePubKeyX448(b2.publicKey)),"
          <> "  0x31,"  -- Just
          <> "  0x41,"  -- 'A' = Accepted
          <> "  ...new Uint8Array([(kemEnc.ciphertext.length >> 8) & 0xff, kemEnc.ciphertext.length & 0xff]), ...kemEnc.ciphertext,"
          <> "  ...new Uint8Array([(bobKem.publicKey.length >> 8) & 0xff, bobKem.publicKey.length & 0xff]), ...bobKem.publicKey,"
          <> "]);"
          <> "const lenBuf = new Uint8Array(2); lenBuf[0] = (bobE2E.length >> 8) & 0xff; lenBuf[1] = bobE2E.length & 0xff;"
          <> "const ctLenBuf = new Uint8Array(2); ctLenBuf[0] = (enc.ciphertext.length >> 8) & 0xff; ctLenBuf[1] = enc.ciphertext.length & 0xff;"
          <> jsOut ("new Uint8Array([...lenBuf, ...bobE2E, ...ctLenBuf, ...enc.ciphertext])")
        let (e2eLenBs, rest1) = B.splitAt 2 tsOutput
            bobE2ELen = fromIntegral (B.index e2eLenBs 0) * 256 + fromIntegral (B.index e2eLenBs 1)
            (bobE2EBytes, rest2) = B.splitAt bobE2ELen rest1
            (ctLenBs, rest3) = B.splitAt 2 rest2
            ctLen = fromIntegral (B.index ctLenBs 0) * 256 + fromIntegral (B.index ctLenBs 1)
            ciphertext = B.take ctLen rest3

        -- Round 3: Haskell decodes bob's params (with KEM accepted), does X3DH with KEM, decrypts
        Right (CR.AE2ERatchetParams _ bobE2EParams :: CR.AE2ERatchetParams 'X448) <- pure $ smpDecode bobE2EBytes
        Right (aliceInitParams, aliceKemKp_) <- runExceptT $ CR.pqX3dhRcv alicePk1 alicePk2 alicePKem_ bobE2EParams
        let aliceRatchet = CR.initRcvRatchet (CR.RatchetVersions v v) alicePk2 (aliceInitParams, aliceKemKp_) CR.PQSupportOn
        gAlice <- C.newRandom
        result <- runExceptT $ CR.rcDecrypt gAlice aliceRatchet M.empty ciphertext
        case result of
          Right (msg, _, _) -> msg `shouldBe` Right "hello with PQ"
          Left e -> expectationFailure $ "rcDecrypt failed: " <> show e

      it "TypeScript PQ ratchet self-consistency: multi-message with KEM ratchet steps" $ do
        tsResult <- callNode $ impSodium <> impSntrup <> impRatchet
          <> "const a1 = generateX448KeyPair(), a2 = generateX448KeyPair();"
          <> "const b1 = generateX448KeyPair(), b2 = generateX448KeyPair();"
          <> "const b3 = generateX448KeyPair();"
          -- Alice proposes KEM
          <> "const aliceKem = sntrup761Keypair();"
          -- Bob accepts: encapsulate against alice's KEM public key
          <> "const kemEnc = sntrup761Enc(aliceKem.publicKey);"
          <> "const bobKem = sntrup761Keypair();"
          <> "const kemAccepted = {rcPQRr: aliceKem.publicKey, rcPQRss: kemEnc.sharedSecret, rcPQRct: kemEnc.ciphertext};"
          -- Alice receives bob's acceptance: decapsulate to get shared secret
          <> "const aliceSS = sntrup761Dec(kemEnc.ciphertext, aliceKem.secretKey);"
          <> "const aliceKemAccepted = {rcPQRr: bobKem.publicKey, rcPQRss: aliceSS, rcPQRct: kemEnc.ciphertext};"
          -- X3DH for both sides
          <> "const bp = pqX3dhSnd(b1.privateKey, b2.privateKey, a1.publicKey, a2.publicKey, kemAccepted);"
          <> "const ap = pqX3dhRcv(a1.privateKey, a2.privateKey, b1.publicKey, b2.publicKey, aliceKemAccepted);"
          -- Init ratchets with KEM keypairs
          <> "let bob = initSndRatchet({current:3,maxSupported:3}, a2.publicKey, b3.privateKey, bp, bobKem);"
          <> "let alice = initRcvRatchet({current:3,maxSupported:3}, a2.privateKey, ap, aliceKem, true);"
          <> "let sk = new Map();"
          -- Bob sends msg1 (has KEM params in header from initSndRatchet)
          <> "const e1 = rcEncrypt(bob, new TextEncoder().encode('pq msg1'), 100); bob = e1.state;"
          -- Alice decrypts msg1 (triggers ratchet advance with KEM)
          <> "let d1 = rcDecrypt(alice, sk, e1.ciphertext); alice = d1.state; sk = d1.skippedKeys;"
          -- Alice sends msg2 (ratchet advanced, has KEM params from pqRatchetStep)
          <> "const e2 = rcEncrypt(alice, new TextEncoder().encode('pq msg2'), 100); alice = e2.state;"
          -- Bob decrypts msg2 (triggers ratchet advance with KEM on bob's side)
          <> "let d2 = rcDecrypt(bob, new Map(), e2.ciphertext); bob = d2.state;"
          -- Bob sends msg3 (another ratchet advance with KEM)
          <> "const e3 = rcEncrypt(bob, new TextEncoder().encode('pq msg3'), 100); bob = e3.state;"
          -- Alice decrypts msg3
          <> "let d3 = rcDecrypt(alice, sk, e3.ciphertext); alice = d3.state; sk = d3.skippedKeys;"
          -- Verify all messages
          <> "const ok = new TextDecoder().decode(d1.plaintext) === 'pq msg1'"
          <> " && new TextDecoder().decode(d2.plaintext) === 'pq msg2'"
          <> " && new TextDecoder().decode(d3.plaintext) === 'pq msg3'"
          -- Verify KEM state is maintained
          <> " && alice.rcKEM !== null && bob.rcKEM !== null"
          <> " && alice.rcSndKEM === true && bob.rcSndKEM === true;"
          <> jsOut ("new Uint8Array([ok ? 1 : 0])")
        tsResult `shouldBe` B.singleton 1

    describe "DER encoding" $ do
      it "X448 DER round-trips" $ do
        tsResult <- callNode $ impRatchet
          <> "const kp = generateX448KeyPair();"
          <> "const der = encodePubKeyX448(kp.publicKey);"
          <> "const raw = decodePubKeyX448(der);"
          <> "const match = kp.publicKey.every((b, i) => b === raw[i]);"
          <> jsOut ("new Uint8Array([match ? 1 : 0, der.length, raw.length])")
        tsResult `shouldBe` B.pack [1, 68, 56]

  describe "crypto/blockEncryption" $ do
    describe "sbcInit + sbcHkdf" $ do
      it "TypeScript produces same sbKey/nonce via sbcInit+sbcHkdf as Haskell" $ do
        let sessId = B.pack [1..32]
            secret = B.pack [50..81]
            (sndCk, _rcvCk) = C.sbcInit sessId secret
            ((C.SbKey sbKey, C.CbNonce nonce), _nextCk) = C.sbcHkdf sndCk
        -- TypeScript does sbcInit then sbcHkdf on sndKey, should produce same sbKey/nonce
        tsResult <- callNode $ impSodium <> impCrypto
          <> "const ck = sbcInit(" <> jsUint8 sessId <> "," <> jsUint8 secret <> ");"
          <> "const r = sbcHkdf(ck.sndKey);"
          <> jsOut ("new Uint8Array([...r.keyNonce.sbKey, ...r.keyNonce.nonce])")
        tsResult `shouldBe` (sbKey <> nonce)

    describe "block encrypt/decrypt" $ do
      it "Haskell encrypts, TypeScript decrypts" $ do
        let sessId = B.pack [1..32]
            secret = B.pack [1..32]
            (sndCk, _) = C.sbcInit sessId secret
            msg = "hello encrypted block"
            ((sk, nonce), _nextCk) = C.sbcHkdf sndCk
        case C.sbEncrypt sk nonce msg (smpBlockSize - 16) of
          Left e -> expectationFailure $ "encrypt failed: " <> show e
          Right ct -> do
            tsResult <- callNode $ impSodium <> impCrypto
              <> "const ck = sbcInit(" <> jsUint8 sessId <> "," <> jsUint8 secret <> ");"
              <> "const r = sbDecryptBlock(ck.sndKey," <> jsUint8 ct <> ");"
              <> jsOut ("r.decrypted")
            tsResult `shouldBe` msg

      it "TypeScript encrypts, Haskell decrypts" $ do
        let sessId = B.pack [10..41]
            secret = B.pack [10..41]
            (sndCk, _) = C.sbcInit sessId secret
            msg = "hello from typescript"
        tsResult <- callNode $ impSodium <> impCrypto
          <> "const ck = sbcInit(" <> jsUint8 sessId <> "," <> jsUint8 secret <> ");"
          <> jsOut ("sbEncryptBlock(ck.sndKey, new TextEncoder().encode('hello from typescript'), " <> show (smpBlockSize - 16) <> ").encrypted")
        let ((sk, nonce), _nextCk) = C.sbcHkdf sndCk
        case C.sbDecrypt sk nonce tsResult of
          Left e -> expectationFailure $ "decrypt failed: " <> show e
          Right plain -> plain `shouldBe` msg

  describe "agent/protocol" $ do
    describe "ProtocolServer binary" $ do
      it "decodes Haskell-encoded server" $ do
        let srv = SMPServer ("smp.example.com" :| ["smp2.example.com"]) "5223" (C.KeyHash $ B.pack [1..32])
            encoded = smpEncode srv
        tsResult <- callNode $ impAgentProto
          <> "const s = decodeProtocolServer(new Decoder(" <> jsUint8 encoded <> "));"
          <> "const enc = new TextEncoder();"
          <> jsOut ("new Uint8Array([s.hosts.length, ...s.keyHash, ...enc.encode(new TextDecoder().decode(s.port))])")
        tsResult `shouldBe` B.pack ([2] ++ [1..32]) <> "5223"

    describe "ConnShortLink binary" $ do
      it "decodes Haskell-encoded contact link" $ do
        let srv = SMPServer ("relay.example.com" :| []) "" (C.KeyHash $ B.pack [1..32])
            linkKey = AP.LinkKey $ B.pack [50..81]
            link = AP.CSLContact AP.SLSServer AP.CCTGroup srv linkKey
            encoded = smpEncode link
        tsResult <- callNode $ impAgentProto
          <> "const l = decodeConnShortLink(new Decoder(" <> jsUint8 encoded <> "));"
          <> jsOut ("new Uint8Array([l.mode === 'contact' ? 1 : 0, l.connType === 'group' ? 1 : 0, ...l.linkKey])")
        tsResult `shouldBe` B.pack ([1, 1] ++ [50..81])

    describe "ConnLinkData" $ do
      it "decodes Haskell-encoded ContactLinkData with profile" $ do
        let profileJson = "{\"displayName\":\"alice\",\"fullName\":\"Alice A\"}"
            userData = AP.UserLinkData profileJson
            ucd = AP.UserContactData {AP.direct = True, AP.owners = [], AP.relays = [], AP.userData = userData}
            cld = AP.ContactLinkData (mkVersionRange (Version 1) (Version 3)) ucd :: AP.ConnLinkData 'AP.CMContact
            encoded = smpEncode cld
        tsResult <- callNode $ impAgentProto
          <> "const r = decodeConnLinkData(new Decoder(" <> jsUint8 encoded <> "));"
          <> "const p = parseProfile(r.userContactData.userData);"
          <> "const enc = new TextEncoder();"
          <> jsOut ("new Uint8Array(["
          <> "r.agentVRange.min >> 8, r.agentVRange.min & 0xff,"
          <> "r.agentVRange.max >> 8, r.agentVRange.max & 0xff,"
          <> "r.userContactData.direct ? 1 : 0,"
          <> "r.userContactData.owners.length,"
          <> "r.userContactData.relays.length,"
          <> "...enc.encode(p.displayName)"
          <> "])")
        tsResult `shouldBe` B.pack [0, 1, 0, 3, 1, 0, 0] <> "alice"

    describe "ConnShortLink URI" $ do
      it "parses simplex: contact link" $ do
        let srv = SMPServer ("smp1.example.com" :| []) "" (C.KeyHash $ B.pack [1..32])
            linkKey = AP.LinkKey $ B.pack [100..131]
            link = AP.CSLContact AP.SLSSimplex AP.CCTContact srv linkKey
            uri = strEncode link
        tsResult <- callNode $ impAgentProto
          <> "const r = connShortLinkStrP(" <> jsStr uri <> ");"
          <> jsOut ("new Uint8Array([...r.linkKey, ...r.server.keyHash])")
        tsResult `shouldBe` (B.pack [100..131] <> B.pack [1..32])

      it "parses https: contact link with port" $ do
        let srv = SMPServer ("smp2.example.com" :| []) "5223" (C.KeyHash $ B.pack [50..81])
            linkKey = AP.LinkKey $ B.pack [200..231]
            link = AP.CSLContact AP.SLSServer AP.CCTContact srv linkKey
            uri = strEncode link
        tsResult <- callNode $ impAgentProto
          <> "const r = connShortLinkStrP(" <> jsStr uri <> ");"
          <> "const enc = new TextEncoder();"
          <> jsOut ("new Uint8Array([...r.linkKey, ...r.server.keyHash, ...enc.encode(r.server.port), 0, ...enc.encode(r.server.hosts.join(','))])")
        let expected = B.pack [200..231] <> B.pack [50..81] <> "5223" <> B.singleton 0 <> "smp2.example.com"
        tsResult `shouldBe` expected

      it "parses simplex: contact link with multiple hosts" $ do
        let srv = SMPServer ("host1.example.com" :| ["host2.example.com"]) "" (C.KeyHash $ B.pack [1..32])
            linkKey = AP.LinkKey $ B.pack [10..41]
            link = AP.CSLContact AP.SLSSimplex AP.CCTContact srv linkKey
            uri = strEncode link
        tsResult <- callNode $ impAgentProto
          <> "const r = connShortLinkStrP(" <> jsStr uri <> ");"
          <> "const enc = new TextEncoder();"
          <> jsOut ("new Uint8Array([...r.linkKey, ...enc.encode(r.server.hosts.join(','))])")
        tsResult `shouldBe` (B.pack [10..41] <> "host1.example.com,host2.example.com")

      it "parses group link type" $ do
        let srv = SMPServer ("smp.example.com" :| []) "" (C.KeyHash $ B.pack [1..32])
            linkKey = AP.LinkKey $ B.pack [10..41]
            link = AP.CSLContact AP.SLSSimplex AP.CCTGroup srv linkKey
            uri = strEncode link
        tsResult <- callNode $ impAgentProto
          <> "const r = connShortLinkStrP(" <> jsStr uri <> ");"
          <> "const enc = new TextEncoder();"
          <> jsOut ("enc.encode(r.connType)")
        tsResult `shouldBe` "group"

      it "round-trips: Haskell encode -> TypeScript parse -> fields match" $ do
        let srv = SMPServer ("server1.simplex.im" :| ["server2.simplex.im"]) "443" (C.KeyHash $ B.pack [1..32])
            linkKey = AP.LinkKey $ B.pack [200..231]
            link = AP.CSLContact AP.SLSServer AP.CCTContact srv linkKey
            uri = strEncode link
        -- TypeScript returns: mode, scheme, connType, host count, port, linkKey
        tsResult <- callNode $ impAgentProto
          <> "const r = connShortLinkStrP(" <> jsStr uri <> ");"
          <> "const enc = new TextEncoder();"
          <> jsOut ("new Uint8Array(["
          <> "r.mode === 'contact' ? 1 : 0,"
          <> "r.scheme === 'https' ? 1 : 0,"
          <> "r.connType === 'contact' ? 1 : 0,"
          <> "r.server.hosts.length,"
          <> "...r.linkKey"
          <> "])")
        tsResult `shouldBe` B.pack ([1, 1, 1, 2] ++ [200..231])

    describe "WebSocket handshake" $ do
      it "TypeScript connects with block encryption, verifies identity, sends encrypted PING" $ do
        let msType = ASType SQSMemory SMSJournal
        attachStaticAndWS "tests/fixtures" $ \attachHTTP ->
          withSmpServerConfig (cfgWebOn msType testPort) (Just attachHTTP) $ \_ -> do
            let C.KeyHash kh = testKeyHash
            tsResult <- callNode $ impSodium <> impWS <> impProto
              <> "import { sendEncryptedBlock, receiveEncryptedBlock } from './dist/transport/websockets.js';"
              <> "try {"
              <> "const conn = await connectSMP('wss://localhost:" <> testPort <> "', " <> jsUint8 kh <> ", {rejectUnauthorized: false, ALPNProtocols: ['http/1.1']});"
              <> "if (!conn.sndKey || !conn.rcvKey) throw new Error('no block encryption keys');"
              <> "const ping = encodeBatch(encodeTransmission(new Uint8Array([0x31]), new Uint8Array(0), new Uint8Array([0x50,0x49,0x4E,0x47])));"
              <> "sendEncryptedBlock(conn, ping);"
              <> "const resp = await receiveEncryptedBlock(conn);"
              <> "const d = new Decoder(resp);"
              <> "d.anyByte();"  -- batch count
              <> "const inner = decodeLarge(d);"
              <> "const t = decodeTransmission(new Decoder(inner));"
              <> jsOut ("t.command")
              <> "conn.ws.close(); setTimeout(() => process.exit(0), 100);"
              <> "} catch(e) { process.stderr.write('ERROR: ' + e.message + '\\n'); process.exit(1); }"
            tsResult `shouldBe` "PONG"

  describe "end-to-end" $ do
    it "TypeScript fetches short link data via WebSocket" $ do
      let msType = ASType SQSMemory SMSJournal
      attachStaticAndWS "tests/fixtures" $ \attachHTTP ->
        withSmpServerConfig (cfgWebOn msType testPort) (Just attachHTTP) $ \_serverThread ->
          withAgent 1 agentCfg initAgentServers testDB $ \a -> do
            let testData = "hello from short link"
                userData = UserLinkData testData
                userCtData = UserContactData {direct = True, owners = [], relays = [], userData = userData}
                newLinkData = UserContactLinkData userCtData
            (_connId, (CCLink _connReq (Just shortLink), Nothing)) <-
              runRight $ A.createConnection a NRMInteractive 1 True True AP.SCMContact (Just newLinkData) Nothing CR.IKPQOn SMSubscribe
            let linkUri = strEncode shortLink
            tsResult <- callNode $ impSodium <> impWS <> impAgentProto <> impProto_ <> impCryptoShortLink
              <> "import { sendEncryptedBlock, receiveEncryptedBlock } from './dist/transport/websockets.js';"
              <> "try {"
              -- 1. Parse short link URI
              <> "const link = connShortLinkStrP(" <> jsStr linkUri <> ");"
              -- 2. Derive keys
              <> "const {linkId, sbKey} = contactShortLinkKdf(link.linkKey);"
              -- 3. Connect via WSS (with block encryption)
              <> "const conn = await connectSMP('wss://localhost:" <> testPort <> "', " <> jsUint8 (C.unKeyHash testKeyHash) <> ", {rejectUnauthorized: false, ALPNProtocols: ['http/1.1']});"
              -- 4. Send LGET (encrypted)
              <> "const lget = encodeBatch(encodeTransmission(new Uint8Array([0x31]), linkId, encodeLGET()));"
              <> "sendEncryptedBlock(conn, lget);"
              -- 5. Receive LNK response (encrypted)
              <> "const resp = await receiveEncryptedBlock(conn);"
              <> "const rd = new Decoder(resp);"
              <> "rd.anyByte();"  -- batch count
              <> "const inner = decodeLarge(rd);"
              <> "const t = decodeTransmission(new Decoder(inner));"
              <> "const r = decodeResponse(new Decoder(t.command));"
              <> "if (r.type !== 'LNK') throw new Error('expected LNK, got ' + r.type);"
              -- 6. Decrypt link data
              <> "const dec = decryptLinkData(sbKey, r.response.encFixedData, r.response.encUserData);"
              -- 7. Parse FixedLinkData (rootKey) and ConnLinkData (userData)
              <> "const fld = decodeFixedLinkData(new Decoder(dec.fixedData));"
              <> "const cld = decodeConnLinkData(new Decoder(dec.userData));"
              -- Return rootKey length (44 = valid DER Ed25519) + userData
              <> jsOut ("new Uint8Array([fld.rootKey.length, ...cld.userContactData.userData])")
              <> "conn.ws.close(); setTimeout(() => process.exit(0), 100);"
              <> "} catch(e) { process.stderr.write('ERROR: ' + e.message + '\\n'); process.exit(1); }"
            -- First byte: rootKey DER length (44 for Ed25519), rest: userData
            B.head tsResult `shouldBe` 44
            B.tail tsResult `shouldBe` testData
