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
import Simplex.Messaging.Notifications.Transport (NTFVersion, supportedClientNTFVRange, supportedNTFHandshakes)
import Simplex.Messaging.Protocol (ErrorType, pattern NoEntity)
import Simplex.Messaging.Transport (TLS, Transport (..))

type NtfClient = ProtocolClient NTFVersion ErrorType NtfResponse

type NtfClientError = ProtocolClientError ErrorType

defaultNTFClientConfig :: ProtocolClientConfig NTFVersion
defaultNTFClientConfig =
  (defaultClientConfig (Just supportedNTFHandshakes) False supportedClientNTFVRange)
    {defaultTransport = ("443", transport @TLS)}
{-# INLINE defaultNTFClientConfig #-}

ntfRegisterToken :: NtfClient -> C.APrivateAuthKey -> NewNtfEntity 'Token -> ExceptT NtfClientError IO (NtfTokenId, C.PublicKeyX25519)
ntfRegisterToken c pKey newTkn =
  sendNtfCommand c (Just pKey) NoEntity (TNEW newTkn) >>= \case
    NRTknId tknId dhKey -> pure (tknId, dhKey)
    r -> throwE $ unexpectedResponse r

ntfVerifyToken :: NtfClient -> C.APrivateAuthKey -> NtfTokenId -> NtfRegCode -> ExceptT NtfClientError IO ()
ntfVerifyToken c pKey tknId code = okNtfCommand (TVFY code) c pKey tknId

ntfCheckToken :: NtfClient -> C.APrivateAuthKey -> NtfTokenId -> ExceptT NtfClientError IO NtfTknStatus
ntfCheckToken c pKey tknId =
  sendNtfCommand c (Just pKey) tknId TCHK >>= \case
    NRTkn stat -> pure stat
    r -> throwE $ unexpectedResponse r

ntfReplaceToken :: NtfClient -> C.APrivateAuthKey -> NtfTokenId -> DeviceToken -> ExceptT NtfClientError IO ()
ntfReplaceToken c pKey tknId token = okNtfCommand (TRPL token) c pKey tknId

ntfDeleteToken :: NtfClient -> C.APrivateAuthKey -> NtfTokenId -> ExceptT NtfClientError IO ()
ntfDeleteToken = okNtfCommand TDEL

-- set to 0 to disable
ntfSetCronInterval :: NtfClient -> C.APrivateAuthKey -> NtfTokenId -> Word16 -> ExceptT NtfClientError IO ()
ntfSetCronInterval c pKey tknId int = okNtfCommand (TCRN int) c pKey tknId

ntfCreateSubscription :: NtfClient -> C.APrivateAuthKey -> NewNtfEntity 'Subscription -> ExceptT NtfClientError IO NtfSubscriptionId
ntfCreateSubscription c pKey newSub =
  sendNtfCommand c (Just pKey) NoEntity (SNEW newSub) >>= \case
    NRSubId subId -> pure subId
    r -> throwE $ unexpectedResponse r

ntfCreateSubscriptions :: NtfClient -> C.APrivateAuthKey -> NonEmpty (NewNtfEntity 'Subscription) -> IO (NonEmpty (Either NtfClientError NtfSubscriptionId))
ntfCreateSubscriptions c pKey newSubs = L.map process <$> sendProtocolCommands c cs
  where
    cs = L.map (\newSub -> (Just pKey, NoEntity, NtfCmd SSubscription $ SNEW newSub)) newSubs
    process (Response _ r) = case r of
      Right (NRSubId subId) -> Right subId
      Right r' -> Left $ unexpectedResponse r'
      Left e -> Left e

ntfCheckSubscription :: NtfClient -> C.APrivateAuthKey -> NtfSubscriptionId -> ExceptT NtfClientError IO NtfSubStatus
ntfCheckSubscription c pKey subId =
  sendNtfCommand c (Just pKey) subId SCHK >>= \case
    NRSub stat -> pure stat
    r -> throwE $ unexpectedResponse r

ntfCheckSubscriptions :: NtfClient -> C.APrivateAuthKey -> NonEmpty NtfSubscriptionId -> IO (NonEmpty (Either NtfClientError NtfSubStatus))
ntfCheckSubscriptions c pKey subIds = L.map process <$> sendProtocolCommands c cs
  where
    cs = L.map (\subId -> (Just pKey, subId, NtfCmd SSubscription SCHK)) subIds
    process (Response _ r) = case r of
      Right (NRSub stat) -> Right stat
      Right r' -> Left $ unexpectedResponse r'
      Left e -> Left e

ntfDeleteSubscription :: NtfClient -> C.APrivateAuthKey -> NtfSubscriptionId -> ExceptT NtfClientError IO ()
ntfDeleteSubscription = okNtfCommand SDEL

-- | Send notification server command
sendNtfCommand :: NtfEntityI e => NtfClient -> Maybe C.APrivateAuthKey -> NtfEntityId -> NtfCommand e -> ExceptT NtfClientError IO NtfResponse
sendNtfCommand c pKey entId cmd = sendProtocolCommand c False pKey entId (NtfCmd sNtfEntity cmd)

okNtfCommand :: NtfEntityI e => NtfCommand e -> NtfClient -> C.APrivateAuthKey -> NtfEntityId -> ExceptT NtfClientError IO ()
okNtfCommand cmd c pKey entId =
  sendNtfCommand c (Just pKey) entId cmd >>= \case
    NROk -> return ()
    r -> throwE $ unexpectedResponse r
