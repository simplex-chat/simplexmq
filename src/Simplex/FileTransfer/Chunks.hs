module Simplex.FileTransfer.Chunks where

import Data.Word (Word32)

serverChunkSizes :: [Word32]
serverChunkSizes = [chunkSize0, chunkSize1, chunkSize2, chunkSize3]
{-# INLINE serverChunkSizes #-}

chunkSize0 :: Word32
chunkSize0 = kb 64
{-# INLINE chunkSize0 #-}

chunkSize1 :: Word32
chunkSize1 = kb 256
{-# INLINE chunkSize1 #-}

chunkSize2 :: Word32
chunkSize2 = mb 1
{-# INLINE chunkSize2 #-}

chunkSize3 :: Word32
chunkSize3 = mb 4
{-# INLINE chunkSize3 #-}

kb :: Integral a => a -> a
kb n = 1024 * n
{-# INLINE kb #-}

mb :: Integral a => a -> a
mb n = 1024 * kb n
{-# INLINE mb #-}

gb :: Integral a => a -> a
gb n = 1024 * mb n
{-# INLINE gb #-}
