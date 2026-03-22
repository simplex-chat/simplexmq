{-# LANGUAGE OverloadedStrings #-}

-- | Per-function tests for the smp-web TypeScript SMP client library.
-- Each test calls the Haskell function and the corresponding TypeScript function
-- via node, then asserts byte-identical output.
--
-- Prerequisites: cd smp-web && npm install && npm run build
-- Run: cabal test --test-option=--match="/SMP Web Client/"
module SMPWebTests (smpWebTests) where

import qualified Data.ByteString as B
import Simplex.Messaging.Encoding
import Test.Hspec hiding (it)
import Util
import XFTPWebTests (callNode_, jsOut, jsUint8)

smpWebDir :: FilePath
smpWebDir = "smp-web"

callNode :: String -> IO B.ByteString
callNode = callNode_ smpWebDir

impProto :: String
impProto = "import { encodeTransmission, decodeTransmission, encodeLGET, decodeLNK, decodeResponse } from './dist/protocol.js';"
  <> "import { Decoder } from '@simplex-chat/xftp-web/dist/protocol/encoding.js';"

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
          <> "new Uint8Array([0x4C,0x47,0x45,0x54])" -- "LGET"
          <> ")")
        -- TS encodes with empty auth prefix, HS encodeTransmission_ doesn't include auth
        -- So TS output = [0x00] ++ hsEncoded
        tsEncoded `shouldBe` (B.singleton 0 <> hsEncoded)

      it "decodeTransmission parses Haskell-encoded" $ do
        let corrId = "abc"
            entityId = B.pack [10..33]
            command = "TEST"
            encoded = smpEncode (B.empty :: B.ByteString) -- empty auth
              <> smpEncode corrId
              <> smpEncode entityId
              <> command
        -- TS decodes and returns corrId ++ entityId ++ command concatenated with length prefixes
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
          <> "const r = decodeResponse(new Decoder(new Uint8Array([0x4F, 0x4B])));"  -- "OK"
          <> jsOut ("new Uint8Array([r.type === 'OK' ? 1 : 0])")
        tsResult `shouldBe` B.singleton 1
