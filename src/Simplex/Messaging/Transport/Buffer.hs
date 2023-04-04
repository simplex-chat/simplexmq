{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module Simplex.Messaging.Transport.Buffer where

import Control.Concurrent.STM
import qualified Control.Exception as E
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B

data TBuffer = TBuffer
  { buffer :: TVar ByteString,
    getLock :: TMVar ()
  }

newTBuffer :: STM TBuffer
newTBuffer = do
  buffer <- newTVar ""
  getLock <- newTMVar ()
  pure TBuffer {buffer, getLock}

withBufferLock :: TBuffer -> IO a -> IO a
withBufferLock TBuffer {getLock} =
  E.bracket_
    (atomically $ takeTMVar getLock)
    (atomically $ putTMVar getLock ())

getBuffered :: TBuffer -> Int -> IO ByteString -> IO ByteString
getBuffered tb@TBuffer {buffer} n getChunk = withBufferLock tb $ do
  b <- readChunks =<< readTVarIO buffer
  let (s, b') = B.splitAt n b
  atomically $ writeTVar buffer $! b'
  -- This would prevent the need to pad auth tag in HTTP2
  -- threadDelay' 150
  pure s
  where
    readChunks :: ByteString -> IO ByteString
    readChunks b
      | B.length b >= n = pure b
      | otherwise =
        getChunk >>= \case
          "" -> pure b
          s -> readChunks $ b <> s

-- This function is only used in test and needs to be improved before it can be used in production,
-- it will never complete if TLS connection is closed before there is newline.
getLnBuffered :: TBuffer -> IO ByteString -> IO ByteString
getLnBuffered tb@TBuffer {buffer} getChunk = withBufferLock tb $ do
  b <- readChunks =<< readTVarIO buffer
  let (s, b') = B.break (== '\n') b
  atomically $ writeTVar buffer $! B.drop 1 b' -- drop '\n' we made a break at
  pure $ trimCR s
  where
    readChunks :: ByteString -> IO ByteString
    readChunks b
      | B.elem '\n' b = pure b
      | otherwise = readChunks . (b <>) =<< getChunk

-- | Trim trailing CR from ByteString.
trimCR :: ByteString -> ByteString
trimCR "" = ""
trimCR s = if B.last s == '\r' then B.init s else s
