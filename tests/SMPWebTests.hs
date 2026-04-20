{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE TypeApplications #-}

-- | Per-function tests for the smp-web TypeScript SMP client library.
-- Each test calls the Haskell function and the corresponding TypeScript function
-- via node, then asserts byte-identical output.
--
-- Prerequisites: cd smp-web && npm install && npm run build
-- Run: cabal test --test-option=--match="/SMP Web Client/"
module SMPWebTests (smpWebTests) where

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
import qualified Simplex.Messaging.Crypto.Ratchet as CR
import Simplex.Messaging.Crypto.ShortLink (contactShortLinkKdf, invShortLinkKdf)
import Simplex.Messaging.Encoding
import Simplex.Messaging.Encoding.String (strEncode)
import Simplex.Messaging.Protocol (EntityId (..), SMPServer, SubscriptionMode (..), pattern SMPServer)
import Simplex.Messaging.Server.Env.STM (AStoreType (..))
import Simplex.Messaging.Server.MsgStore.Types (SMSType (..), SQSType (..))
import Simplex.Messaging.Server.Web (attachStaticAndWS)
import Simplex.Messaging.Transport (TLS, smpBlockSize)
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
impEnc = "import { Decoder, decodeLarge } from '@simplex-chat/xftp-web/dist/protocol/encoding.js';"

impProto_ :: String
impProto_ = "import { encodeTransmission, encodeBatch, decodeTransmission, encodeLGET, decodeLNK, decodeResponse } from './dist/protocol.js';"

impProto :: String
impProto = impEnc <> impProto_

impTransport :: String
impTransport = "import { decodeSMPServerHandshake, encodeSMPClientHandshake } from './dist/transport.js';"
  <> "import { Decoder, encodeWord16 } from '@simplex-chat/xftp-web/dist/protocol/encoding.js';"

impWS :: String
impWS = "import { connectSMP, sendBlock, receiveBlock } from './dist/transport/websockets.js';"
  <> "import { blockPad, blockUnpad } from '@simplex-chat/xftp-web/dist/protocol/transmission.js';"

impAgentProto_ :: String
impAgentProto_ = "import { connShortLinkStrP, decodeConnLinkData, decodeProtocolServer, decodeConnShortLink, decodeOwnerAuth, decodeUserLinkData, parseProfile } from './dist/agent/protocol.js';"

impAgentProto :: String
impAgentProto = impEnc <> impAgentProto_

impCryptoShortLink :: String
impCryptoShortLink = "import { contactShortLinkKdf, invShortLinkKdf, decryptLinkData } from './dist/crypto/shortLink.js';"

impCrypto :: String
impCrypto = "import { sbcInit, sbcHkdf, sbEncryptBlock, sbDecryptBlock } from './dist/crypto.js';"

-- Init sodium from xftp-web's copy (same instance secretbox.ts uses)
impSodium :: String
impSodium = "import sodium from '@simplex-chat/xftp-web/node_modules/libsodium-wrappers-sumo/dist/modules-sumo/libsodium-wrappers.js'; await sodium.ready;"

jsStr :: B.ByteString -> String
jsStr bs = "'" <> BC.unpack bs <> "'"

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
              -- 7. Parse ConnLinkData to get UserLinkData
              <> "const cld = decodeConnLinkData(new Decoder(dec.userData));"
              <> jsOut ("cld.userContactData.userData")
              <> "conn.ws.close(); setTimeout(() => process.exit(0), 100);"
              <> "} catch(e) { process.stderr.write('ERROR: ' + e.message + '\\n'); process.exit(1); }"
            tsResult `shouldBe` testData
