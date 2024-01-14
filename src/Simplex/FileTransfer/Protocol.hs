{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# OPTIONS_GHC -fno-warn-unticked-promoted-constructors #-}

module Simplex.FileTransfer.Protocol where

import Control.Applicative ((<|>))
import qualified Data.Aeson.TH as J
import qualified Data.Attoparsec.ByteString.Char8 as A
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
import Simplex.Messaging.Parsers
import Simplex.Messaging.Protocol
  ( BasicAuth,
    CommandError (..),
    Protocol (..),
    ProtocolEncoding (..),
    ProtocolErrorType (..),
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
  )
import Simplex.Messaging.Transport (SessionId, TransportError (..))
import Simplex.Messaging.Util (bshow, (<$?>))
import Simplex.Messaging.Version

currentXFTPVersion :: Version
currentXFTPVersion = 1

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

instance Protocol XFTPErrorType FileResponse where
  type ProtoCommand FileResponse = FileCmd
  type ProtoType FileResponse = 'PXFTP
  protocolClientHandshake = ntfClientHandshake
  protocolPing = FileCmd SFRecipient PING
  protocolError = \case
    FRErr e -> Just e
    _ -> Nothing

data FileCommand (p :: FileParty) where
  FNEW :: FileInfo -> NonEmpty RcvPublicVerifyKey -> Maybe BasicAuth -> FileCommand FSender
  FADD :: NonEmpty RcvPublicVerifyKey -> FileCommand FSender
  FPUT :: FileCommand FSender
  FDEL :: FileCommand FSender
  FGET :: RcvPublicDhKey -> FileCommand FRecipient
  FACK :: FileCommand FRecipient
  PING :: FileCommand FRecipient

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

instance FilePartyI p => ProtocolEncoding XFTPErrorType (FileCommand p) where
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

  fromProtocolError = fromProtocolError @XFTPErrorType @FileResponse
  {-# INLINE fromProtocolError #-}

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

instance ProtocolEncoding XFTPErrorType FileCmd where
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

  fromProtocolError = fromProtocolError @XFTPErrorType @FileResponse
  {-# INLINE fromProtocolError #-}

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
  | FRFile RcvPublicDhKey C.CbNonce
  | FROk
  | FRErr XFTPErrorType
  | FRPong
  deriving (Show)

instance ProtocolEncoding XFTPErrorType FileResponse where
  type Tag FileResponse = FileResponseTag
  encodeProtocol _v = \case
    FRSndIds fId rIds -> e (FRSndIds_, ' ', fId, rIds)
    FRRcvIds rIds -> e (FRRcvIds_, ' ', rIds)
    FRFile rDhKey nonce -> e (FRFile_, ' ', rDhKey, nonce)
    FROk -> e FROk_
    FRErr err -> e (FRErr_, ' ', err)
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

data XFTPErrorType
  = -- | incorrect block format, encoding or signature size
    BLOCK
  | -- | incorrect SMP session ID (TLS Finished message / tls-unique binding RFC5929)
    SESSION
  | -- | SMP command is unknown or has invalid syntax
    CMD {cmdErr :: CommandError}
  | -- | command authorization error - bad signature or non-existing SMP queue
    AUTH
  | -- | incorrent file size
    SIZE
  | -- | storage quota exceeded
    QUOTA
  | -- | incorrent file digest
    DIGEST
  | -- | file encryption/decryption failed
    CRYPTO
  | -- | no expected file body in request/response or no file on the server
    NO_FILE
  | -- | unexpected file body
    HAS_FILE
  | -- | file IO error
    FILE_IO
  | -- | internal server error
    INTERNAL
  | -- | used internally, never returned by the server (to be removed)
    DUPLICATE_ -- not part of SMP protocol, used internally
  deriving (Eq, Read, Show)

instance StrEncoding XFTPErrorType where
  strEncode = \case
    CMD e -> "CMD " <> bshow e
    e -> bshow e
  strP = "CMD " *> (CMD <$> parseRead1) <|> parseRead1

instance Encoding XFTPErrorType where
  smpEncode = \case
    BLOCK -> "BLOCK"
    SESSION -> "SESSION"
    CMD err -> "CMD " <> smpEncode err
    AUTH -> "AUTH"
    SIZE -> "SIZE"
    QUOTA -> "QUOTA"
    DIGEST -> "DIGEST"
    CRYPTO -> "CRYPTO"
    NO_FILE -> "NO_FILE"
    HAS_FILE -> "HAS_FILE"
    FILE_IO -> "FILE_IO"
    INTERNAL -> "INTERNAL"
    DUPLICATE_ -> "DUPLICATE_"

  smpP =
    A.takeTill (== ' ') >>= \case
      "BLOCK" -> pure BLOCK
      "SESSION" -> pure SESSION
      "CMD" -> CMD <$> _smpP
      "AUTH" -> pure AUTH
      "SIZE" -> pure SIZE
      "QUOTA" -> pure QUOTA
      "DIGEST" -> pure DIGEST
      "CRYPTO" -> pure CRYPTO
      "NO_FILE" -> pure NO_FILE
      "HAS_FILE" -> pure HAS_FILE
      "FILE_IO" -> pure FILE_IO
      "INTERNAL" -> pure INTERNAL
      "DUPLICATE_" -> pure DUPLICATE_
      _ -> fail "bad error type"

checkParty :: forall t p p'. (FilePartyI p, FilePartyI p') => t p' -> Either String (t p)
checkParty c = case testEquality (sFileParty @p) (sFileParty @p') of
  Just Refl -> Right c
  Nothing -> Left "incorrect XFTP party"

checkParty' :: forall t p p'. (FilePartyI p, FilePartyI p') => t p' -> Maybe (t p)
checkParty' c = case testEquality (sFileParty @p) (sFileParty @p') of
  Just Refl -> Just c
  _ -> Nothing

xftpEncodeTransmission :: ProtocolEncoding e c => SessionId -> Maybe C.APrivateSignKey -> Transmission c -> Either TransportError ByteString
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

xftpDecodeTransmission :: ProtocolEncoding e c => SessionId -> ByteString -> Either XFTPErrorType (SignedTransmission e c)
xftpDecodeTransmission sessionId t = do
  t' <- first (const BLOCK) $ C.unPad t
  case tParse True t' of
    t'' :| [] -> Right $ tDecodeParseValidate sessionId currentXFTPVersion t''
    _ -> Left BLOCK

$(J.deriveJSON (enumJSON $ dropPrefix "F") ''FileParty)

$(J.deriveJSON (sumTypeJSON id) ''XFTPErrorType)
