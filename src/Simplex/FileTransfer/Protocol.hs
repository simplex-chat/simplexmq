{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# OPTIONS_GHC -fno-warn-unticked-promoted-constructors #-}

module Simplex.FileTransfer.Protocol where
import Data.Aeson (FromJSON (..), ToJSON (..), (.=))
import qualified Data.Aeson as J
import qualified Data.Aeson.Encoding as JE
import qualified Data.Attoparsec.ByteString.Char8 as A
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Kind
import Data.Maybe (isNothing, isJust)
import Data.Text.Encoding (decodeLatin1, encodeUtf8)
import Data.Type.Equality
import Data.Word (Word16)
import Database.SQLite.Simple.FromField (FromField (..))
import Database.SQLite.Simple.ToField (ToField (..))
import Simplex.Messaging.Agent.Protocol (updateSMPServerHosts)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Notifications.Transport (ntfClientHandshake)
import Simplex.Messaging.Parsers (fromTextField_)
import Simplex.Messaging.Protocol hiding (Command (..), CommandTag (..), Recipient, Sender, SRecipient, SSender, Cmd)
import Simplex.Messaging.Util (eitherToMaybe, (<$?>))
import Data.Type.Equality (TestEquality (testEquality))
import Data.Kind (Type)
import Data.ByteString (ByteString)

-- | File protocol clients
data FileParty = Recipient | Sender
  deriving (Show)

data SFileParty :: FileParty -> Type where
  SRecipient :: SFileParty Recipient
  SSender :: SFileParty Sender

instance TestEquality SFileParty where
  testEquality SRecipient SRecipient = Just Refl
  testEquality SSender SSender = Just Refl
  testEquality _ _ = Nothing

deriving instance Show (SFileParty p)

class FilePartyI (p :: FileParty) where sFileParty :: SFileParty p

instance FilePartyI Recipient where sFileParty = SRecipient

instance FilePartyI Sender where sFileParty = SSender

data FileCommandTag (p :: FileParty) where
  NEW_ :: FileCommandTag Sender
  ADD_ :: FileCommandTag Sender
  UP_ :: FileCommandTag Sender
  SDEL_ :: FileCommandTag Sender
  DOWN_ :: FileCommandTag Recipient
  RDEL_ :: FileCommandTag Recipient
  PING_ :: FileCommandTag Recipient

deriving instance Show (FileCommandTag p)

data FileCmdTag = forall p. FilePartyI p => CT (SFileParty p) (FileCommandTag p)

instance FilePartyI p => Encoding (FileCommandTag p) where
  smpEncode = \case
    NEW_ -> "NEW"
    ADD_ -> "ADD"
    UP_ -> "UP"
    SDEL_ -> "SDEL"
    DOWN_ -> "DOWN"
    RDEL_ -> "RDEL"
    PING_ -> "PING"
  smpP = messageTagP

instance Encoding FileCmdTag where
  smpEncode (CT _ t) = smpEncode t
  smpP = messageTagP

instance ProtocolMsgTag FileCmdTag where
  decodeTag = \case
    "NEW" -> Just $ CT SSender NEW_
    "ADD" -> Just $ CT SSender ADD_
    "UP" -> Just $ CT SSender UP_
    "SDEL" -> Just $ CT SSender SDEL_
    "DOWN" -> Just $ CT SRecipient DOWN_
    "RDEL" -> Just $ CT SRecipient RDEL_
    "PING" -> Just $ CT SRecipient PING_
    _ -> Nothing


instance FilePartyI p => ProtocolMsgTag (FileCommandTag p) where
  decodeTag s = decodeTag s >>= (\(CT _ t) -> checkParty' t)

{- newtype NtfRegCode = NtfRegCode ByteString
  deriving (Eq, Show)

instance Encoding NtfRegCode where
  smpEncode (NtfRegCode code) = smpEncode code
  smpP = NtfRegCode <$> smpP

instance StrEncoding NtfRegCode where
  strEncode (NtfRegCode m) = strEncode m
  strDecode s = NtfRegCode <$> strDecode s
  strP = NtfRegCode <$> strP
  
instance FromJSON NtfRegCode where
  parseJSON = strParseJSON "NtfRegCode"

instance ToJSON NtfRegCode where
  toJSON = strToJSON
  toEncoding = strToJEncoding

data NewNtfEntity (e :: NtfEntity) where
  NewNtfTkn :: DeviceToken -> C.APublicVerifyKey -> C.PublicKeyX25519 -> NewNtfEntity 'Token
  NewNtfSub :: NtfTokenId -> SMPQueueNtf -> NtfPrivateSignKey -> NewNtfEntity 'Subscription

deriving instance Show (NewNtfEntity e)

data ANewNtfEntity = forall e. NtfEntityI e => ANE (SNtfEntity e) (NewNtfEntity e)

deriving instance Show ANewNtfEntity

instance NtfEntityI e => Encoding (NewNtfEntity e) where
  smpEncode = \case
    NewNtfTkn tkn verifyKey dhPubKey -> smpEncode ('T', tkn, verifyKey, dhPubKey)
    NewNtfSub tknId smpQueue notifierKey -> smpEncode ('S', tknId, smpQueue, notifierKey)
  smpP = (\(ANE _ c) -> checkEntity c) <$?> smpP

instance Encoding ANewNtfEntity where
  smpEncode (ANE _ e) = smpEncode e
  smpP =
    A.anyChar >>= \case
      'T' -> ANE SToken <$> (NewNtfTkn <$> smpP <*> smpP <*> smpP)
      'S' -> ANE SSubscription <$> (NewNtfSub <$> smpP <*> smpP <*> smpP)
      _ -> fail "bad ANewNtfEntity"

   -}

instance Protocol FileResponse where
  type ProtoCommand FileResponse = FileCmd
  type ProtoType FileResponse = 'PNTF
  protocolClientHandshake = ntfClientHandshake
  protocolPing = FileCmd SRecipient PING
  protocolError = \case
    FRErr e -> Just e
    _ -> Nothing

data FileCommand (p :: FileParty) where
  -- Sender key, recipients keys, chunk size
  NEW :: SndPublicVerifyKey -> [RcvPublicVerifyKey] -> Int -> FileCommand Sender
  ADD :: [RcvPublicVerifyKey] -> FileCommand Sender
  UP :: FileCommand Sender
  SDEL :: FileCommand Sender
  DOWN :: RcvDhSecret -> FileCommand Recipient
  RDEL :: FileCommand Recipient
  PING :: FileCommand Recipient

deriving instance Show (FileCommand p)

data FileCmd = forall p. FilePartyI p => FileCmd (SFileParty p) (FileCommand p)

deriving instance Show FileCmd

instance FilePartyI p => ProtocolEncoding (FileCommand p) where
  type Tag (FileCommand p) = FileCommandTag p
  encodeProtocol _v = \case
    NEW sKey dhKeys chunkSize -> e (NEW_, ' ', sKey, dhKeys, chunkSize)
    ADD dhKeys -> e (ADD_, ' ', dhKeys)
    UP -> e UP_
    SDEL -> e SDEL_
    DOWN dhKey -> e (DOWN_, ' ', dhKey)
    RDEL -> e RDEL_
    PING -> e PING
    where
      e :: Encoding a => a -> ByteString
      e = smpEncode

  protocolP v tag = (\(FileCmd _ c) -> checkParty c) <$?> protocolP v (CT (sFileParty @p) tag)

  checkCredentials (sig, _, chunkId, _) cmd = case cmd of
    -- NEW must not have signature and chunk ID
    NEW {}
      | isJust sig || not (B.null chunkId) -> Left $ CMD HAS_AUTH
      | otherwise -> Right cmd
    -- other client commands must have both signature and queue ID
    _
      | isNothing sig || B.null chunkId -> Left $ CMD NO_AUTH
      | otherwise -> Right cmd

instance ProtocolEncoding FileCmd where
  type Tag FileCmd = FileCmdTag
  encodeProtocol _v (FileCmd _ c) = encodeProtocol _v c

  protocolP _v = \case
    CT SSender tag ->
      FileCmd SSender <$> case tag of
        NEW_ -> NEW <$> _smpP
        ADD_ -> ADD <$> _smpP
        UP_ -> pure UP
        SDEL_ -> pure SDEL
    CT SRecipient tag ->
      FileCmd SRecipient <$> case tag of
        DOWN_ -> DOWN <$> _smpP
        RDEL_ -> pure RDEL
        PING_ -> pure PING

  checkCredentials t (FileCmd p c) = FileCmd p <$> checkCredentials t c

data FileResponseTag
  = FRChunkId_
  | FROk_
  | FRErr_
  | FRPong_

  deriving (Show)

instance Encoding FileResponseTag where
  smpEncode = \case
    FRChunkId_ -> "CHUNK"
    FROk_ -> "OK"
    FRErr_ -> "ERR"
    FRPong_ -> "PONG"
  smpP = messageTagP

instance ProtocolMsgTag FileResponseTag where
  decodeTag = \case
    "CHUNK" -> Just FRChunkId_
    "OK" -> Just FROk_
    "ERR" -> Just FRErr_
    "PONG" -> Just FRPong_
    _ -> Nothing

data FileResponse
  = FRChunkId FileChunkId
  | FROk
  | FRErr ErrorType
  | FRPong
  deriving (Show)

instance ProtocolEncoding FileResponse where
  type Tag FileResponse = FileResponseTag
  encodeProtocol _v = \case
    FRChunkId chunkId -> e (FRChunkId_, ' ', chunkId)
    FROk -> e FROk_
    FRErr err -> e (FRErr_, ' ', err)
    FRPong -> e FRPong_
    where
      e :: Encoding a => a -> ByteString
      e = smpEncode

  protocolP _v = \case
    FRChunkId_ -> FRChunkId <$> _smpP <*> smpP
    FROk_ -> pure FROk
    FRErr_ -> FRErr <$> _smpP
    FRPong_ -> pure FRPong

  checkCredentials (_, _, entId, _) cmd = case cmd of
    FRChunkId {} -> noEntity
    -- ERR response does not always have entity ID
    FRErr _ -> Right cmd
    -- PONG response must not have queue ID
    FRPong -> noEntity
    -- other server responses must have entity ID
    _
      | B.null entId -> Left $ CMD NO_ENTITY
      | otherwise -> Right cmd
    where
      noEntity
        | B.null entId = Right cmd
        | otherwise = Left $ CMD HAS_AUTH


{- 
data SMPQueueNtf = SMPQueueNtf
  { smpServer :: SMPServer,
    notifierId :: NotifierId
  }
  deriving (Eq, Ord, Show)

instance Encoding SMPQueueNtf where
  smpEncode SMPQueueNtf {smpServer, notifierId} = smpEncode (smpServer, notifierId)
  smpP = do
    smpServer <- updateSMPServerHosts <$> smpP
    notifierId <- smpP
    pure SMPQueueNtf {smpServer, notifierId}

instance StrEncoding SMPQueueNtf where
  strEncode SMPQueueNtf {smpServer, notifierId} = strEncode smpServer <> "/" <> strEncode notifierId
  strP = do
    smpServer <- updateSMPServerHosts <$> strP
    notifierId <- A.char '/' *> strP
    pure SMPQueueNtf {smpServer, notifierId}

data PushProvider = PPApnsDev | PPApnsProd | PPApnsTest
  deriving (Eq, Ord, Show)

instance Encoding PushProvider where
  smpEncode = \case
    PPApnsDev -> "AD"
    PPApnsProd -> "AP"
    PPApnsTest -> "AT"
  smpP =
    A.take 2 >>= \case
      "AD" -> pure PPApnsDev
      "AP" -> pure PPApnsProd
      "AT" -> pure PPApnsTest
      _ -> fail "bad PushProvider"

instance StrEncoding PushProvider where
  strEncode = \case
    PPApnsDev -> "apns_dev"
    PPApnsProd -> "apns_prod"
    PPApnsTest -> "apns_test"
  strP =
    A.takeTill (== ' ') >>= \case
      "apns_dev" -> pure PPApnsDev
      "apns_prod" -> pure PPApnsProd
      "apns_test" -> pure PPApnsTest
      _ -> fail "bad PushProvider"

instance FromField PushProvider where fromField = fromTextField_ $ eitherToMaybe . strDecode . encodeUtf8

instance ToField PushProvider where toField = toField . decodeLatin1 . strEncode

data DeviceToken = DeviceToken PushProvider ByteString
  deriving (Eq, Ord, Show)

instance Encoding DeviceToken where
  smpEncode (DeviceToken p t) = smpEncode (p, t)
  smpP = DeviceToken <$> smpP <*> smpP

instance StrEncoding DeviceToken where
  strEncode (DeviceToken p t) = strEncode p <> " " <> t
  strP = DeviceToken <$> strP <* A.space <*> hexStringP
    where
      hexStringP =
        A.takeWhile (\c -> A.isDigit c || (c >= 'a' && c <= 'f')) >>= \s ->
          if even (B.length s) then pure s else fail "odd number of hex characters"

instance ToJSON DeviceToken where
  toEncoding (DeviceToken pp t) = J.pairs $ "pushProvider" .= decodeLatin1 (strEncode pp) <> "token" .= decodeLatin1 t
  toJSON (DeviceToken pp t) = J.object ["pushProvider" .= decodeLatin1 (strEncode pp), "token" .= decodeLatin1 t]

 -}

type FileChunkId = ByteString

checkParty :: forall t p p'. (FilePartyI p, FilePartyI p') => t p' -> Either String (t p)
checkParty c = case testEquality (sFileParty @p) (sFileParty @p') of
  Just Refl -> Right c
  Nothing -> Left "bad command party"

checkParty' :: forall t p p'. (FilePartyI p, FilePartyI p') => t p' -> Maybe (t p)
checkParty' c = case testEquality (sFileParty @p) (sFileParty @p') of
  Just Refl -> Just c
  _ -> Nothing
