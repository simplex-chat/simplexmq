{-# LANGUAGE GADTs #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}

module Simplex.Messaging.Crypto.Lazy
  ( sha256Hash,
    sha512Hash,
    sign,
    pad,
    unPad,
    splitLen,
    sbEncrypt,
    sbDecrypt,
    sbEncryptTailTag,
    kcbEncryptTailTag,
    sbDecryptTailTag,
    kcbDecryptTailTag,
    fastReplicate,
    secretBox,
    secretBoxTailTag,
    SbState,
    cbInit,
    sbInit,
    kcbInit,
    sbEncryptChunk,
    sbDecryptChunk,
    sbEncryptChunkLazy,
    sbDecryptChunkLazy,
    sbAuth,
    LazyByteString,
  )
where

import Crypto.Hash (Digest, hashlazy)
import Crypto.Hash.Algorithms (SHA256, SHA512)
import Data.Bifunctor (first)
import Data.ByteArray (ByteArrayAccess)
import qualified Data.ByteArray as BA
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy.Char8 as LB
import Data.Composition ((.:.))
import Data.Int (Int64)
import Data.List.NonEmpty (NonEmpty (..))
import Foreign (sizeOf)
import Simplex.Messaging.Crypto (APrivateSignKey (..), ASignature, CbNonce, DhSecret (..), DhSecretX25519, SbKey, pattern CbNonce, pattern SbKey)
import Simplex.Messaging.Crypto.Internal
import Simplex.Messaging.Crypto.SNTRUP761 (KEMHybridSecret (..))
import Simplex.Messaging.Encoding

-- | SHA512 digest of a lazy bytestring.
sha256Hash :: LazyByteString -> ByteString
sha256Hash = BA.convert . (hashlazy :: LazyByteString -> Digest SHA256)
{-# INLINE sha256Hash #-}

-- | SHA512 digest of a lazy bytestring.
sha512Hash :: LazyByteString -> ByteString
sha512Hash = BA.convert . (hashlazy :: LazyByteString -> Digest SHA512)
{-# INLINE sha512Hash #-}

sign :: APrivateSignKey -> LazyByteString -> ASignature
sign (APrivateSignKey _a _k) _ = undefined

-- this function does not validate the length of the message to avoid consuming all chunks,
-- but if the passed string is longer it will truncate it to specified length
pad :: LazyByteString -> Int64 -> Int64 -> Either CryptoError LazyByteString
pad msg len paddedLen
  | padLen >= 0 = Right $ LB.fromStrict encodedLen <> LB.take len msg <> fastReplicate padLen '#'
  | otherwise = Left CryptoLargeMsgError
  where
    encodedLen = smpEncode len -- 8 bytes Int64 encoded length
    padLen = paddedLen - len - 8

fastReplicate :: Int64 -> Char -> LazyByteString
fastReplicate n c
  | n <= 0 = LB.empty
  | n < chSize' = LB.fromStrict $ B.replicate (fromIntegral n) c
  | otherwise = LB.fromChunks $ B.replicate (fromIntegral r) c : replicate (fromIntegral q) chPad
  where
    chSize = 65536 - 2 * sizeOf (undefined :: Int)
    chPad = B.replicate chSize c
    chSize' = fromIntegral chSize
    (q, r) = quotRem n chSize'

-- this function does not validate the length of the message to avoid consuming all chunks,
-- so it can return a shorter string than expected
unPad :: LazyByteString -> Either CryptoError LazyByteString
unPad = fmap snd . splitLen
{-# INLINE unPad #-}

splitLen :: LazyByteString -> Either CryptoError (Int64, LazyByteString)
splitLen padded
  | LB.length lenStr == 8 = case smpDecode $ LB.toStrict lenStr of
      Right len
        | len < 0 -> Left CryptoInvalidMsgError
        | otherwise -> Right (len, LB.take len rest)
      Left _ -> Left CryptoInvalidMsgError
  | otherwise = Left CryptoInvalidMsgError
  where
    (lenStr, rest) = LB.splitAt 8 padded

-- | NaCl @secret_box@ lazy encrypt with a symmetric 256-bit key and 192-bit nonce.
-- The resulting string will be bigger than paddedLen by the size of the auth tag (16 bytes).
-- Unlike cbEncrypt' in Simplex.Messaging.Crypto, this function prepends 8 bytes (the length of the message).
sbEncrypt :: SbKey -> CbNonce -> LazyByteString -> Int64 -> Int64 -> Either CryptoError LazyByteString
sbEncrypt (SbKey key) (CbNonce nonce) msg len paddedLen =
  cryptoBox' key nonce <$> pad msg len paddedLen

-- | NaCl @secret_box@ decrypt with a symmetric 256-bit key and 192-bit nonce.
-- The resulting string will be smaller than packet size by the size of the auth tag (16 bytes).
-- Unlike cbDecrypt' in Simplex.Messaging.Crypto, this function expects 8 bytes prefix as the length of the message.
sbDecrypt :: SbKey -> CbNonce -> LazyByteString -> Either CryptoError LazyByteString
sbDecrypt (SbKey key) (CbNonce nonce) = sbDecrypt_' unPad key nonce
{-# INLINE sbDecrypt #-}

-- | NaCl @secret_box@ lazy encrypt with a symmetric 256-bit key and 192-bit nonce with appended auth tag (more efficient with large files).
sbEncryptTailTag :: SbKey -> CbNonce -> LazyByteString -> Int64 -> Int64 -> Either CryptoError LazyByteString
sbEncryptTailTag (SbKey key) = sbEncryptTailTag_ key
{-# INLINE sbEncryptTailTag #-}

-- | NaCl @crypto_box@ lazy encrypt with with a shared hybrid KEM+DH 256-bit secret and 192-bit nonce with appended auth tag (more efficient with large strings/files).
kcbEncryptTailTag :: KEMHybridSecret -> CbNonce -> LazyByteString -> Int64 -> Int64 -> Either CryptoError LazyByteString
kcbEncryptTailTag (KEMHybridSecret key) = sbEncryptTailTag_ key
{-# INLINE kcbEncryptTailTag #-}

sbEncryptTailTag_ :: ByteArrayAccess key => key -> CbNonce -> LazyByteString -> Int64 -> Int64 -> Either CryptoError LazyByteString
sbEncryptTailTag_ key (CbNonce nonce) msg len paddedLen =
  LB.fromChunks . secretBoxTailTag sbEncryptChunk key nonce <$> pad msg len paddedLen

-- | NaCl @secret_box@ decrypt with a symmetric 256-bit key and 192-bit nonce with appended auth tag (more efficient with large files).
-- paddedLen should NOT include the tag length, it should be the same number that is passed to sbEncrypt / sbEncryptTailTag.
sbDecryptTailTag :: SbKey -> CbNonce -> Int64 -> LazyByteString -> Either CryptoError (Bool, LazyByteString)
sbDecryptTailTag (SbKey key) = sbDecryptTailTag_ key
{-# INLINE sbDecryptTailTag #-}

-- | NaCl @crypto_box@ lazy decrypt with a shared hybrid KEM+DH 256-bit secret and 192-bit nonce with appended auth tag (more efficient with large strings/files).
-- paddedLen should NOT include the tag length, it should be the same number that is passed to sbEncrypt / sbEncryptTailTag.
kcbDecryptTailTag :: KEMHybridSecret -> CbNonce -> Int64 -> LazyByteString -> Either CryptoError (Bool, LazyByteString)
kcbDecryptTailTag (KEMHybridSecret key) = sbDecryptTailTag_ key
{-# INLINE kcbDecryptTailTag #-}

-- paddedLen should NOT include the tag length, it should be the same number that is passed to sbEncrypt / sbEncryptTailTag.
sbDecryptTailTag_ :: ByteArrayAccess key => key -> CbNonce -> Int64 -> LazyByteString -> Either CryptoError (Bool, LazyByteString)
sbDecryptTailTag_ key (CbNonce nonce) paddedLen packet =
  (valid,) <$> unPad (LB.fromChunks cs)
  where
    valid = LB.length tag' == 16 && BA.constEq (LB.toStrict tag') tag
    (tag :| cs) = secretBox sbDecryptChunk key nonce c
    (c, tag') = LB.splitAt paddedLen packet

secretBoxTailTag :: ByteArrayAccess key => (SbState -> ByteString -> (ByteString, SbState)) -> key -> ByteString -> LazyByteString -> [ByteString]
secretBoxTailTag sbProcess secret nonce msg = reverse $ BA.convert (sbAuth state') : cs
  where
    (cs, state') = secretBoxLazy_ sbProcess (sbInit_ secret nonce) msg

cbInit :: DhSecretX25519 -> CbNonce -> SbState
cbInit (DhSecretX25519 secret) (CbNonce nonce) = sbInit_ secret nonce
{-# INLINE cbInit #-}

sbInit :: SbKey -> CbNonce -> SbState
sbInit (SbKey secret) (CbNonce nonce) = sbInit_ secret nonce
{-# INLINE sbInit #-}

kcbInit :: KEMHybridSecret -> CbNonce -> SbState
kcbInit (KEMHybridSecret k) (CbNonce nonce) = sbInit_ k nonce
{-# INLINE kcbInit #-}

sbEncryptChunkLazy :: SbState -> LazyByteString -> (LazyByteString, SbState)
sbEncryptChunkLazy = sbProcessChunkLazy_ sbEncryptChunk
{-# INLINE sbEncryptChunkLazy #-}

sbDecryptChunkLazy :: SbState -> LazyByteString -> (LazyByteString, SbState)
sbDecryptChunkLazy = sbProcessChunkLazy_ sbDecryptChunk
{-# INLINE sbDecryptChunkLazy #-}

sbProcessChunkLazy_ :: (SbState -> ByteString -> (ByteString, SbState)) -> SbState -> LazyByteString -> (LazyByteString, SbState)
sbProcessChunkLazy_ = first (LB.fromChunks . reverse) .:. secretBoxLazy_
{-# INLINE sbProcessChunkLazy_ #-}
