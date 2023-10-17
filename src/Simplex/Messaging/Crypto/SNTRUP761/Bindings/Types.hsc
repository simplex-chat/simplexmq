module Simplex.Messaging.Crypto.SNTRUP761.Bindings.Types where

#include "cbits/sntrup761.h"

c_SNTRUP761_SECRETKEY_SIZE :: CInt
c_SNTRUP761_SECRETKEY_SIZE = #{const SNTRUP761_SECRETKEY_SIZE}
