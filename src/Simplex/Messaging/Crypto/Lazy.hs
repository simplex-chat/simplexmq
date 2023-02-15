{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE PatternSynonyms #-}

module Simplex.Messaging.Crypto.Lazy
  ( sha512Hash,
    pad,
    unPad,
    sbEncrypt,
    sbDecrypt,
    fastReplicate,
  )
where

import qualified Crypto.Cipher.XSalsa as XSalsa
import qualified Crypto.Error as CE
import Crypto.Hash (Digest, hashlazy)
import Crypto.Hash.Algorithms (SHA512)
import qualified Crypto.MAC.Poly1305 as Poly1305
import Data.ByteArray (ByteArrayAccess)
import qualified Data.ByteArray as BA
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy.Char8 as LB
import Data.Int (Int64)
import Foreign (sizeOf)
import Simplex.Messaging.Crypto (CbNonce, CryptoError (..), SbKey, pattern CbNonce, pattern SbKey)
import Simplex.Messaging.Encoding

type LazyByteString = LB.ByteString

-- | SHA512 digest of a lazy bytestring.
sha512Hash :: LazyByteString -> ByteString
sha512Hash = BA.convert . (hashlazy :: LazyByteString -> Digest SHA512)

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
unPad padded
  | LB.length lenStr == 8 = case smpDecode $ LB.toStrict lenStr of
    Right len
      | len < 0 -> Left CryptoInvalidMsgError
      | otherwise -> Right $ LB.take len rest
    Left _ -> Left CryptoInvalidMsgError
  | otherwise = Left CryptoInvalidMsgError
  where
    (lenStr, rest) = LB.splitAt 8 padded

-- | NaCl @secret_box@ lazy encrypt with a symmetric 256-bit key and 192-bit nonce.
sbEncrypt :: SbKey -> CbNonce -> LazyByteString -> Int64 -> Int64 -> Either CryptoError LazyByteString
sbEncrypt (SbKey key) = sbEncrypt_ key

sbEncrypt_ :: ByteArrayAccess key => key -> CbNonce -> LazyByteString -> Int64 -> Int64 -> Either CryptoError LazyByteString
sbEncrypt_ secret (CbNonce nonce) msg len paddedLen = cryptoBox secret nonce =<< pad msg len paddedLen

-- | NaCl @secret_box@ decrypt with a symmetric 256-bit key and 192-bit nonce.
sbDecrypt :: SbKey -> CbNonce -> LazyByteString -> Either CryptoError LazyByteString
sbDecrypt (SbKey key) = sbDecrypt_ key

-- | NaCl @crypto_box@ decrypt with a shared DH secret and 192-bit nonce.
sbDecrypt_ :: ByteArrayAccess key => key -> CbNonce -> LazyByteString -> Either CryptoError LazyByteString
sbDecrypt_ secret (CbNonce nonce) packet
  | LB.length tag' < 16 = Left CBDecryptError
  | otherwise = case poly1305auth rs c of
    Right tag
      | BA.constEq (LB.toStrict tag') tag -> unPad msg
      | otherwise -> Left CBDecryptError
    Left e -> Left e
  where
    (tag', c) = LB.splitAt 16 packet
    (rs, msg) = xSalsa20 secret nonce c

cryptoBox :: ByteArrayAccess key => key -> ByteString -> LazyByteString -> Either CryptoError LazyByteString
cryptoBox secret nonce s = (<> c) . LB.fromStrict . BA.convert <$> tag
  where
    (rs, c) = xSalsa20 secret nonce s
    tag = poly1305auth rs c

poly1305auth :: ByteString -> LazyByteString -> Either CryptoError Poly1305.Auth
poly1305auth rs c = authTag <$> cryptoPassed (Poly1305.initialize rs)
  where
    authTag state = Poly1305.finalize $ Poly1305.updates state $ LB.toChunks c
    cryptoPassed = \case
      CE.CryptoPassed a -> Right a
      CE.CryptoFailed e -> Left $ CryptoPoly1305Error e

xSalsa20 :: ByteArrayAccess key => key -> ByteString -> LazyByteString -> (ByteString, LazyByteString)
xSalsa20 secret nonce msg = (rs, msg')
  where
    zero = B.replicate 16 $ toEnum 0
    (iv0, iv1) = B.splitAt 8 nonce
    state0 = XSalsa.initialize 20 secret (zero `B.append` iv0)
    state1 = XSalsa.derive state0 iv1
    (rs, state2) = XSalsa.generate state1 32
    (msg', _) = foldl update (LB.empty, state2) $ LB.toChunks msg
    update (acc, state) chunk =
      let (c, state') = XSalsa.combine state chunk
       in (acc `LB.append` LB.fromStrict c, state')
