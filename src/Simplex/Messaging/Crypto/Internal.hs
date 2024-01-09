{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}

module Simplex.Messaging.Crypto.Internal where

import Control.Exception (Exception)
import qualified Crypto.Cipher.XSalsa as XSalsa
import qualified Crypto.Error as CE
import qualified Crypto.MAC.Poly1305 as Poly1305
import Data.ByteArray (ByteArrayAccess)
import qualified Data.ByteArray as BA
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy as LB
import qualified Data.ByteString.Lazy.Internal as LB
import Data.List.NonEmpty (NonEmpty (..))
import Data.Word (Word32)

type SbState = (XSalsa.State, Poly1305.State)

type LazyByteString = LB.ByteString

cryptoBox' :: ByteArrayAccess key => key -> ByteString -> LazyByteString -> LazyByteString
cryptoBox' secret nonce s = LB.Chunk tag (LB.fromChunks cs)
  where
  (tag :| cs) = secretBox sbEncryptChunk secret nonce s

-- | NaCl @secret_box@ decrypt with a symmetric 256-bit key and 192-bit nonce.
-- The resulting string will be smaller than packet size by the size of the auth tag (16 bytes).
-- Unlike cbDecrypt' in Simplex.Messaging.Crypto, this function expects 8 bytes prefix as the length of the message.
sbDecrypt_' :: ByteArrayAccess key => (LazyByteString -> Either CryptoError LazyByteString) -> key -> ByteString -> LazyByteString -> Either CryptoError LazyByteString
sbDecrypt_' unPad secret nonce packet
  | LB.length tag' < 16 = Left CBDecryptError
  | BA.constEq (LB.toStrict tag') tag = unPad $ LB.fromChunks cs
  | otherwise = Left CBDecryptError
  where
    (tag :| cs) = secretBox sbDecryptChunk secret nonce c
    (tag', c) = LB.splitAt 16 packet

secretBox :: ByteArrayAccess key => (SbState -> ByteString -> (ByteString, SbState)) -> key -> ByteString -> LazyByteString -> NonEmpty ByteString
secretBox sbProcess secret nonce msg = BA.convert (sbAuth state') :| reverse cs
  where
    (!cs, !state') = secretBoxLazy_ sbProcess (sbInit_ secret nonce) msg

-- passes lazy bytestring via initialized secret box returning the reversed list of chunks
secretBoxLazy_ :: (SbState -> ByteString -> (ByteString, SbState)) -> SbState -> LazyByteString -> ([ByteString], SbState)
secretBoxLazy_ sbProcess state = LB.foldlChunks update ([], state)
  where
    update (cs, st) chunk = let (!c, !st') = sbProcess st chunk in (c : cs, st')

sbInit_ :: ByteArrayAccess key => key -> ByteString -> SbState
sbInit_ secret nonce = (state2, cantFail $ Poly1305.initialize rs)
  where
    zero = B.replicate 16 $ toEnum 0
    (iv0, iv1) = B.splitAt 8 nonce
    state0 = XSalsa.initialize 20 secret (zero `B.append` iv0)
    state1 = XSalsa.derive state0 iv1
    (rs :: ByteString, state2) = XSalsa.generate state1 32
    -- Poly1305.initialize can only fail if key size is different from 32
    -- https://hackage.haskell.org/package/crypton-0.34/docs/src/Crypto.MAC.Poly1305.html#initialize
    -- https://github.com/kazu-yamamoto/crypton/issues/28
    cantFail :: CE.CryptoFailable b -> b
    cantFail = \case
      CE.CryptoPassed a -> a
      CE.CryptoFailed e -> error $ "key size is different from 32" <> show e

sbEncryptChunk :: SbState -> ByteString -> (ByteString, SbState)
sbEncryptChunk (st, authSt) chunk =
  let (!c, !st') = XSalsa.combine st chunk
      !authSt' = Poly1305.update authSt c
   in (c, (st', authSt'))

sbDecryptChunk :: SbState -> ByteString -> (ByteString, SbState)
sbDecryptChunk (st, authSt) chunk =
  let (!s, !st') = XSalsa.combine st chunk
      !authSt' = Poly1305.update authSt chunk
   in (s, (st', authSt'))

sbAuth :: SbState -> Poly1305.Auth
sbAuth = Poly1305.finalize . snd
{-# INLINE sbAuth #-}

-- | Various cryptographic or related errors.
data CryptoError
  = -- | AES initialization error
    AESCipherError CE.CryptoError
  | -- | IV generation error
    CryptoIVError
  | -- | AES decryption error
    AESDecryptError
  | -- CryptoBox decryption error
    CBDecryptError
  | -- | message is larger that allowed padded length minus 2 (to prepend message length)
    -- (or required un-padded length is larger than the message length)
    CryptoLargeMsgError
  | -- | padded message is shorter than 2 bytes
    CryptoInvalidMsgError
  | -- | failure parsing message header
    CryptoHeaderError String
  | -- | no sending chain key in ratchet state
    CERatchetState
  | -- | header decryption error (could indicate that another key should be tried)
    CERatchetHeader
  | -- | too many skipped messages
    CERatchetTooManySkipped Word32
  | -- | earlier message number (or, possibly, skipped message that failed to decrypt?)
    CERatchetEarlierMessage Word32
  | -- | duplicate message number
    CERatchetDuplicateMessage
  deriving (Eq, Show, Exception)
