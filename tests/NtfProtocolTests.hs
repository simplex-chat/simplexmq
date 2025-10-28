{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE DataKinds #-}

module NtfProtocolTests where

import Test.Hspec hiding (fit, it)
import Util
import Simplex.Messaging.Encoding.String (StrEncoding(..))
import qualified Data.ByteString as B
import qualified Crypto.PubKey.ECC.Types as ECC
import Simplex.Messaging.Notifications.Protocol
import Simplex.Messaging.Notifications.Server.Push.WebPush (wpEncrypt')
import Control.Monad.Except (runExceptT)
import qualified Data.ByteString.Lazy as BL

ntfProtocolTests :: Spec
ntfProtocolTests = describe "NTF Protocol" $ do
  it "decode WPDeviceToken from string" testWPDeviceTokenStrEncoding
  it "Encrypt RFC8291 example" testWPEncryption

testWPDeviceTokenStrEncoding :: Expectation
testWPDeviceTokenStrEncoding = do
  let ts = "webpush https://localhost/secret AQ3VfRX3_F38J3ltcmMVRg BKuw4WxupnnrZHqk6vCwoms4tOpitZMvFdR9eAn54yOPY4q9jpXOpl-Ui_FwbIy8ZbFCnuaS7RnO02ahuL4XxIM"
  -- let ts = "apns_null test_ntf_token"
  -- let ts = "apns_test 11111111222222223333333344444444"

  let auth = either error id $ strDecode "AQ3VfRX3_F38J3ltcmMVRg"
  let pk = either error id $ strDecode "BKuw4WxupnnrZHqk6vCwoms4tOpitZMvFdR9eAn54yOPY4q9jpXOpl-Ui_FwbIy8ZbFCnuaS7RnO02ahuL4XxIM"
  let params ::WPTokenParams = either error id $ strDecode "/secret AQ3VfRX3_F38J3ltcmMVRg BKuw4WxupnnrZHqk6vCwoms4tOpitZMvFdR9eAn54yOPY4q9jpXOpl-Ui_FwbIy8ZbFCnuaS7RnO02ahuL4XxIM"
  wpPath params `shouldBe` "/secret"
  let key = wpKey params
  wpAuth key `shouldBe` auth
  wpP256dh key `shouldBe` pk

  let pp@(WPP s) :: WPProvider = either error id $ strDecode "webpush https://localhost"

  let parsed = either error id $ strDecode ts
  parsed `shouldBe` WPDeviceToken pp params
  -- TODO: strEncoding should be base64url _without padding_
  -- strEncode parsed `shouldBe` ts

  strEncode s <> wpPath params `shouldBe` "https://localhost/secret"

-- | Example from RFC8291
testWPEncryption :: Expectation
testWPEncryption = do
  let clearT :: B.ByteString = "When I grow up, I want to be a watermelon"
  let pParams :: WPTokenParams = either error id $ strDecode "/push/JzLQ3raZJfFBR0aqvOMsLrt54w4rJUsV BTBZMqHH6r4Tts7J_aSIgg BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4"
  let salt :: B.ByteString = either error id $ strDecode "DGv6ra1nlYgDCS1FRnbzlw"
  let privBS :: BL.ByteString = either error BL.fromStrict $ strDecode "yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw"
  asPriv :: ECC.PrivateNumber <- case uncompressDecodePrivateNumber privBS of
    Left e -> fail $ "Cannot decode PrivateNumber from b64 " <> show e
    Right p -> pure p
  mCip <- runExceptT $ wpEncrypt' (wpKey pParams) asPriv salt clearT
  cipher <- case mCip of
    Left _ -> fail "Cannot encrypt clear text"
    Right c -> pure c
  strEncode cipher `shouldBe` "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPTpK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN"
