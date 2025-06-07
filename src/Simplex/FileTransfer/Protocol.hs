{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# OPTIONS_GHC -fno-warn-unticked-promoted-constructors #-}

module Simplex.FileTransfer.Protocol where

import qualified Data.Aeson.TH as J
import Data.Bifunctor (first)
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Kind (Type)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Maybe (isNothing)
import Data.Type.Equality
import Data.Word (Word32)
import Simplex.FileTransfer.Transport (XFTPErrorType (..), XFTPVersion, blockedFilesXFTPVersion, xftpClientHandshakeStub)
import Simplex.Messaging.Client (authTransmission)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Parsers
import Simplex.Messaging.Protocol
  ( BasicAuth,
    CommandError (..),
    Protocol (..),
    ProtocolEncoding (..),
    ProtocolErrorType (..),
    ProtocolMsgTag (..),
    ProtocolType (..),
    RcvPublicAuthKey,
    RcvPublicDhKey,
    EntityId (..),
    RecipientId,
    SenderId,
    SentRawTransmission,
    SignedTransmissionOrError,
    SndPublicAuthKey,
    Transmission,
    TransmissionForAuth (..),
    CorrId (..),
    encodeTransmission,
    encodeTransmissionForAuth,
    messageTagP,
    tDecodeParseValidate,
    tEncodeBatch1,
    tParse,
  )
import Simplex.Messaging.Transport (THandleParams (..), TransportError (..), TransportPeer (..))
import Simplex.Messaging.Util ((<$?>))

xftpBlockSize :: Int
xftpBlockSize = 16384

-- | File protocol clients
data FileParty = FRecipient | FSender
  deriving (Eq, Show)

data SFileParty :: FileParty -> Type where
  SFRecipient :: SFileParty FRecipient
  SFSender :: SFileParty FSender

instance TestEquality SFileParty where
  testEquality SFRecipient SFRecipient = Just Refl
  testEquality SFSender SFSender = Just Refl
  testEquality _ _ = Nothing

deriving instance Eq (SFileParty p)

deriving instance Show (SFileParty p)

data AFileParty = forall p. FilePartyI p => AFP (SFileParty p)

toFileParty :: SFileParty p -> FileParty
toFileParty = \case
  SFRecipient -> FRecipient
  SFSender -> FSender

aFileParty :: FileParty -> AFileParty
aFileParty = \case
  FRecipient -> AFP SFRecipient
  FSender -> AFP SFSender

class FilePartyI (p :: FileParty) where sFileParty :: SFileParty p

instance FilePartyI FRecipient where sFileParty = SFRecipient

instance FilePartyI FSender where sFileParty = SFSender

data FileCommandTag (p :: FileParty) where
  FNEW_ :: FileCommandTag FSender
  FADD_ :: FileCommandTag FSender
  FPUT_ :: FileCommandTag FSender
  FDEL_ :: FileCommandTag FSender
  FGET_ :: FileCommandTag FRecipient
  FACK_ :: FileCommandTag FRecipient
  PING_ :: FileCommandTag FRecipient

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
    "FNEW" -> Just $ FCT SFSender FNEW_
    "FADD" -> Just $ FCT SFSender FADD_
    "FPUT" -> Just $ FCT SFSender FPUT_
    "FDEL" -> Just $ FCT SFSender FDEL_
    "FGET" -> Just $ FCT SFRecipient FGET_
    "FACK" -> Just $ FCT SFRecipient FACK_
    "PING" -> Just $ FCT SFRecipient PING_
    _ -> Nothing

instance FilePartyI p => ProtocolMsgTag (FileCommandTag p) where
  decodeTag s = decodeTag s >>= (\(FCT _ t) -> checkParty' t)

instance Protocol XFTPVersion XFTPErrorType FileResponse where
  type ProtoCommand FileResponse = FileCmd
  type ProtoType FileResponse = 'PXFTP
  protocolClientHandshake = xftpClientHandshakeStub
  {-# INLINE protocolClientHandshake #-}
  useServiceAuth _ = False
  {-# INLINE useServiceAuth #-}
  protocolPing = FileCmd SFRecipient PING
  {-# INLINE protocolPing #-}
  protocolError = \case
    FRErr e -> Just e
    _ -> Nothing
  {-# INLINE protocolError #-}

data FileCommand (p :: FileParty) where
  FNEW :: FileInfo -> NonEmpty RcvPublicAuthKey -> Maybe BasicAuth -> FileCommand FSender
  FADD :: NonEmpty RcvPublicAuthKey -> FileCommand FSender
  FPUT :: FileCommand FSender
  FDEL :: FileCommand FSender
  FGET :: RcvPublicDhKey -> FileCommand FRecipient
  FACK :: FileCommand FRecipient
  PING :: FileCommand FRecipient

deriving instance Show (FileCommand p)

data FileCmd = forall p. FilePartyI p => FileCmd (SFileParty p) (FileCommand p)

deriving instance Show FileCmd

data FileInfo = FileInfo
  { sndKey :: SndPublicAuthKey,
    size :: Word32,
    digest :: ByteString
  }
  deriving (Show)

type XFTPFileId = EntityId

instance FilePartyI p => ProtocolEncoding XFTPVersion XFTPErrorType (FileCommand p) where
  type Tag (FileCommand p) = FileCommandTag p
  encodeProtocol _v = \case
    FNEW file rKeys auth_ -> e (FNEW_, ' ', file, rKeys, auth_)
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

  fromProtocolError = fromProtocolError @XFTPVersion @XFTPErrorType @FileResponse
  {-# INLINE fromProtocolError #-}

  checkCredentials auth (EntityId fileId) cmd = case cmd of
    -- FNEW must not have signature and chunk ID
    FNEW {}
      | isNothing auth -> Left $ CMD NO_AUTH
      | not (B.null fileId) -> Left $ CMD HAS_AUTH
      | otherwise -> Right cmd
    PING
      | isNothing auth && B.null fileId -> Right cmd
      | otherwise -> Left $ CMD HAS_AUTH
    -- other client commands must have both signature and queue ID
    _
      | isNothing auth || B.null fileId -> Left $ CMD NO_AUTH
      | otherwise -> Right cmd

instance ProtocolEncoding XFTPVersion XFTPErrorType FileCmd where
  type Tag FileCmd = FileCmdTag
  encodeProtocol _v (FileCmd _ c) = encodeProtocol _v c

  protocolP _v = \case
    FCT SFSender tag ->
      FileCmd SFSender <$> case tag of
        FNEW_ -> FNEW <$> _smpP <*> smpP <*> smpP
        FADD_ -> FADD <$> _smpP
        FPUT_ -> pure FPUT
        FDEL_ -> pure FDEL
    FCT SFRecipient tag ->
      FileCmd SFRecipient <$> case tag of
        FGET_ -> FGET <$> _smpP
        FACK_ -> pure FACK
        PING_ -> pure PING

  fromProtocolError = fromProtocolError @XFTPVersion @XFTPErrorType @FileResponse
  {-# INLINE fromProtocolError #-}

  checkCredentials tAuth entId (FileCmd p c) = FileCmd p <$> checkCredentials tAuth entId c
  {-# INLINE checkCredentials #-}

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
  | FRFile RcvPublicDhKey C.CbNonce
  | FROk
  | FRErr XFTPErrorType
  | FRPong
  deriving (Show)

instance ProtocolEncoding XFTPVersion XFTPErrorType FileResponse where
  type Tag FileResponse = FileResponseTag
  encodeProtocol v = \case
    FRSndIds fId rIds -> e (FRSndIds_, ' ', fId, rIds)
    FRRcvIds rIds -> e (FRRcvIds_, ' ', rIds)
    FRFile rDhKey nonce -> e (FRFile_, ' ', rDhKey, nonce)
    FROk -> e FROk_
    FRErr err -> case err of
      BLOCKED _ | v < blockedFilesXFTPVersion -> e (FRErr_, ' ', AUTH)
      _ -> e (FRErr_, ' ', err)
    FRPong -> e FRPong_
    where
      e :: Encoding a => a -> ByteString
      e = smpEncode

  protocolP _v = \case
    FRSndIds_ -> FRSndIds <$> _smpP <*> smpP
    FRRcvIds_ -> FRRcvIds <$> _smpP
    FRFile_ -> FRFile <$> _smpP <*> smpP
    FROk_ -> pure FROk
    FRErr_ -> FRErr <$> _smpP
    FRPong_ -> pure FRPong

  fromProtocolError = \case
    PECmdSyntax -> CMD SYNTAX
    PECmdUnknown -> CMD UNKNOWN
    PESession -> SESSION
    PEBlock -> BLOCK
  {-# INLINE fromProtocolError #-}

  checkCredentials _ (EntityId entId) cmd = case cmd of
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
  Nothing -> Left "incorrect XFTP party"

checkParty' :: forall t p p'. (FilePartyI p, FilePartyI p') => t p' -> Maybe (t p)
checkParty' c = case testEquality (sFileParty @p) (sFileParty @p') of
  Just Refl -> Just c
  _ -> Nothing

xftpEncodeAuthTransmission :: ProtocolEncoding XFTPVersion XFTPErrorType c => THandleParams XFTPVersion 'TClient -> C.APrivateAuthKey -> Transmission c -> Either TransportError ByteString
xftpEncodeAuthTransmission thParams@THandleParams {thAuth} pKey t@((corrId, _), _) = do
  let TransmissionForAuth {tForAuth, tToSend} = encodeTransmissionForAuth thParams t
  xftpEncodeBatch1 . (,tToSend) =<< authTransmission thAuth False (Just pKey) (C.cbNonce $ bs corrId) tForAuth

xftpEncodeTransmission :: ProtocolEncoding XFTPVersion XFTPErrorType c => THandleParams XFTPVersion p -> Transmission c -> Either TransportError ByteString
xftpEncodeTransmission thParams t = xftpEncodeBatch1 (Nothing, encodeTransmission thParams t)

-- this function uses batch syntax but puts only one transmission in the batch
xftpEncodeBatch1 :: SentRawTransmission -> Either TransportError ByteString
xftpEncodeBatch1 t = first (const TELargeMsg) $ C.pad (tEncodeBatch1 False t) xftpBlockSize

xftpDecodeTransmission :: ProtocolEncoding XFTPVersion XFTPErrorType c => THandleParams XFTPVersion p -> ByteString -> Either XFTPErrorType (SignedTransmissionOrError XFTPErrorType c)
xftpDecodeTransmission thParams t = do
  t' <- first (const BLOCK) $ C.unPad t
  case tParse thParams t' of
    t'' :| [] -> Right $ tDecodeParseValidate thParams t''
    _ -> Left BLOCK

$(J.deriveJSON (enumJSON $ dropPrefix "F") ''FileParty)
