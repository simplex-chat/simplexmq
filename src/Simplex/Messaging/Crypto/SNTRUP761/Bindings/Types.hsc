-- {-# LANGUAGE CApiFFI #-}

module Simplex.Messaging.Crypto.SNTRUP761.Bindings.Types where

import Foreign.C

#include "sntrup761.h"

c_SNTRUP761_SECRETKEY_SIZE :: CInt
c_SNTRUP761_SECRETKEY_SIZE = #{const SNTRUP761_SECRETKEY_SIZE}

-- foreign import capi "sntrup761.h value SNTRUP761_SECRETKEY_SIZE" c_SNTRUP761_SECRETKEY_SIZE :: CInt
