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

import Data.Bifunctor (first)
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Kind (Type)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Maybe (isNothing)
import Data.Type.Equality
import Data.Word (Word32)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Notifications.Transport (ntfClientHandshake)
import Simplex.Messaging.Protocol
  ( CommandError (..),
    ErrorType (..),
    Protocol (..),
    ProtocolEncoding (..),
    ProtocolMsgTag (..),
    ProtocolType (..),
    RcvPublicDhKey,
    RcvPublicVerifyKey,
    RecipientId,
    SenderId,
    SentRawTransmission,
    SignedTransmission,
    SndPublicVerifyKey,
    Transmission,
    encodeTransmission,
    messageTagP,
    tDecodeParseValidate,
    tEncode,
    tEncodeBatch,
    tParse,
    _smpP,
  )
import Simplex.Messaging.Transport (SessionId, TransportError (..))
import Simplex.Messaging.Util ((<$?>))
import Simplex.Messaging.Version

currentXFTPVersion :: Version
currentXFTPVersion = 1

xftpBlockSize :: Int
xftpBlockSize = 16384

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
  type ProtoType FileResponse = 'PXFTP
  protocolClientHandshake = ntfClientHandshake
  protocolPing = FileCmd SRecipient PING
  protocolError = \case
    FRErr e -> Just e
    _ -> Nothing

data FileCommand (p :: FileParty) where
  FNEW :: FileInfo -> NonEmpty RcvPublicVerifyKey -> FileCommand Sender
  FADD :: NonEmpty RcvPublicVerifyKey -> FileCommand Sender
  FPUT :: FileCommand Sender
  FDEL :: FileCommand Sender
  FGET :: RcvPublicDhKey -> FileCommand Recipient
  FACK :: FileCommand Recipient
  PING :: FileCommand Recipient

deriving instance Show (FileCommand p)

data FileCmd = forall p. FilePartyI p => FileCmd (SFileParty p) (FileCommand p)

deriving instance Show FileCmd

data FileInfo = FileInfo
  { sndKey :: SndPublicVerifyKey,
    size :: Word32,
    digest :: ByteString
  }
  deriving (Eq, Show)

type XFTPFileId = ByteString

instance FilePartyI p => ProtocolEncoding (FileCommand p) where
  type Tag (FileCommand p) = FileCommandTag p
  encodeProtocol _v = \case
    FNEW file rKeys -> e (FNEW_, ' ', file, rKeys)
    FADD rKeys -> e (FADD_, ' ', rKeys)
    FPUT -> e FPUT_
    FDEL -> e FDEL_
    FGET rKey -> e (FGET_, ' ', rKey)
    FACK -> e FACK_
    PING -> e PING_
    where
      e :: Encoding a => a -> ByteString
      e = smpEncode

  protocolP v tag = (\(FileCmd _ c) -> checkParty c) <$?> protocolP v (FCT (sFileParty @p) tag)

  checkCredentials (sig, _, fileId, _) cmd = case cmd of
    -- FNEW must not have signature and chunk ID
    FNEW {}
      | isNothing sig -> Left $ CMD NO_AUTH
      | not (B.null fileId) -> Left $ CMD HAS_AUTH
      | otherwise -> Right cmd
    PING
      | isNothing sig && B.null fileId -> Right cmd
      | otherwise -> Left $ CMD HAS_AUTH
    -- other client commands must have both signature and queue ID
    _
      | isNothing sig || B.null fileId -> Left $ CMD NO_AUTH
      | otherwise -> Right cmd

instance ProtocolEncoding FileCmd where
  type Tag FileCmd = FileCmdTag
  encodeProtocol _v (FileCmd _ c) = encodeProtocol _v c

  protocolP _v = \case
    FCT SSender tag ->
      FileCmd SSender <$> case tag of
        FNEW_ -> FNEW <$> _smpP <*> smpP
        FADD_ -> FADD <$> _smpP
        FPUT_ -> pure FPUT
        FDEL_ -> pure FDEL
    FCT SRecipient tag ->
      FileCmd SRecipient <$> case tag of
        FGET_ -> FGET <$> _smpP
        FACK_ -> pure FACK
        PING_ -> pure PING

  checkCredentials t (FileCmd p c) = FileCmd p <$> checkCredentials t c

