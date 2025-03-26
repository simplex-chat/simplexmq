{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}

module Simplex.Messaging.Crypto.ShortLink where

import Control.Concurrent.STM
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

contactShortLinkKdf :: LinkKey -> (LinkId, C.SbKey)
contactShortLinkKdf (LinkKey k) =
  let (lnkId, sbKey) = B.splitAt 24 $ C.hkdf "" k "SimpleXContactLink" 56
   in (EntityId lnkId, C.unsafeSbKey sbKey)

invShortLinkKdf :: LinkKey -> C.SbKey
invShortLinkKdf (LinkKey k) = C.unsafeSbKey $ C.hkdf "" k "SimpleXInvLink" 32

encodeSignLinkData :: ConnectionModeI c => C.KeyPair 'C.Ed25519 -> VersionRangeSMPA -> ConnectionRequestUri c -> ConnInfo -> (LinkKey, (ByteString, ByteString))
encodeSignLinkData (sigKey, pk) agentVRange connReq userData =
  let fd = smpEncode FixedLinkData {agentVRange, sigKey, connReq}
      ud = smpEncode UserLinkData {agentVRange, userData}
   in (LinkKey (C.sha3_256 fd), (sign fd, sign ud))
  where
    sign s = smpEncode (C.signatureBytes $ C.sign' pk s) <> s

-- TODO [short links] possibly use padded encryption for fixed and for user data
encryptLinkData :: TVar ChaChaDRG -> C.SbKey -> (ByteString, ByteString) -> IO QueueLinkData
encryptLinkData g k = bimapM encrypt encrypt
  where
    encrypt s = do
      nonce <- atomically $ C.randomCbNonce g
      pure $ EncDataBytes $ smpEncode nonce <> C.sbEncryptNoPad k nonce s

decryptLinkData :: ConnectionModeI c => LinkKey -> C.SbKey -> QueueLinkData -> Either AgentErrorType (ConnectionRequestUri c, ConnInfo)
decryptLinkData linkKey k (encFD, encUD) = do
  (sig1, fd) <- decrypt encFD
  (sig2, ud) <- decrypt encUD
  FixedLinkData {sigKey, connReq} <- decode fd
  UserLinkData {userData} <- decode ud
  if
    | LinkKey (C.sha3_256 fd) /= linkKey -> linkErr "link data hash"
    | not (C.verify' sigKey sig1 fd) -> linkErr "link data signature"
    | not (C.verify' sigKey sig2 ud) -> linkErr "user data signature"
    | otherwise -> Right (connReq, userData)
  where
    decrypt (EncDataBytes d) = do
      (nonce, Tail ct) <- decode d
      (sigBytes, Tail s) <- decode =<< first cryptoError (C.sbDecryptNoPad k nonce ct)
      (,s) <$> msgErr (C.decodeSignature sigBytes)
    decode :: Encoding a => ByteString -> Either AgentErrorType a
    decode = msgErr . smpDecode
    msgErr = first (const $ AGENT A_MESSAGE)
    linkErr = Left . AGENT . A_LINK
