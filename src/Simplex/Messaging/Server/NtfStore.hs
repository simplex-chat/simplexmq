{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module Simplex.Messaging.Server.NtfStore
  ( NtfStore (..),
    MsgNtf (..),
    storeNtf,
    deleteNtfs,
    deleteExpiredNtfs,
    NtfLogRecord (..),
  ) where

import Control.Concurrent.STM
import Control.Monad (foldM)
import Data.Int (Int64)
import qualified Data.Map.Strict as M
import Data.Time.Clock.System (SystemTime (..))
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Protocol (EncNMsgMeta, MsgId, NotifierId)
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM

newtype NtfStore = NtfStore (TMap NotifierId (TVar [MsgNtf]))

data MsgNtf = MsgNtf
  { ntfMsgId :: MsgId,
    ntfTs :: SystemTime,
    ntfNonce :: C.CbNonce,
    ntfEncMeta :: EncNMsgMeta
  }

storeNtf :: NtfStore -> NotifierId -> MsgNtf -> IO ()
storeNtf (NtfStore ns) nId ntf = do
  TM.lookupIO nId ns >>= atomically . maybe newNtfs (`modifyTVar'` (ntf :))
  -- TODO [ntfdb] coalesce messages here once the client is updated to process multiple messages
  -- for single notification.
  -- when (isJust prevNtf) $ incStat $ msgNtfReplaced stats
  where
    newNtfs = TM.lookup nId ns >>= maybe (TM.insertM nId (newTVar [ntf]) ns) (`modifyTVar'` (ntf :))

deleteNtfs :: NtfStore -> NotifierId -> IO Int
deleteNtfs (NtfStore ns) nId = atomically (TM.lookupDelete nId ns) >>= maybe (pure 0) (fmap length . readTVarIO)

deleteExpiredNtfs :: NtfStore -> Int64 -> IO Int
deleteExpiredNtfs (NtfStore ns) old =
  foldM (\expired -> fmap (expired +) . expireQueue) 0 . M.keys =<< readTVarIO ns
  where
    expireQueue nId = TM.lookupIO nId ns >>= maybe (pure 0) expire
    expire v = readTVarIO v >>= \case
      [] -> pure 0
      _ ->
        atomically $ readTVar v >>= \case
          [] -> pure 0
          -- check the last message first, it is the earliest
          ntfs | systemSeconds (ntfTs $ last $ ntfs) < old -> do
            let !ntfs' = filter (\MsgNtf {ntfTs = ts} -> systemSeconds ts >= old) ntfs
            writeTVar v ntfs'
            pure $! length ntfs - length ntfs'
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
