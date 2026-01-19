{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module NtfWPTests where

import Control.Monad (unless)
import Control.Monad.Except (runExceptT)
import qualified Crypto.PubKey.ECC.Types as ECC
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Data.Either (isLeft)
import Data.IORef (newIORef)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding.String (StrEncoding (..))
import Simplex.Messaging.Notifications.Protocol
import Simplex.Messaging.Notifications.Server.Main (getVapidKey)
import Simplex.Messaging.Notifications.Server.Push.WebPush (getVapidHeader', wpEncrypt')
import Test.Hspec hiding (fit, it)
import Util

ntfWPTests :: Spec
ntfWPTests = describe "NTF Protocol" $ do
  it "decode WPDeviceToken from string" testWPDeviceTokenStrEncoding
  it "decode invalid WPDeviceToken" testInvalidWPDeviceTokenStrEncoding
  it "Encrypt RFC8291 example" testWPEncryption
  it "Vapid header cache" testVapidCache

testWPDeviceTokenStrEncoding :: Expectation
testWPDeviceTokenStrEncoding = do
  let ts = "webpush https://localhost/secret AQ3VfRX3_F38J3ltcmMVRg BKuw4WxupnnrZHqk6vCwoms4tOpitZMvFdR9eAn54yOPY4q9jpXOpl-Ui_FwbIy8ZbFCnuaS7RnO02ahuL4XxIM"
  -- let ts = "apns_null test_ntf_token"
  -- let ts = "apns_test 11111111222222223333333344444444"

  let auth = either error id $ strDecode "AQ3VfRX3_F38J3ltcmMVRg"
  let pk = either error id $ strDecode "BKuw4WxupnnrZHqk6vCwoms4tOpitZMvFdR9eAn54yOPY4q9jpXOpl-Ui_FwbIy8ZbFCnuaS7RnO02ahuL4XxIM"
  let params :: WPTokenParams = either error id $ strDecode "/secret AQ3VfRX3_F38J3ltcmMVRg BKuw4WxupnnrZHqk6vCwoms4tOpitZMvFdR9eAn54yOPY4q9jpXOpl-Ui_FwbIy8ZbFCnuaS7RnO02ahuL4XxIM"
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

testInvalidWPDeviceTokenStrEncoding :: Expectation
testInvalidWPDeviceTokenStrEncoding = do
  -- http-client parser parseUrlThrow is very very lax,
  -- e.g "https://#1" is a valid URL. But that is the same parser
  -- we use to send the requests, so that's fine.
  let ts = "webpush https://localhost:/ AQ3VfRX3_F38J3ltcmMVRg BKuw4WxupnnrZHqk6vCwoms4tOpitZMvFdR9eAn54yOPY4q9jpXOpl-Ui_FwbIy8ZbFCnuaS7RnO02ahuL4XxIM"
      t = strDecode ts :: Either String DeviceToken
  t `shouldSatisfy` isLeft

-- | Example from RFC8291
testWPEncryption :: Expectation
testWPEncryption = do
  let clearT :: ByteString = "When I grow up, I want to be a watermelon"
      pParams :: WPTokenParams = either error id $ strDecode "/push/JzLQ3raZJfFBR0aqvOMsLrt54w4rJUsV BTBZMqHH6r4Tts7J_aSIgg BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4"
      salt :: ByteString = either error id $ strDecode "DGv6ra1nlYgDCS1FRnbzlw"
      privBS :: ByteString = either error id $ strDecode "yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw"
  asPriv :: ECC.PrivateNumber <- case C.uncompressDecodePrivateNumber privBS of
    Left e -> fail $ "Cannot decode PrivateNumber from b64 " <> show e
    Right p -> pure p
  mCip <- runExceptT $ wpEncrypt' (wpKey pParams) asPriv salt clearT
  cipher <- case mCip of
    Left _ -> fail "Cannot encrypt clear text"
    Right c -> pure c
  strEncode cipher `shouldBe` "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPTpK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN"

testVapidCache :: Expectation
testVapidCache = do
  let wpaud = "https://localhost"
  let now = 1761900906
  cache <- newIORef Nothing
  vapidKey <- getVapidKey "tests/fixtures/vapid.privkey"
  v1 <- getVapidHeader' now vapidKey cache wpaud
  v2 <- getVapidHeader' now vapidKey cache wpaud
  v1 `shouldBe` v2
  -- we just don't test the signature here
  v1 `shouldContainBS` "vapid t=eyJ0eXAiOiJKV1QiLCJhbGciOiJFUzI1NiJ9.eyJleHAiOjE3NjE5MDQ1MDYsImF1ZCI6Imh0dHBzOi8vbG9jYWxob3N0Iiwic3ViIjoiaHR0cHM6Ly9naXRodWIuY29tL3NpbXBsZXgtY2hhdC9zaW1wbGV4bXEvIn0."
  v1 `shouldContainBS` ",k=BIk7ASkEr1A1rJRGXMKi77tAGj3dRouSgZdW6S5pee7a3h7fkvd0OYQixy4yj35UFZt8hd9TwAQiybDK_HJLwJA"
  v3 <- getVapidHeader' (now + 3600) vapidKey cache wpaud
  v1 `shouldNotBe` v3
  v3 `shouldContainBS` "vapid t=eyJ0eXAiOiJKV1QiLCJhbGciOiJFUzI1NiJ9."
  v3 `shouldContainBS` ",k=BIk7ASkEr1A1rJRGXMKi77tAGj3dRouSgZdW6S5pee7a3h7fkvd0OYQixy4yj35UFZt8hd9TwAQiybDK_HJLwJA"

shouldContainBS :: ByteString -> ByteString -> Expectation
shouldContainBS actual expected =
  unless (expected `B.isInfixOf` actual) $
    expectationFailure $
      "Expected ByteString to contain:\n"
        ++ show expected
        ++ "\nBut got:\n"
        ++ show actual
