{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

module Simplex.Messaging.Agent.Store.SQLite.Functions where

import Control.Monad.Trans.Except
import Data.Bits (xor)
import Database.SQLite3 (Database)
import Database.SQLite3.Direct (Error (..), createFunction, funcArgBlob, funcResultBlob)
import qualified Data.ByteString as B
import qualified Simplex.Messaging.Crypto as C

md5Func :: Database -> IO (Either Error ())
md5Func db =
  createFunction db "chat_md5hash" (Just 1) True $ \cxt args -> do
    print "in chat_md5hash"
    funcResultBlob cxt . C.md5Hash =<< funcArgBlob args 0

-- Bitwise XOR
xorCombineFunc :: Database -> IO (Either Error ())
xorCombineFunc db =
  createFunction db "chat_xor_combine" (Just 2) True $ \cxt args -> do
    print "in chat_xor_combine"
    s1 <- funcArgBlob args 0
    s2 <- funcArgBlob args 1
    funcResultBlob cxt $ B.pack $ B.zipWith xor s1 s2

-- xorAggregate :: Database -> IO (Either Error ())
-- xorAggregate db = createAggregate db "chat_xor_aggregate" (Just 1) (B.replicate 16 0) step funcResultBlob
--   where
--     step _ args st = B.pack . B.zipWith xor st <$> funcArgBlob args 0

registerFunctions :: Database -> IO (Either Error ())
registerFunctions db = runExceptT $ do
  ExceptT $ md5Func db
  ExceptT $ xorCombineFunc db
  -- ExceptT $ xorAggregate db
