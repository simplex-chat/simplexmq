{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

module Simplex.Messaging.Agent.TSessionSubs
  ( TSessionSubs (sessionSubs),
    SessSubs (..),
    emptyIO,
    clear,
    hasActiveSub,
    hasPendingSub,
    addPendingSub,
    setSessionId,
    addActiveSub,
    batchAddPendingSubs,
    deletePendingSub,
    deleteSub,
    batchDeleteSubs,
    hasPendingSubs,
    getPendingSubs,
    getActiveSubs,
    setSubsPending,
    foldSessionSubs,
    mapSubs,
  )
where

import Control.Concurrent.STM
import Control.Monad
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Data.Maybe (isJust)
import qualified Data.Set as S
import Simplex.Messaging.Agent.Protocol (SMPQueue (..))
import Simplex.Messaging.Agent.Store (RcvQueueSub (..), SomeRcvQueue)
import Simplex.Messaging.Client (SMPTransportSession, TransportSessionMode (..))
import Simplex.Messaging.Protocol (RecipientId)
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Transport
import Simplex.Messaging.Util (($>>=))

-- the fields in this record have the same data with swapped keys for lookup efficiency,
-- and all methods must maintain this invariant.
data TSessionSubs = TSessionSubs
  { sessionSubs :: TMap SMPTransportSession SessSubs
  }

data SessSubs = SessSubs
  { subsSessId :: TVar (Maybe SessionId),
    activeSubs :: TMap RecipientId RcvQueueSub,
    pendingSubs :: TMap RecipientId RcvQueueSub
  }

emptyIO :: IO TSessionSubs
emptyIO = TSessionSubs <$> TM.emptyIO
{-# INLINE emptyIO #-}

clear :: TSessionSubs -> STM ()
clear = TM.clear . sessionSubs
{-# INLINE clear #-}

lookupSubs :: SMPTransportSession -> TSessionSubs -> STM (Maybe SessSubs)
lookupSubs tSess = TM.lookup tSess . sessionSubs
{-# INLINE lookupSubs #-}

getSessSubs :: SMPTransportSession -> TSessionSubs -> STM SessSubs
getSessSubs tSess ss = lookupSubs tSess ss >>= maybe new pure
  where
    new = do
      s <- SessSubs <$> newTVar Nothing <*> newTVar M.empty <*> newTVar M.empty
      TM.insert tSess s $ sessionSubs ss
      pure s

hasActiveSub :: RecipientId -> SMPTransportSession -> TSessionSubs -> STM Bool
hasActiveSub = hasQueue_ activeSubs
{-# INLINE hasActiveSub #-}

hasPendingSub :: RecipientId -> SMPTransportSession -> TSessionSubs -> STM Bool
hasPendingSub = hasQueue_ pendingSubs
{-# INLINE hasPendingSub #-}

hasQueue_ :: (SessSubs -> TMap RecipientId RcvQueueSub) -> RecipientId -> SMPTransportSession -> TSessionSubs -> STM Bool
hasQueue_ subs rId tSess ss = isJust <$> (lookupSubs tSess ss $>>= TM.lookup rId . subs)
{-# INLINE hasQueue_ #-}

addPendingSub :: RcvQueueSub -> SMPTransportSession -> TSessionSubs -> STM ()
addPendingSub rq tSess ss = getSessSubs tSess ss >>= TM.insert (rcvId rq) rq . pendingSubs

setSessionId :: SessionId -> SMPTransportSession -> TSessionSubs -> STM ()
setSessionId sessId tSess ss = do
  s <- getSessSubs tSess ss
  readTVar (subsSessId s) >>= \case
    Nothing -> writeTVar (subsSessId s) (Just sessId)
    Just sessId' -> unless (sessId == sessId') $ void $ setSubsPending_ s $ Just sessId

addActiveSub :: SessionId -> RcvQueueSub -> SMPTransportSession -> TSessionSubs -> STM ()
addActiveSub sessId rq tSess ss = do
  s <- getSessSubs tSess ss
  sessId' <- readTVar $ subsSessId s
  let rId = rcvId rq
  if Just sessId == sessId'
    then do
      TM.insert rId rq $ activeSubs s
      TM.delete rId $ pendingSubs s
    else TM.insert rId rq $ pendingSubs s

batchAddPendingSubs :: [RcvQueueSub] -> SMPTransportSession -> TSessionSubs -> STM ()
batchAddPendingSubs rqs tSess ss = do
  s <- getSessSubs tSess ss
  modifyTVar' (pendingSubs s) $ M.union $ M.fromList $ map (\rq -> (rcvId rq, rq)) rqs

deletePendingSub :: RecipientId -> SMPTransportSession -> TSessionSubs -> STM ()
deletePendingSub rId tSess = lookupSubs tSess >=> mapM_ (TM.delete rId . pendingSubs)

deleteSub :: RecipientId -> SMPTransportSession -> TSessionSubs -> STM ()
deleteSub rId tSess = lookupSubs tSess >=> mapM_ (\s -> TM.delete rId (activeSubs s) >> TM.delete rId (pendingSubs s))

batchDeleteSubs :: SomeRcvQueue q => [q] -> SMPTransportSession -> TSessionSubs -> STM ()
batchDeleteSubs rqs tSess = lookupSubs tSess >=> mapM_ (\s -> delete (activeSubs s) >> delete (pendingSubs s))
  where
    rIds = S.fromList $ map queueId rqs
    delete = (`modifyTVar'` (`M.withoutKeys` rIds))

hasPendingSubs :: SMPTransportSession -> TSessionSubs -> STM Bool
hasPendingSubs tSess = lookupSubs tSess >=> maybe (pure False) (fmap (not . null) . readTVar . pendingSubs)

getPendingSubs :: SMPTransportSession -> TSessionSubs -> STM (Map RecipientId RcvQueueSub)
getPendingSubs = getSubs_ pendingSubs
{-# INLINE getPendingSubs #-}

getActiveSubs :: SMPTransportSession -> TSessionSubs -> STM (Map RecipientId RcvQueueSub)
getActiveSubs = getSubs_ activeSubs
{-# INLINE getActiveSubs #-}

getSubs_ :: (SessSubs -> TMap RecipientId RcvQueueSub) -> SMPTransportSession -> TSessionSubs -> STM (Map RecipientId RcvQueueSub)
getSubs_ subs tSess = lookupSubs tSess >=> maybe (pure M.empty) (readTVar . subs)

setSubsPending :: TransportSessionMode -> SMPTransportSession -> SessionId -> TSessionSubs -> STM (Map RecipientId RcvQueueSub)
setSubsPending mode tSess@(uId, srv, connId_) sessId tss@(TSessionSubs ss)
  | entitySession == isJust connId_ =
      TM.lookup tSess ss >>= withSessSubs (`setSubsPending_` Nothing)
  | otherwise =
      TM.lookupDelete tSess ss >>= withSessSubs setPendingChangeMode
  where
    entitySession = mode == TSMEntity
    sessEntId = if entitySession then Just else const Nothing
    withSessSubs run = \case
      Nothing -> pure M.empty
      Just s -> do
        sessId' <- readTVar $ subsSessId s
        if Just sessId == sessId' then run s else pure M.empty
    setPendingChangeMode s = do
      subs <- M.union <$> readTVar (activeSubs s) <*> readTVar (pendingSubs s)
      unless (null subs) $
        forM_ subs $ \rq -> addPendingSub rq (uId, srv, sessEntId (connId rq)) tss
      pure subs

setSubsPending_ :: SessSubs -> Maybe SessionId -> STM (Map RecipientId RcvQueueSub)
setSubsPending_ s sessId_ = do
  writeTVar (subsSessId s) sessId_
  let as = activeSubs s
  subs <- readTVar as
  unless (null subs) $ do
    writeTVar as M.empty
    modifyTVar' (pendingSubs s) $ M.union subs
  pure subs

foldSessionSubs :: (a -> (SMPTransportSession, SessSubs) -> IO a) -> a -> TSessionSubs -> IO a
foldSessionSubs f a = foldM f a . M.assocs <=< readTVarIO . sessionSubs

mapSubs :: (Map RecipientId RcvQueueSub -> a) -> SessSubs -> IO (a, a)
mapSubs f s = do
  active <- readTVarIO $ activeSubs s
  pending <- readTVarIO $ pendingSubs s
  pure (f active, f pending)
