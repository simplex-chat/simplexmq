{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

module Simplex.Messaging.Notifications.Client where

import Control.Monad.Except
import Control.Monad.Trans.Except
import Data.Word (Word16)
import Simplex.Messaging.Client
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Notifications.Protocol

type NtfClient = ProtocolClient NtfResponse

ntfRegisterToken :: NtfClient -> C.APrivateSignKey -> NewNtfEntity 'Token -> ExceptT ProtocolClientError IO (NtfTokenId, C.PublicKeyX25519)
ntfRegisterToken c pKey newTkn =
  sendNtfCommand c (Just pKey) "" (TNEW newTkn) >>= \case
    NRTknId tknId dhKey -> pure (tknId, dhKey)
    _ -> throwE PCEUnexpectedResponse

ntfVerifyToken :: NtfClient -> C.APrivateSignKey -> NtfTokenId -> NtfRegCode -> ExceptT ProtocolClientError IO ()
ntfVerifyToken c pKey tknId code = okNtfCommand (TVFY code) c pKey tknId

ntfCheckToken :: NtfClient -> C.APrivateSignKey -> NtfTokenId -> ExceptT ProtocolClientError IO NtfTknStatus
ntfCheckToken c pKey tknId =
  sendNtfCommand c (Just pKey) tknId TCHK >>= \case
    NRTkn stat -> pure stat
    _ -> throwE PCEUnexpectedResponse

ntfReplaceToken :: NtfClient -> C.APrivateSignKey -> NtfTokenId -> DeviceToken -> ExceptT ProtocolClientError IO ()
ntfReplaceToken c pKey tknId token = okNtfCommand (TRPL token) c pKey tknId

ntfDeleteToken :: NtfClient -> C.APrivateSignKey -> NtfTokenId -> ExceptT ProtocolClientError IO ()
ntfDeleteToken = okNtfCommand TDEL

ntfEnableCron :: NtfClient -> C.APrivateSignKey -> NtfTokenId -> Word16 -> ExceptT ProtocolClientError IO ()
ntfEnableCron c pKey tknId int = okNtfCommand (TCRN int) c pKey tknId

ntfCreateSubscription :: NtfClient -> C.APrivateSignKey -> NewNtfEntity 'Subscription -> ExceptT ProtocolClientError IO NtfSubscriptionId
ntfCreateSubscription c pKey newSub =
  sendNtfCommand c (Just pKey) "" (SNEW newSub) >>= \case
    NRSubId subId -> pure subId
    _ -> throwE PCEUnexpectedResponse

ntfCheckSubscription :: NtfClient -> C.APrivateSignKey -> NtfSubscriptionId -> ExceptT ProtocolClientError IO NtfSubStatus
ntfCheckSubscription c pKey subId =
  sendNtfCommand c (Just pKey) subId SCHK >>= \case
    NRSub stat -> pure stat
    _ -> throwE PCEUnexpectedResponse

ntfDeleteSubscription :: NtfClient -> C.APrivateSignKey -> NtfSubscriptionId -> ExceptT ProtocolClientError IO ()
ntfDeleteSubscription = okNtfCommand SDEL

-- | Send notification server command
sendNtfCommand :: NtfEntityI e => NtfClient -> Maybe C.APrivateSignKey -> NtfEntityId -> NtfCommand e -> ExceptT ProtocolClientError IO NtfResponse
sendNtfCommand c pKey entId cmd = sendProtocolCommand c pKey entId (NtfCmd sNtfEntity cmd)

okNtfCommand :: NtfEntityI e => NtfCommand e -> NtfClient -> C.APrivateSignKey -> NtfEntityId -> ExceptT ProtocolClientError IO ()
okNtfCommand cmd c pKey entId =
  sendNtfCommand c (Just pKey) entId cmd >>= \case
    NROk -> return ()
    _ -> throwE PCEUnexpectedResponse
