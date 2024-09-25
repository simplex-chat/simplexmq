{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE TypeApplications #-}

module Simplex.Messaging.Notifications.Client where

import Control.Monad.Except
import Control.Monad.Trans.Except
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
  (defaultClientConfig (Just supportedNTFHandshakes) supportedClientNTFVRange)
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

ntfEnableCron :: NtfClient -> C.APrivateAuthKey -> NtfTokenId -> Word16 -> ExceptT NtfClientError IO ()
ntfEnableCron c pKey tknId int = okNtfCommand (TCRN int) c pKey tknId

ntfCreateSubscription :: NtfClient -> C.APrivateAuthKey -> NewNtfEntity 'Subscription -> ExceptT NtfClientError IO NtfSubscriptionId
ntfCreateSubscription c pKey newSub =
  sendNtfCommand c (Just pKey) NoEntity (SNEW newSub) >>= \case
    NRSubId subId -> pure subId
    r -> throwE $ unexpectedResponse r

ntfCheckSubscription :: NtfClient -> C.APrivateAuthKey -> NtfSubscriptionId -> ExceptT NtfClientError IO NtfSubStatus
ntfCheckSubscription c pKey subId =
  sendNtfCommand c (Just pKey) subId SCHK >>= \case
    NRSub stat -> pure stat
    r -> throwE $ unexpectedResponse r

ntfDeleteSubscription :: NtfClient -> C.APrivateAuthKey -> NtfSubscriptionId -> ExceptT NtfClientError IO ()
ntfDeleteSubscription = okNtfCommand SDEL

-- | Send notification server command
sendNtfCommand :: NtfEntityI e => NtfClient -> Maybe C.APrivateAuthKey -> NtfEntityId -> NtfCommand e -> ExceptT NtfClientError IO NtfResponse
sendNtfCommand c pKey entId cmd = sendProtocolCommand c pKey entId (NtfCmd sNtfEntity cmd)

okNtfCommand :: NtfEntityI e => NtfCommand e -> NtfClient -> C.APrivateAuthKey -> NtfEntityId -> ExceptT NtfClientError IO ()
okNtfCommand cmd c pKey entId =
  sendNtfCommand c (Just pKey) entId cmd >>= \case
    NROk -> return ()
    r -> throwE $ unexpectedResponse r
