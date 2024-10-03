{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module Simplex.Messaging.Server.NtfStore where

import Control.Concurrent.STM
import Control.Monad (foldM)
import Data.Functor (($>))
import Data.Int (Int64)
import qualified Data.Map.Strict as M
import Data.Maybe (isJust)
import Data.Time.Clock.System (SystemTime (..))
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Protocol (EncNMsgMeta, MsgId, NotifierId)
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM

newtype NtfStore = NtfStore (TMap NotifierId (TVar (Maybe MsgNtf)))

data MsgNtf = MsgNtf
  { ntfMsgId :: MsgId,
    ntfTs :: SystemTime,
    ntfNonce :: C.CbNonce,
    ntfEncMeta :: EncNMsgMeta
  }

storeNtf :: NtfStore -> NotifierId -> MsgNtf -> IO Bool
storeNtf (NtfStore ns) nId ntf = do
  ntfVar_ <- TM.lookupIO nId ns
  prevNtf <- atomically $ case ntfVar_ of
    Just v -> swapTVar v (Just ntf)
    Nothing -> newNtfs
  pure $ isJust prevNtf
  where
    newNtfs = do
      TM.lookup nId ns >>= \case
        Just v -> swapTVar v (Just ntf)
        Nothing -> TM.insertM nId (newTVar (Just ntf)) ns $> Nothing

deleteNtfs :: NtfStore -> NotifierId -> IO ()
deleteNtfs (NtfStore ns) nId = atomically $ TM.delete nId ns

flushNtfs :: NtfStore -> NotifierId -> IO (Maybe MsgNtf)
flushNtfs (NtfStore ns) nId = do
  TM.lookupIO nId ns >>= maybe (pure Nothing) swapNtfs
  where
    swapNtfs v =
      readTVarIO v >>= \case
        Nothing -> pure Nothing
        -- if notifications available, atomically swap with empty array
        _ -> atomically (swapTVar v Nothing)

deleteExpiredNtfs :: NtfStore -> Int64 -> IO Int
deleteExpiredNtfs (NtfStore ns) old =
  foldM (\expired -> fmap (expired +) . expireQueue) 0 . M.keys =<< readTVarIO ns
  where
    expireQueue nId = TM.lookupIO nId ns >>= maybe (pure 0) expire
    expire v =
      readTVarIO v >>= \case
        Nothing -> pure 0
        _ ->
          atomically $
            readTVar v >>= \case
              Nothing -> pure 0
              Just ntf | systemSeconds (ntfTs ntf) < old -> do
                writeTVar v Nothing
                pure 1
              _ -> pure 0

data NtfLogRecord = NLRv1 NotifierId MsgNtf

instance StrEncoding MsgNtf where
  strEncode MsgNtf {ntfMsgId, ntfTs, ntfNonce, ntfEncMeta} = strEncode (ntfMsgId, ntfTs, ntfNonce, ntfEncMeta)
  strP = do
    (ntfMsgId, ntfTs, ntfNonce, ntfEncMeta) <- strP
    pure MsgNtf {ntfMsgId, ntfTs, ntfNonce, ntfEncMeta}

instance StrEncoding NtfLogRecord where
  strEncode (NLRv1 nId ntf) = strEncode (Str "v1", nId, ntf)
  strP = "v1 " *> (NLRv1 <$> strP_ <*> strP)
