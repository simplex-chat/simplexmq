{-# LANGUAGE OverloadedStrings #-}

module Util where

import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Network.Socket
import System.IO

getSocketHandle :: Socket -> IO Handle
getSocketHandle conn = do
  h <- socketToHandle conn ReadWriteMode
  hSetBinaryMode h True
  hSetNewlineMode h NewlineMode {inputNL = CRLF, outputNL = CRLF}
  hSetBuffering h LineBuffering
  return h

putLn :: Handle -> ByteString -> IO ()
putLn h = B.hPut h . (<> "\r\n")

getLn :: Handle -> IO ByteString
getLn h = trim_cr <$> B.hGetLine h
  where
    trim_cr "" = ""
    trim_cr s = if B.last s == '\r' then B.init s else s
