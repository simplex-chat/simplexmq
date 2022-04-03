{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Simplex.Messaging.Notifications.Client where

import Control.Monad.Except
import Control.Monad.Trans.Except
import Data.Time (UTCTime)
import Data.Word (Word16)
import Simplex.Messaging.Client
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Notifications.Protocol
import Simplex.Messaging.Protocol (ProtocolServer)

type NtfServer = ProtocolServer

type NtfClient = ProtocolClient NtfResponse

registerNtfToken :: NtfClient -> C.APrivateSignKey -> NewNtfEntity 'Token -> ExceptT ProtocolClientError IO (NtfTokenId, C.PublicKeyX25519)
registerNtfToken c pKey newTkn =
  sendNtfCommand c (Just pKey) "" (TNEW newTkn) >>= \case
    NRId tknId dhKey -> pure (tknId, dhKey)
    _ -> throwE PCEUnexpectedResponse

verifyNtfToken :: NtfClient -> C.APrivateSignKey -> NtfTokenId -> NtfRegistrationCode -> ExceptT ProtocolClientError IO ()
verifyNtfToken c pKey tknId code = okNtfCommand (TVFY code) c pKey tknId

deleteNtfToken :: NtfClient -> C.APrivateSignKey -> NtfTokenId -> ExceptT ProtocolClientError IO ()
deleteNtfToken = okNtfCommand TDEL

enableNtfCron :: NtfClient -> C.APrivateSignKey -> NtfTokenId -> Word16 -> ExceptT ProtocolClientError IO ()
enableNtfCron c pKey tknId int = okNtfCommand (TCRN int) c pKey tknId

createNtfSubsciption :: NtfClient -> C.APrivateSignKey -> NewNtfEntity 'Subscription -> ExceptT ProtocolClientError IO (NtfSubscriptionId, C.PublicKeyX25519)
createNtfSubsciption c pKey newSub =
  sendNtfCommand c (Just pKey) "" (SNEW newSub) >>= \case
    NRId tknId dhKey -> pure (tknId, dhKey)
    _ -> throwE PCEUnexpectedResponse

checkNtfSubscription :: NtfClient -> C.APrivateSignKey -> NtfSubscriptionId -> ExceptT ProtocolClientError IO NtfSubStatus
checkNtfSubscription c pKey subId =
  sendNtfCommand c (Just pKey) subId SCHK >>= \case
    NRStat stat -> pure stat
    _ -> throwE PCEUnexpectedResponse

deleteNfgSubscription :: NtfClient -> C.APrivateSignKey -> NtfSubscriptionId -> ExceptT ProtocolClientError IO ()
deleteNfgSubscription = okNtfCommand SDEL

-- | Send notification server command
sendNtfCommand :: NtfEntityI e => NtfClient -> Maybe C.APrivateSignKey -> NtfEntityId -> NtfCommand e -> ExceptT ProtocolClientError IO NtfResponse
sendNtfCommand c pKey entId = sendProtocolCommand c pKey entId . NtfCmd sNtfEntity

okNtfCommand :: NtfEntityI e => NtfCommand e -> NtfClient -> C.APrivateSignKey -> NtfEntityId -> ExceptT ProtocolClientError IO ()
okNtfCommand cmd c pKey entId =
  sendNtfCommand c (Just pKey) entId cmd >>= \case
    NROk -> return ()
    _ -> throwE PCEUnexpectedResponse

data NtfTknAction = NTARegister | NTAVerify | NTACheck | NTADelete

data NewStoreNtfToken = NewStoreNtfToken
  { deviceToken :: DeviceToken,
    ntfServer :: NtfServer,
    ntfPrivKey :: C.APrivateSignKey,
    ntfPubKey :: C.APublicVerifyKey
  }

data NtfToken = NtfToken
  { deviceToken :: DeviceToken,
    ntfServer :: NtfServer,
    ntfTokenId :: NtfTokenId,
    -- | key used by the ntf client to sign transmissions
    ntfPrivKey :: C.APrivateSignKey,
    -- | key used by the ntf server to verify transmissions
    ntfPubKey :: C.APublicVerifyKey,
    -- | shared DH secret used to encrypt/decrypt notifications e2e
    ntfDhSecret :: C.DhSecretX25519,
    -- | token status
    ntfTknStatus :: NtfTknStatus,
    -- | pending token action and the earliest time
    ntfTknAction :: Maybe (NtfTknAction, UTCTime)
  }
