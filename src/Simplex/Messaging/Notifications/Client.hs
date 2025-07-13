{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE TypeApplications #-}

module Simplex.Messaging.Notifications.Client where

import Control.Monad.Except
import Control.Monad.Trans.Except
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as L
import Data.Word (Word16)
import Simplex.Messaging.Client
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Notifications.Protocol
import Simplex.Messaging.Notifications.Transport (NTFVersion, supportedClientNTFVRange, alpnSupportedNTFHandshakes)
import Simplex.Messaging.Protocol (ErrorType, pattern NoEntity)
import Simplex.Messaging.Transport (TLS, Transport (..))

type NtfClient = ProtocolClient NTFVersion ErrorType NtfResponse

type NtfClientError = ProtocolClientError ErrorType

defaultNTFClientConfig :: ProtocolClientConfig NTFVersion
defaultNTFClientConfig =
  (defaultClientConfig (Just alpnSupportedNTFHandshakes) False supportedClientNTFVRange)
    {defaultTransport = ("443", transport @TLS)}
{-# INLINE defaultNTFClientConfig #-}

ntfRegisterToken :: NtfClient -> NetworkRequestMode -> C.APrivateAuthKey -> NewNtfEntity 'Token -> ExceptT NtfClientError IO (NtfTokenId, C.PublicKeyX25519)
ntfRegisterToken c nm pKey newTkn =
  sendNtfCommand c nm (Just pKey) NoEntity (TNEW newTkn) >>= \case
    NRTknId tknId dhKey -> pure (tknId, dhKey)
    r -> throwE $ unexpectedResponse r

ntfVerifyToken :: NtfClient -> NetworkRequestMode -> C.APrivateAuthKey -> NtfTokenId -> NtfRegCode -> ExceptT NtfClientError IO ()
ntfVerifyToken c nm pKey tknId code = okNtfCommand (TVFY code) c nm pKey tknId

ntfCheckToken :: NtfClient -> NetworkRequestMode -> C.APrivateAuthKey -> NtfTokenId -> ExceptT NtfClientError IO NtfTknStatus
ntfCheckToken c nm pKey tknId =
  sendNtfCommand c nm (Just pKey) tknId TCHK >>= \case
    NRTkn stat -> pure stat
    r -> throwE $ unexpectedResponse r

ntfReplaceToken :: NtfClient -> NetworkRequestMode -> C.APrivateAuthKey -> NtfTokenId -> DeviceToken -> ExceptT NtfClientError IO ()
ntfReplaceToken c nm pKey tknId token = okNtfCommand (TRPL token) c nm pKey tknId

ntfDeleteToken :: NtfClient -> NetworkRequestMode -> C.APrivateAuthKey -> NtfTokenId -> ExceptT NtfClientError IO ()
ntfDeleteToken = okNtfCommand TDEL

-- set to 0 to disable
ntfSetCronInterval :: NtfClient -> NetworkRequestMode -> C.APrivateAuthKey -> NtfTokenId -> Word16 -> ExceptT NtfClientError IO ()
ntfSetCronInterval c nm pKey tknId int = okNtfCommand (TCRN int) c nm pKey tknId

ntfCreateSubscription :: NtfClient -> C.APrivateAuthKey -> NewNtfEntity 'Subscription -> ExceptT NtfClientError IO NtfSubscriptionId
ntfCreateSubscription c pKey newSub =
  sendNtfCommand c NRMBackground (Just pKey) NoEntity (SNEW newSub) >>= \case
    NRSubId subId -> pure subId
    r -> throwE $ unexpectedResponse r

ntfCreateSubscriptions :: NtfClient -> C.APrivateAuthKey -> NonEmpty (NewNtfEntity 'Subscription) -> IO (NonEmpty (Either NtfClientError NtfSubscriptionId))
ntfCreateSubscriptions c pKey newSubs = L.map process <$> sendProtocolCommands c NRMBackground cs
  where
    cs = L.map (\newSub -> (NoEntity, Just pKey, NtfCmd SSubscription $ SNEW newSub)) newSubs
    process (Response _ r) = case r of
      Right (NRSubId subId) -> Right subId
      Right r' -> Left $ unexpectedResponse r'
      Left e -> Left e

ntfCheckSubscription :: NtfClient -> C.APrivateAuthKey -> NtfSubscriptionId -> ExceptT NtfClientError IO NtfSubStatus
ntfCheckSubscription c pKey subId =
  sendNtfCommand c NRMBackground (Just pKey) subId SCHK >>= \case
    NRSub stat -> pure stat
    r -> throwE $ unexpectedResponse r

ntfCheckSubscriptions :: NtfClient -> C.APrivateAuthKey -> NonEmpty NtfSubscriptionId -> IO (NonEmpty (Either NtfClientError NtfSubStatus))
ntfCheckSubscriptions c pKey subIds = L.map process <$> sendProtocolCommands c NRMBackground cs
  where
    cs = L.map (\subId -> (subId, Just pKey, NtfCmd SSubscription SCHK)) subIds
    process (Response _ r) = case r of
      Right (NRSub stat) -> Right stat
      Right r' -> Left $ unexpectedResponse r'
      Left e -> Left e

ntfDeleteSubscription :: NtfClient -> C.APrivateAuthKey -> NtfSubscriptionId -> ExceptT NtfClientError IO ()
ntfDeleteSubscription c = okNtfCommand SDEL c NRMBackground

-- | Send notification server command
sendNtfCommand :: NtfEntityI e => NtfClient -> NetworkRequestMode -> Maybe C.APrivateAuthKey -> NtfEntityId -> NtfCommand e -> ExceptT NtfClientError IO NtfResponse
sendNtfCommand c nm pKey entId cmd = sendProtocolCommand c nm pKey entId (NtfCmd sNtfEntity cmd)

okNtfCommand :: NtfEntityI e => NtfCommand e -> NtfClient -> NetworkRequestMode -> C.APrivateAuthKey -> NtfEntityId -> ExceptT NtfClientError IO ()
okNtfCommand cmd c nm pKey entId =
  sendNtfCommand c nm (Just pKey) entId cmd >>= \case
    NROk -> return ()
    r -> throwE $ unexpectedResponse r
