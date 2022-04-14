{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module NtfServerTests where

import Data.ByteString.Char8 (ByteString)
import NtfClient
import ServerTests (sampleDhPubKey, samplePubKey, sampleSig)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding
import Simplex.Messaging.Notifications.Protocol
import Simplex.Messaging.Protocol
import Simplex.Messaging.Transport
import Test.Hspec

ntfServerTests :: ATransport -> Spec
ntfServerTests t = do
  describe "notifications server protocol syntax" $ ntfSyntaxTests t

ntfSyntaxTests :: ATransport -> Spec
ntfSyntaxTests (ATransport t) = do
  it "unknown command" $ ("", "abcd", "1234", ('H', 'E', 'L', 'L', 'O')) >#> ("", "abcd", "1234", ERR $ CMD UNKNOWN)
  describe "NEW" $ do
    it "no parameters" $ (sampleSig, "bcda", "", TNEW_) >#> ("", "bcda", "", ERR $ CMD SYNTAX)
    it "many parameters" $ (sampleSig, "cdab", "", (TNEW_, (' ', '\x01', 'A'), ('T', 'A', "abcd" :: ByteString), samplePubKey, sampleDhPubKey)) >#> ("", "cdab", "", ERR $ CMD SYNTAX)
    it "no signature" $ ("", "dabc", "", (TNEW_, ' ', ('T', 'A', "abcd" :: ByteString), samplePubKey, sampleDhPubKey)) >#> ("", "dabc", "", ERR $ CMD NO_AUTH)
    it "token ID" $ (sampleSig, "abcd", "12345678", (TNEW_, ' ', ('T', 'A', "abcd" :: ByteString), samplePubKey, sampleDhPubKey)) >#> ("", "abcd", "12345678", ERR $ CMD HAS_AUTH)
  where
    (>#>) ::
      Encoding smp =>
      (Maybe C.ASignature, ByteString, ByteString, smp) ->
      (Maybe C.ASignature, ByteString, ByteString, BrokerMsg) ->
      Expectation
    command >#> response = ntfServerTest t command `shouldReturn` response