instance Encoding FileInfo where
  smpEncode FileInfo {sndKey, size, digest} = smpEncode (sndKey, size, digest)
  smpP = FileInfo <$> smpP <*> smpP <*> smpP

instance StrEncoding FileInfo where
  strEncode FileInfo {sndKey, size, digest} = strEncode (sndKey, size, digest)
  strP = FileInfo <$> strP_ <*> strP_ <*> strP

data FileResponseTag
  = FRSndIds_
  | FRRcvIds_
  | FRFile_
  | FROk_
  | FRErr_
  | FRPong_
  deriving (Show)

instance Encoding FileResponseTag where
  smpEncode = \case
    FRSndIds_ -> "SIDS"
    FRRcvIds_ -> "RIDS"
    FRFile_ -> "FILE"
    FROk_ -> "OK"
    FRErr_ -> "ERR"
    FRPong_ -> "PONG"
  smpP = messageTagP

instance ProtocolMsgTag FileResponseTag where
  decodeTag = \case
    "SIDS" -> Just FRSndIds_
    "RIDS" -> Just FRRcvIds_
    "FILE" -> Just FRFile_
    "OK" -> Just FROk_
    "ERR" -> Just FRErr_
    "PONG" -> Just FRPong_
    _ -> Nothing

data FileResponse
  = FRSndIds SenderId (NonEmpty RecipientId)
  | FRRcvIds (NonEmpty RecipientId)
  | FRFile RcvPublicDhKey
  | FROk
  | FRErr ErrorType
  | FRPong
  deriving (Show)

instance ProtocolEncoding FileResponse where
  type Tag FileResponse = FileResponseTag
  encodeProtocol _v = \case
    FRSndIds fId rIds -> e (FRSndIds_, ' ', fId, rIds)
    FRRcvIds rIds -> e (FRRcvIds_, ' ', rIds)
    FRFile rKey -> e (FRFile_, ' ', rKey)
    FROk -> e FROk_
    FRErr err -> e (FRErr_, ' ', err)
    FRPong -> e FRPong_
    where
      e :: Encoding a => a -> ByteString
      e = smpEncode

  protocolP _v = \case
    FRSndIds_ -> FRSndIds <$> _smpP <*> smpP
    FRRcvIds_ -> FRRcvIds <$> _smpP
    FRFile_ -> FRFile <$> _smpP
    FROk_ -> pure FROk
    FRErr_ -> FRErr <$> _smpP
    FRPong_ -> pure FRPong

  checkCredentials (_, _, entId, _) cmd = case cmd of
    FRSndIds {} -> noEntity
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

checkParty :: forall t p p'. (FilePartyI p, FilePartyI p') => t p' -> Either String (t p)
checkParty c = case testEquality (sFileParty @p) (sFileParty @p') of
  Just Refl -> Right c
  Nothing -> Left "bad command party"

checkParty' :: forall t p p'. (FilePartyI p, FilePartyI p') => t p' -> Maybe (t p)
checkParty' c = case testEquality (sFileParty @p) (sFileParty @p') of
  Just Refl -> Just c
  _ -> Nothing

xftpEncodeTransmission :: ProtocolEncoding c => SessionId -> Maybe C.APrivateSignKey -> Transmission c -> Either TransportError ByteString
xftpEncodeTransmission sessionId pKey (corrId, fId, msg) = do
  let t = encodeTransmission currentXFTPVersion sessionId (corrId, fId, msg)
  xftpEncodeBatch1 $ signTransmission t
  where
    signTransmission :: ByteString -> SentRawTransmission
    signTransmission t = ((`C.sign` t) <$> pKey, t)

-- this function uses batch syntax but puts only one transmission in the batch
xftpEncodeBatch1 :: (Maybe C.ASignature, ByteString) -> Either TransportError ByteString
xftpEncodeBatch1 (sig, t) =
  let t' = tEncodeBatch 1 . smpEncode . Large $ tEncode (sig, t)
   in first (const TELargeMsg) $ C.pad t' xftpBlockSize

xftpDecodeTransmission :: ProtocolEncoding c => SessionId -> ByteString -> Either ErrorType (SignedTransmission c)
xftpDecodeTransmission sessionId t = do
  t' <- first (const LARGE_MSG) $ C.unPad t
  case tParse True t' of
    t'' :| [] -> Right $ tDecodeParseValidate sessionId currentXFTPVersion t''
    _ -> Left BLOCK
