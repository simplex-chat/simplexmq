{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}

{-# HLINT ignore "Use newtype instead of data" #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE TypeApplications #-}

module Simplex.Messaging.Notifications.Server.Push.WebPush where

import Network.HTTP.Client
import Simplex.Messaging.Notifications.Protocol (DeviceToken (WPDeviceToken), WPEndpoint (..))
import Simplex.Messaging.Notifications.Server.Store.Types
import Simplex.Messaging.Notifications.Server.Push
import Control.Monad.Except
import Control.Logger.Simple (logDebug)
import Simplex.Messaging.Util (tshow)
import qualified Data.ByteString.Char8 as B
import Data.ByteString.Char8 (ByteString)
import Control.Monad.IO.Class (liftIO)
import Control.Exception ( fromException, SomeException, try )
import qualified Network.HTTP.Types as N

wpPushProviderClient :: Manager -> PushProviderClient
wpPushProviderClient mg tkn _ = do
      e <- B.unpack <$> endpoint tkn
      r <- liftPPWPError $ parseUrlThrow e
      logDebug $ "Request to " <> tshow r.host
      let requestHeaders = [
            ("TTL", "2592000") -- 30 days
            , ("Urgency", "High")
            , ("Content-Encoding", "aes128gcm")
        -- TODO: topic for pings and interval
            ]
      let req = r {
        method = "POST"
        , requestHeaders
        , requestBody = "ping"
        , redirectCount = 0
      }
      _ <- liftPPWPError $ httpNoBody req mg
      pure ()
  where
    endpoint :: NtfTknRec -> ExceptT PushProviderError IO ByteString
    endpoint NtfTknRec {token} = do
      case token of
        WPDeviceToken WPEndpoint{ endpoint = e } -> pure e
        _ -> fail "Wrong device token"

liftPPWPError :: IO a -> ExceptT PushProviderError IO a
liftPPWPError = liftPPWPError' toPPWPError

liftPPWPError' :: (SomeException -> PushProviderError) -> IO a -> ExceptT PushProviderError IO a
liftPPWPError' err a = do
  res <- liftIO $ try @SomeException a
  either (throwError . err) return res

toPPWPError :: SomeException -> PushProviderError
toPPWPError e = case fromException e of
    Just (InvalidUrlException _ _) -> PPWPInvalidUrl
    Just (HttpExceptionRequest _ (StatusCodeException resp _)) -> fromStatusCode (responseStatus resp) ("" :: String)
    _ -> PPWPOtherError e
  where
    fromStatusCode status reason
      | status == N.status200 = PPWPRemovedEndpoint
      | status == N.status410 = PPWPRemovedEndpoint
      | status == N.status413 = PPWPRequestTooLong
      | status == N.status429 = PPRetryLater
      | status >= N.status500 = PPRetryLater
      | otherwise = PPResponseError (Just status) (tshow reason)
