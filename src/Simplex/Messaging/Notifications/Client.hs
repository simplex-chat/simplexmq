{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Simplex.Messaging.Notifications.Client where

import Control.Monad.Except
import Control.Monad.Trans.Except
import qualified Data.Attoparsec.ByteString.Char8 as A
import Data.Word (Word16)
import Database.SQLite.Simple.FromField (FromField (..))
import Database.SQLite.Simple.ToField (ToField (..))
import Simplex.Messaging.Client
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding
import Simplex.Messaging.Encoding.String (StrEncoding (strEncode), TextEncoding (..))
import Simplex.Messaging.Notifications.Protocol
import Simplex.Messaging.Parsers (blobFieldDecoder, fromTextField_)
import Simplex.Messaging.Protocol (ProtocolServer)

type NtfServer = ProtocolServer

type NtfClient = ProtocolClient NtfResponse

ntfRegisterToken :: NtfClient -> C.APrivateSignKey -> NewNtfEntity 'Token -> ExceptT ProtocolClientError IO (NtfTokenId, C.PublicKeyX25519)
ntfRegisterToken c pKey newTkn =
  sendNtfCommand c (Just pKey) "" (TNEW newTkn) >>= \case
    NRId tknId dhKey -> pure (tknId, dhKey)
    _ -> throwE PCEUnexpectedResponse

ntfVerifyToken :: NtfClient -> C.APrivateSignKey -> NtfTokenId -> NtfRegistrationCode -> ExceptT ProtocolClientError IO ()
ntfVerifyToken c pKey tknId code = okNtfCommand (TVFY code) c pKey tknId

ntfDeleteToken :: NtfClient -> C.APrivateSignKey -> NtfTokenId -> ExceptT ProtocolClientError IO ()
ntfDeleteToken = okNtfCommand TDEL

ntfEnableCron :: NtfClient -> C.APrivateSignKey -> NtfTokenId -> Word16 -> ExceptT ProtocolClientError IO ()
ntfEnableCron c pKey tknId int = okNtfCommand (TCRN int) c pKey tknId

ntfCreateSubsciption :: NtfClient -> C.APrivateSignKey -> NewNtfEntity 'Subscription -> ExceptT ProtocolClientError IO (NtfSubscriptionId, C.PublicKeyX25519)
ntfCreateSubsciption c pKey newSub =
  sendNtfCommand c (Just pKey) "" (SNEW newSub) >>= \case
    NRId tknId dhKey -> pure (tknId, dhKey)
    _ -> throwE PCEUnexpectedResponse

ntfCheckSubscription :: NtfClient -> C.APrivateSignKey -> NtfSubscriptionId -> ExceptT ProtocolClientError IO NtfSubStatus
ntfCheckSubscription c pKey subId =
  sendNtfCommand c (Just pKey) subId SCHK >>= \case
    NRStat stat -> pure stat
    _ -> throwE PCEUnexpectedResponse

ntfDeleteSubscription :: NtfClient -> C.APrivateSignKey -> NtfSubscriptionId -> ExceptT ProtocolClientError IO ()
ntfDeleteSubscription = okNtfCommand SDEL

-- | Send notification server command
sendNtfCommand :: NtfEntityI e => NtfClient -> Maybe C.APrivateSignKey -> NtfEntityId -> NtfCommand e -> ExceptT ProtocolClientError IO NtfResponse
sendNtfCommand c pKey entId = sendProtocolCommand c pKey entId . NtfCmd sNtfEntity

okNtfCommand :: NtfEntityI e => NtfCommand e -> NtfClient -> C.APrivateSignKey -> NtfEntityId -> ExceptT ProtocolClientError IO ()
okNtfCommand cmd c pKey entId =
  sendNtfCommand c (Just pKey) entId cmd >>= \case
    NROk -> return ()
    _ -> throwE PCEUnexpectedResponse

data NtfTknAction
  = NTARegister C.APublicVerifyKey -- public key to send to the server
  | NTAVerify NtfRegistrationCode -- code to verify token
  | NTACheck
  | NTACron Word16
  | NTADelete

instance Encoding NtfTknAction where
  smpEncode = \case
    NTARegister key -> smpEncode ('R', key)
    NTAVerify code -> smpEncode ('V', code)
    NTACheck -> "C"
    NTACron interval -> smpEncode ('I', interval)
    NTADelete -> "D"
  smpP =
    A.anyChar >>= \case
      'R' -> NTARegister <$> smpP
      'V' -> NTAVerify <$> smpP
      'C' -> pure NTACheck
      'I' -> NTACron <$> smpP
      'D' -> pure NTADelete
      _ -> fail "bad NtfTknAction"

instance FromField NtfTknAction where fromField = blobFieldDecoder smpDecode

instance ToField NtfTknAction where toField = toField . smpEncode

data NtfToken = NtfToken
  { deviceToken :: DeviceToken,
    ntfServer :: NtfServer,
    ntfTokenId :: Maybe NtfTokenId,
    -- | key used by the ntf client to sign transmissions
    ntfPrivKey :: C.APrivateSignKey,
    -- | shared DH secret used to encrypt/decrypt notifications e2e
    ntfDhSecret :: Maybe C.DhSecretX25519,
    -- | token status
    ntfTknStatus :: NtfTknStatus,
    -- | pending token action and the earliest time
    ntfTknAction :: Maybe NtfTknAction
  }

newNtfToken :: DeviceToken -> NtfServer -> C.APrivateSignKey -> C.APublicVerifyKey -> NtfToken
newNtfToken deviceToken ntfServer ntfPrivKey ntfPubKey =
  NtfToken
    { deviceToken,
      ntfServer,
      ntfTokenId = Nothing,
      ntfPrivKey,
      ntfDhSecret = Nothing,
      ntfTknStatus = NTNew,
      ntfTknAction = Just $ NTARegister ntfPubKey
    }