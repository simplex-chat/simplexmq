{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Simplex.Messaging.Transport.Plain (Plain) where

import Control.Concurrent.STM
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy as BL
import qualified Network.TLS as T
import Simplex.Messaging.Transport
import Simplex.Messaging.Transport (TLS (tlsContext))
import qualified UnliftIO.Exception as E

newtype Plain = Plain {tls :: TLS}

instance Transport Plain where
  transportName _ = "Plain TLS 1.3 over TCP"
  getServerConnection tls = pure Plain {tls}
  getClientConnection tls = pure Plain {tls}
  closeConnection (Plain tls) = closeTLS $ tlsContext tls

  cGet :: Plain -> Int -> IO ByteString
  cGet Plain {tls} n =
    E.bracket_
      (atomically $ takeTMVar (getLock tls))
      (atomically $ putTMVar (getLock tls) ())
      $ do
        b <- readChunks =<< readTVarIO (buffer tls)
        let (s, b') = B.splitAt n b
        atomically $ writeTVar (buffer tls) b'
        pure s
    where
      readChunks :: ByteString -> IO ByteString
      readChunks b
        | B.length b >= n = pure b
        | otherwise = readChunks . (b <>) =<< T.recvData (tlsContext tls) `E.catch` handleEOF
      handleEOF = \case
        T.Error_EOF -> E.throwIO TEBadBlock
        e -> E.throwIO e

  cPut :: Plain -> ByteString -> IO ()
  cPut Plain {tls} = T.sendData (tlsContext tls) . BL.fromStrict

  -- ?
  getLn :: Plain -> IO ByteString
  getLn Plain {tls} = do
    s <- trimCR <$> T.recvData (tlsContext tls)
    if B.null s || B.last s /= '\n'
      then E.throwIO TEBadBlock
      else pure $ B.init s
