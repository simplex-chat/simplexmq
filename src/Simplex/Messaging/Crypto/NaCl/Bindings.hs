{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}

{-# HLINT ignore "Use camelCase" #-}

module Simplex.Messaging.Crypto.NaCl.Bindings where

import Data.ByteArray (ScrubbedBytes)
import Foreign
import Foreign.C.Types

#if MIN_VERSION_base(4,18,0)
import Foreign.C.ConstPtr
#else
type ConstPtr = Ptr
pattern ConstPtr :: p -> p
pattern ConstPtr p = p
#endif

crypto_box_PUBLICKEYBYTES :: Num a => a
crypto_box_PUBLICKEYBYTES = 32

crypto_box_SECRETKEYBYTES :: Num a => a
crypto_box_SECRETKEYBYTES = 32

crypto_box_BEFORENMBYTES :: Num a => a
crypto_box_BEFORENMBYTES = 32

crypto_box_NONCEBYTES :: Num a => a
crypto_box_NONCEBYTES = 24

crypto_box_ZEROBYTES :: Num a => a
crypto_box_ZEROBYTES = 32

crypto_box_BOXZEROBYTES :: Num a => a
crypto_box_BOXZEROBYTES = 16

-- int crypto_box(u8 *c,const u8 *m,u64 d,const u8 *n,const u8 *y,const u8 *x)
-- {
--   u8 k[32];
--   crypto_box_beforenm(k,y,x);
--   return crypto_box_afternm(c,m,d,n,k);
-- }
foreign import capi "tweetnacl.h crypto_box"
  c_crypto_box :: Ptr Word8 -> ConstPtr Word8 -> Word64 -> ConstPtr Word8 -> ConstPtr Word8 -> ConstPtr Word8 -> IO CInt

-- int crypto_box_open(u8 *m,const u8 *c,u64 d,const u8 *n,const u8 *y,const u8 *x)
-- {
--   u8 k[32];
--   crypto_box_beforenm(k,y,x);
--   return crypto_box_open_afternm(m,c,d,n,k);
-- }
foreign import capi "crypto_box_open"
  c_crypto_box_open :: Ptr Word8 -> ConstPtr Word8 -> Word64 -> ConstPtr Word8 -> ConstPtr Word8 -> ConstPtr Word8 -> IO CInt

-- XXX: requires randombytes extern symbol available. Not relevant as we can random it ourselves.
-- foreign import ccall "crypto_box_keypair"
--   c_crypto_box_keypair :: Ptr Word8 -> Ptr Word8 -> IO CInt

foreign import capi "tweetnacl.h crypto_scalarmult"
  crypto_scalarmult :: Ptr Word8 -> ConstPtr Word8 -> ConstPtr Word8 -> IO CInt

-- XXX: does NOT result in the same DH key we/crypton use as it throws HSalsa20 at the result of the scalarmult op above
-- int crypto_box_beforenm(u8 *k,const u8 *y,const u8 *x)
-- {
--   u8 s[32];
--   crypto_scalarmult(s,x,y);
--   return crypto_core_hsalsa20(k,_0,s,sigma);
-- }
foreign import capi "tweetnacl.h crypto_box_beforenm"
  c_crypto_box_beforenm :: Ptr Word8 -> ConstPtr Word8 -> ConstPtr Word8 -> IO CInt

foreign import capi "tweetnacl.h crypto_core_hsalsa20"
  c_crypto_core_hsalsa20 :: Ptr Word8 -> ConstPtr Word8 -> ConstPtr Word8 -> ConstPtr Word8 -> IO CInt

foreign import capi "tweetnacl.h crypto_secretbox"
  c_crypto_secretbox :: Ptr Word8 -> ConstPtr Word8 -> Word64 -> ConstPtr Word8 -> ConstPtr Word8 -> IO CInt

foreign import capi "tweetnacl.h crypto_secretbox_open"
  c_crypto_secretbox_open :: Ptr Word8 -> ConstPtr Word8 -> Word64 -> ConstPtr Word8 -> ConstPtr Word8 -> IO CInt

-- type NaclDhSecret = C.DhSecret 'C.X25519
type NaclDhSecret = ScrubbedBytes

-- int crypto_box_afternm(u8 *c,const u8 *m,u64 d,const u8 *n,const u8 *k)
-- {
--   return crypto_secretbox(c,m,d,n,k);
-- }
foreign import capi "tweetnacl.h crypto_box_afternm"
  c_crypto_box_afternm :: Ptr Word8 -> ConstPtr Word8 -> Word64 -> ConstPtr Word8 -> ConstPtr Word8 -> IO CInt

-- int crypto_box_open_afternm(u8 *m,const u8 *c,u64 d,const u8 *n,const u8 *k)
-- {
--   return crypto_secretbox_open(m,c,d,n,k);
-- }
foreign import capi "tweetnacl.h crypto_box_open_afternm"
  c_crypto_box_open_afternm :: Ptr Word8 -> ConstPtr Word8 -> Word64 -> ConstPtr Word8 -> ConstPtr Word8 -> IO CInt
