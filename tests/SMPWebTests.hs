{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

-- | Per-function tests for the smp-web TypeScript SMP client library.
-- Each test calls the Haskell function and the corresponding TypeScript function
-- via node, then asserts byte-identical output.
--
-- Prerequisites: cd smp-web && npm install && npm run build
-- Run: cabal test --test-option=--match="/SMP Web Client/"
module SMPWebTests (smpWebTests) where

import qualified Data.ByteString as B
import Data.Word (Word16)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding
import Simplex.Messaging.Server.Env.STM (AStoreType (..))
import Simplex.Messaging.Server.MsgStore.Types (SMSType (..), SQSType (..))
import Simplex.Messaging.Server.Web (attachStaticAndWS)
import Simplex.Messaging.Transport (TLS)
import SMPClient (cfgWebOn, testKeyHash, testPort, withSmpServerConfig)
import Test.Hspec hiding (it)
import Util
import XFTPWebTests (callNode_, jsOut, jsUint8)

smpWebDir :: FilePath
smpWebDir = "smp-web"

callNode :: String -> IO B.ByteString
callNode = callNode_ smpWebDir

impProto :: String
impProto = "import { encodeTransmission, encodeBatch, decodeTransmission, encodeLGET, decodeLNK, decodeResponse } from './dist/protocol.js';"
  <> "import { Decoder } from '@simplex-chat/xftp-web/dist/protocol/encoding.js';"

impTransport :: String
impTransport = "import { decodeSMPServerHandshake, encodeSMPClientHandshake } from './dist/transport.js';"
  <> "import { Decoder, encodeWord16 } from '@simplex-chat/xftp-web/dist/protocol/encoding.js';"

impWS :: String
impWS = "import { connectSMP, sendBlock, receiveBlock } from './dist/transport/websockets.js';"
  <> "import { blockPad, blockUnpad } from '@simplex-chat/xftp-web/dist/protocol/transmission.js';"

smpWebTests :: SpecWith ()
smpWebTests = describe "SMP Web Client" $ do
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

    describe "WebSocket handshake" $ do
      it "TypeScript connects and completes SMP handshake" $ do
        let msType = ASType SQSMemory SMSJournal
        attachStaticAndWS "tests/fixtures" $ \attachHTTP ->
          withSmpServerConfig (cfgWebOn msType testPort) (Just attachHTTP) $ \_ -> do
            let C.KeyHash kh = testKeyHash
            tsResult <- callNode $ impWS <> impProto
              <> "try {"
              <> "const conn = await connectSMP('wss://localhost:" <> testPort <> "', " <> jsUint8 kh <> ", {rejectUnauthorized: false, ALPNProtocols: ['http/1.1']});"
              <> "const ping = encodeTransmission(new Uint8Array([0x31]), new Uint8Array(0), new Uint8Array([0x50,0x49,0x4E,0x47]));"
              <> "sendBlock(conn.ws, blockPad(encodeBatch(ping), 16384));"
              <> "const {decodeLarge} = await import('@simplex-chat/xftp-web/dist/protocol/encoding.js');"
              <> "const resp = await receiveBlock(conn.ws);"
              <> "const d = new Decoder(blockUnpad(resp));"
              <> "d.anyByte();"  -- batch count
              <> "const inner = decodeLarge(d);"
              <> "const t = decodeTransmission(new Decoder(inner));"
              <> jsOut ("t.command")
              <> "conn.ws.close(); setTimeout(() => process.exit(0), 100);"
              <> "} catch(e) { process.stderr.write('ERROR: ' + e.message + '\\n'); process.exit(1); }"
            tsResult `shouldBe` "PONG"
