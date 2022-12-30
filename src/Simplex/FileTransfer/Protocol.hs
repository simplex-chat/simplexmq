{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# OPTIONS_GHC -fno-warn-unticked-promoted-constructors #-}

module Simplex.FileTransfer.Protocol where

import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Data (type (:~:) (Refl))
import Data.Kind (Type)
import Data.List.NonEmpty (NonEmpty)
import Data.Maybe (isJust, isNothing)
import Data.Type.Equality (TestEquality (testEquality))
import Data.Word (Word32)
import Simplex.Messaging.Encoding
import Simplex.Messaging.Notifications.Transport (ntfClientHandshake)
import Simplex.Messaging.Protocol hiding (Cmd, Command (..), CommandTag (..), Recipient, SRecipient, SSender, Sender)
import Simplex.Messaging.Util ((<$?>))

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
  FNEW_ :: FileCommandTag Sender
  FADD_ :: FileCommandTag Sender
  FPUT_ :: FileCommandTag Sender
  FDEL_ :: FileCommandTag Sender
  FGET_ :: FileCommandTag Recipient
  FACK_ :: FileCommandTag Recipient
  PING_ :: FileCommandTag Recipient

deriving instance Show (FileCommandTag p)

data FileCmdTag = forall p. FilePartyI p => FCT (SFileParty p) (FileCommandTag p)

instance FilePartyI p => Encoding (FileCommandTag p) where
  smpEncode = \case
    FNEW_ -> "FNEW"
    FADD_ -> "FADD"
    FPUT_ -> "FPUT"
    FDEL_ -> "FDEL"
    FGET_ -> "FGET"
    FACK_ -> "FACK"
    PING_ -> "PING"
  smpP = messageTagP

instance Encoding FileCmdTag where
  smpEncode (FCT _ t) = smpEncode t
  smpP = messageTagP

instance ProtocolMsgTag FileCmdTag where
  decodeTag = \case
    "FNEW" -> Just $ FCT SSender FNEW_
    "FADD" -> Just $ FCT SSender FADD_
    "FPUT" -> Just $ FCT SSender FPUT_
    "FDEL" -> Just $ FCT SSender FDEL_
    "FGET" -> Just $ FCT SRecipient FGET_
    "FACK" -> Just $ FCT SRecipient FACK_
    "PING" -> Just $ FCT SRecipient PING_
    _ -> Nothing

instance FilePartyI p => ProtocolMsgTag (FileCommandTag p) where
  decodeTag s = decodeTag s >>= (\(FCT _ t) -> checkParty' t)

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
  FNEW :: SndPublicVerifyKey -> NonEmpty RcvPublicVerifyKey -> Word32 -> FileCommand Sender
  FADD :: NonEmpty RcvPublicVerifyKey -> FileCommand Sender
  FPUT :: FileCommand Sender
  FDEL :: FileCommand Sender
  FGET :: RcvPublicDhKey -> FileCommand Recipient
  FACK :: FileCommand Recipient
  PING :: FileCommand Recipient

deriving instance Show (FileCommand p)

data FileCmd = forall p. FilePartyI p => FileCmd (SFileParty p) (FileCommand p)

deriving instance Show FileCmd

instance FilePartyI p => ProtocolEncoding (FileCommand p) where
  type Tag (FileCommand p) = FileCommandTag p
  encodeProtocol _v = \case
    FNEW sKey dhKeys chunkSize -> e (FNEW_, ' ', sKey, dhKeys, chunkSize)
    FADD dhKeys -> e (FADD_, ' ', dhKeys)
    FPUT -> e FPUT_
    FDEL -> e FDEL_
    FGET dhKey -> e (FGET_, ' ', dhKey)
    FACK -> e FACK_
    PING -> e PING_
    where
      e :: Encoding a => a -> ByteString
      e = smpEncode

  protocolP v tag = (\(FileCmd _ c) -> checkParty c) <$?> protocolP v (FCT (sFileParty @p) tag)

  checkCredentials (sig, _, chunkId, _) cmd = case cmd of
    -- FNEW must not have signature and chunk ID
    FNEW {}
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
    FCT SSender tag ->
      FileCmd SSender <$> case tag of
        FNEW_ -> FNEW <$> _smpP <*> smpP <*> smpP
        FADD_ -> FADD <$> _smpP
        FPUT_ -> pure FPUT
        FDEL_ -> pure FDEL
    FCT SRecipient tag ->
      FileCmd SRecipient <$> case tag of
        FGET_ -> FGET <$> _smpP
        FACK_ -> pure FACK
        PING_ -> pure PING

  checkCredentials t (FileCmd p c) = FileCmd p <$> checkCredentials t c

data FileResponseTag
  = FRChunkIds_
  | FRRcvIds_
  | FROk_
  | FRErr_
  | FRPong_
  deriving (Show)

instance Encoding FileResponseTag where
  smpEncode = \case
    FRChunkIds_ -> "CHUNK"
    FRRcvIds_ -> "RIDS"
    FROk_ -> "OK"
    FRErr_ -> "ERR"
    FRPong_ -> "PONG"
  smpP = messageTagP

instance ProtocolMsgTag FileResponseTag where
  decodeTag = \case
    "CHUNK" -> Just FRChunkIds_
    "RIDS" -> Just FRRcvIds_
    "OK" -> Just FROk_
    "ERR" -> Just FRErr_
    "PONG" -> Just FRPong_
    _ -> Nothing

data FileResponse
  = FRChunkIds FileChunkId (NonEmpty FileChunkId)
  | FRRcvIds (NonEmpty FileChunkId)
  | FROk
  | FRErr ErrorType
  | FRPong
  deriving (Show)

instance ProtocolEncoding FileResponse where
  type Tag FileResponse = FileResponseTag
  encodeProtocol _v = \case
    FRChunkIds chId rIds -> e (FRChunkIds_, ' ', chId, rIds)
    FRRcvIds rIds -> e (FRRcvIds_, ' ', rIds)
    FROk -> e FROk_
    FRErr err -> e (FRErr_, ' ', err)
    FRPong -> e FRPong_
    where
      e :: Encoding a => a -> ByteString
      e = smpEncode

  protocolP _v = \case
    FRChunkIds_ -> FRChunkIds <$> _smpP <*> smpP
    FRRcvIds_ -> FRRcvIds <$> _smpP
    FROk_ -> pure FROk
    FRErr_ -> FRErr <$> _smpP
    FRPong_ -> pure FRPong

  checkCredentials (_, _, entId, _) cmd = case cmd of
    FRChunkIds {} -> noEntity
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

type FileChunkId = ByteString

checkParty :: forall t p p'. (FilePartyI p, FilePartyI p') => t p' -> Either String (t p)
checkParty c = case testEquality (sFileParty @p) (sFileParty @p') of
  Just Refl -> Right c
  Nothing -> Left "bad command party"

checkParty' :: forall t p p'. (FilePartyI p, FilePartyI p') => t p' -> Maybe (t p)
checkParty' c = case testEquality (sFileParty @p) (sFileParty @p') of
  Just Refl -> Just c
  _ -> Nothing
