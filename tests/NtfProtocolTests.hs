{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE DataKinds #-}

module NtfProtocolTests where

import Test.Hspec hiding (fit, it)
import Util
import Simplex.Messaging.Encoding.String (StrEncoding(..))
import Simplex.Messaging.Notifications.Protocol
    ( DeviceToken(WPDeviceToken),
      WPTokenParams(..),
      WPKey(..),
      WPProvider(WPP) )
import Simplex.Messaging.Protocol (ProtocolServer, ProtocolType(..))

ntfProtocolTests :: Spec
ntfProtocolTests = describe "NTF Protocol" $ do
  it "decode WPDeviceToken from string" testWPDeviceTokenStrEncoding

testWPDeviceTokenStrEncoding :: Expectation
testWPDeviceTokenStrEncoding = do
  -- TODO: Web Push endpoint should not require a keyHash
  -- let ts = "webpush https://localhost/secret AQ3VfRX3_F38J3ltcmMVRg BKuw4WxupnnrZHqk6vCwoms4tOpitZMvFdR9eAn54yOPY4q9jpXOpl-Ui_FwbIy8ZbFCnuaS7RnO02ahuL4XxIM"
  let ts = "webpush https://AAAA@localhost:8000/secret AQ3VfRX3_F38J3ltcmMVRg BKuw4WxupnnrZHqk6vCwoms4tOpitZMvFdR9eAn54yOPY4q9jpXOpl-Ui_FwbIy8ZbFCnuaS7RnO02ahuL4XxIM"
  -- let ts = "apns_null test_ntf_token"
  -- let ts = "apns_test 11111111222222223333333344444444"

  let auth = either error id $ strDecode "AQ3VfRX3_F38J3ltcmMVRg"
  let pk = either error id $ strDecode "BKuw4WxupnnrZHqk6vCwoms4tOpitZMvFdR9eAn54yOPY4q9jpXOpl-Ui_FwbIy8ZbFCnuaS7RnO02ahuL4XxIM"
  let params ::WPTokenParams = either error id $ strDecode "/secret AQ3VfRX3_F38J3ltcmMVRg BKuw4WxupnnrZHqk6vCwoms4tOpitZMvFdR9eAn54yOPY4q9jpXOpl-Ui_FwbIy8ZbFCnuaS7RnO02ahuL4XxIM"
  wpPath params `shouldBe` "/secret"
  let key = wpKey params
  wpAuth key `shouldBe` auth
  wpP256dh key `shouldBe` pk

  let pp@(WPP s) :: WPProvider = either error id $ strDecode "webpush https://AAAA@localhost:8000"

  let parsed = either error id $ strDecode ts
  parsed `shouldBe` WPDeviceToken pp params
  -- TODO: strEncoding should be base64url _without padding_
  -- strEncode parsed `shouldBe` ts

  strEncode s <> wpPath params `shouldBe` "https://AAAA@localhost:8000/secret"
