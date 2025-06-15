{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}

module Simplex.Messaging.Crypto.ShortLink
  ( contactShortLinkKdf,
    invShortLinkKdf,
    encodeSignLinkData,
    encodeSignUserData,
    encryptLinkData,
    encryptUserData,
    decryptLinkData,
  )
where

import Control.Concurrent.STM
import Control.Monad.Except
import Control.Monad.IO.Class
import Crypto.Random (ChaChaDRG)
import Data.Bifunctor (first)
import Data.Bitraversable (bimapM)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Simplex.Messaging.Agent.Client (cryptoError)
import Simplex.Messaging.Agent.Protocol
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding
import Simplex.Messaging.Protocol (EntityId (..), LinkId, EncDataBytes (..), QueueLinkData)
import Simplex.Messaging.Util (liftEitherWith)

fixedDataPaddedLength :: Int
fixedDataPaddedLength = 2008 -- 2048 - 24 (nonce) - 16 (auth tag)

userDataPaddedLength :: Int
userDataPaddedLength = 13784 -- 13824 - 24 - 16

contactShortLinkKdf :: LinkKey -> (LinkId, C.SbKey)
contactShortLinkKdf (LinkKey k) =
  let (lnkId, sbKey) = B.splitAt 24 $ C.hkdf "" k "SimpleXContactLink" 56
   in (EntityId lnkId, C.unsafeSbKey sbKey)

invShortLinkKdf :: LinkKey -> C.SbKey
invShortLinkKdf (LinkKey k) = C.unsafeSbKey $ C.hkdf "" k "SimpleXInvLink" 32

encodeSignLinkData :: forall c. ConnectionModeI c => C.KeyPairEd25519 -> VersionRangeSMPA -> ConnectionRequestUri c -> ConnInfo -> (LinkKey, (ByteString, ByteString))
encodeSignLinkData (rootKey, pk) agentVRange connReq userData =
  let fd = smpEncode FixedLinkData {agentVRange, rootKey, connReq}
      md = smpEncode $ connLinkData @c agentVRange userData
   in (LinkKey (C.sha3_256 fd), (encodeSign pk fd, encodeSign pk md))

encodeSignUserData :: forall c. ConnectionModeI c => SConnectionMode c -> C.PrivateKeyEd25519 -> VersionRangeSMPA -> ConnInfo -> ByteString
encodeSignUserData _ pk agentVRange userData =
  encodeSign pk $ smpEncode $ connLinkData @c agentVRange userData

connLinkData :: forall c. ConnectionModeI c => VersionRangeSMPA -> ConnInfo -> ConnLinkData c
connLinkData agentVRange userData = case sConnectionMode @c of
  SCMInvitation -> InvitationLinkData agentVRange userData
  SCMContact -> ContactLinkData {agentVRange, direct = True, owners = [], relays = [], userData}

encodeSign :: C.PrivateKeyEd25519 -> ByteString -> ByteString
encodeSign pk s = smpEncode (C.sign' pk s) <> s

encryptLinkData :: TVar ChaChaDRG -> C.SbKey -> (ByteString, ByteString) -> ExceptT AgentErrorType IO QueueLinkData
encryptLinkData g k = bimapM (encrypt fixedDataPaddedLength) (encrypt userDataPaddedLength)
  where
    encrypt len = encryptData g k len

encryptUserData :: TVar ChaChaDRG -> C.SbKey -> ByteString -> ExceptT AgentErrorType IO EncDataBytes
encryptUserData g k s = encryptData g k userDataPaddedLength s

encryptData :: TVar ChaChaDRG -> C.SbKey -> Int -> ByteString -> ExceptT AgentErrorType IO EncDataBytes
encryptData g k len s = do
  nonce <- liftIO $ atomically $ C.randomCbNonce g
  ct <- liftEitherWith cryptoError $ C.sbEncrypt k nonce s len
  pure $ EncDataBytes $ smpEncode nonce <> ct

decryptLinkData :: forall c. ConnectionModeI c => LinkKey -> C.SbKey -> QueueLinkData -> Either AgentErrorType (ConnectionRequestUri c, ConnLinkData c)
decryptLinkData linkKey k (encFD, encMD) = do
  (sig1, fd) <- decrypt encFD
  (sig2, md) <- decrypt encMD
  FixedLinkData {rootKey, connReq} <- decode fd
  md' <- decode @(ConnLinkData c) md
  if
    | LinkKey (C.sha3_256 fd) /= linkKey -> linkErr "link data hash"
    | not (C.verify' rootKey sig1 fd) -> linkErr "link data signature"
    | not (C.verify' rootKey sig2 md) -> linkErr "user data signature"
    | otherwise -> Right (connReq, md')
  where
    decrypt (EncDataBytes d) = do
      (nonce, Tail ct) <- decode d
      (sig, Tail s) <- decode =<< first cryptoError (C.sbDecrypt k nonce ct)
      pure (sig, s)
    decode :: Encoding a => ByteString -> Either AgentErrorType a
    decode = msgErr . smpDecode
    msgErr = first (const $ AGENT A_MESSAGE)
    linkErr = Left . AGENT . A_LINK
