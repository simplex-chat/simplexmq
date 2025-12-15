{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}

module Simplex.Messaging.Agent.TSessionSubs
  ( TSessionSubs (sessionSubs),
    SessSubs (..),
    emptyIO,
    clear,
    hasActiveSub,
    hasPendingSub,
    addPendingSub,
    setSessionId,
    setPendingServiceSub,
    setActiveServiceSub,
    addActiveSub,
    addActiveSub',
    batchAddActiveSubs,
    batchAddPendingSubs,
    deletePendingSub,
    batchDeletePendingSubs,
    deleteSub,
    batchDeleteSubs,
    deleteServiceSub,
    hasPendingSubs,
    getPendingSubs,
    getPendingQueueSubs,
    getActiveSubs,
    setSubsPending,
    updateClientNotices,
    foldSessionSubs,
    mapSubs,
  )
where

import Control.Concurrent.STM
import Control.Monad
import Data.Int (Int64)
import Data.List (foldl')
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe, isJust)
import qualified Data.Set as S
import Simplex.Messaging.Agent.Protocol (SMPQueue (..))
import Simplex.Messaging.Agent.Store (RcvQueue, RcvQueueSub (..), SomeRcvQueue, StoredRcvQueue (rcvServiceAssoc), rcvQueueSub)
import Simplex.Messaging.Client (SMPTransportSession, TransportSessionMode (..))
import Simplex.Messaging.Protocol (RecipientId, ServiceSub (..), noIdsHash, queueIdHash)
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Transport
import Simplex.Messaging.Util (anyM, ($>>=))

data TSessionSubs = TSessionSubs
  { sessionSubs :: TMap SMPTransportSession SessSubs
  }

data SessSubs = SessSubs
  { subsSessId :: TVar (Maybe SessionId),
    activeSubs :: TMap RecipientId RcvQueueSub,
    pendingSubs :: TMap RecipientId RcvQueueSub,
    activeServiceSub :: TVar (Maybe ServiceSub),
    pendingServiceSub :: TVar (Maybe ServiceSub)
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
      s <- SessSubs <$> newTVar Nothing <*> newTVar M.empty <*> newTVar M.empty <*> newTVar Nothing <*> newTVar Nothing
      TM.insert tSess s $ sessionSubs ss
      pure s

hasActiveSub :: SMPTransportSession -> RecipientId -> TSessionSubs -> STM Bool
hasActiveSub = hasQueue_ activeSubs
{-# INLINE hasActiveSub #-}

hasPendingSub :: SMPTransportSession -> RecipientId -> TSessionSubs -> STM Bool
hasPendingSub = hasQueue_ pendingSubs
{-# INLINE hasPendingSub #-}

hasQueue_ :: (SessSubs -> TMap RecipientId RcvQueueSub) -> SMPTransportSession -> RecipientId -> TSessionSubs -> STM Bool
hasQueue_ subs tSess rId ss = isJust <$> (lookupSubs tSess ss $>>= TM.lookup rId . subs)
{-# INLINE hasQueue_ #-}

addPendingSub :: SMPTransportSession -> RcvQueueSub -> TSessionSubs -> STM ()
addPendingSub tSess rq ss = getSessSubs tSess ss >>= TM.insert (rcvId rq) rq . pendingSubs

setSessionId :: SMPTransportSession -> SessionId -> TSessionSubs -> STM ()
setSessionId tSess sessId ss = do
  s <- getSessSubs tSess ss
  readTVar (subsSessId s) >>= \case
    Nothing -> writeTVar (subsSessId s) (Just sessId)
    Just sessId' -> unless (sessId == sessId') $ void $ setSubsPending_ s $ Just sessId

setPendingServiceSub :: SMPTransportSession -> ServiceSub -> TSessionSubs -> STM ()
setPendingServiceSub tSess serviceSub ss = do
  s <- getSessSubs tSess ss
  writeTVar (pendingServiceSub s) $ Just serviceSub

setActiveServiceSub :: SMPTransportSession -> SessionId -> ServiceSub -> TSessionSubs -> STM ()
setActiveServiceSub tSess sessId serviceSub ss = do
  s <- getSessSubs tSess ss
  sessId' <- readTVar $ subsSessId s
  if Just sessId == sessId'
    then do
      writeTVar (activeServiceSub s) $ Just serviceSub
      writeTVar (pendingServiceSub s) Nothing
    else writeTVar (pendingServiceSub s) $ Just serviceSub

addActiveSub :: SMPTransportSession -> SessionId -> RcvQueue -> TSessionSubs -> STM ()
addActiveSub tSess sessId rq = addActiveSub' tSess sessId (rcvQueueSub rq) (rcvServiceAssoc rq)
{-# INLINE addActiveSub #-}

addActiveSub' :: SMPTransportSession -> SessionId -> RcvQueueSub -> Bool -> TSessionSubs -> STM ()
addActiveSub' tSess sessId rq serviceAssoc ss = do
  s <- getSessSubs tSess ss
  sessId' <- readTVar $ subsSessId s
  let rId = rcvId rq
  if Just sessId == sessId'
    then do
      TM.insert rId rq $ activeSubs s
      TM.delete rId $ pendingSubs s
      when serviceAssoc $
        let updateServiceSub (ServiceSub serviceId n idsHash) = ServiceSub serviceId (n + 1) (idsHash <> queueIdHash rId)
         in modifyTVar' (activeServiceSub s) (updateServiceSub <$>)
    else TM.insert rId rq $ pendingSubs s

batchAddActiveSubs :: SMPTransportSession -> SessionId -> Maybe ServiceId -> ([RcvQueueSub], [RcvQueueSub]) -> TSessionSubs -> STM ()
batchAddActiveSubs tSess sessId serviceId_ (rqs, serviceRQs) ss = do
  s <- getSessSubs tSess ss
  sessId' <- readTVar $ subsSessId s
  let qs = M.fromList $ map (\rq -> (rcvId rq, rq)) rqs
      serviceQs = M.fromList $ map (\rq -> (rcvId rq, rq)) serviceRQs
  if Just sessId == sessId'
    then do
      TM.union qs $ activeSubs s
      modifyTVar' (pendingSubs s) (`M.difference` qs)
      forM_ serviceId_ $ \serviceId -> unless (null serviceRQs) $ do
        modifyTVar' (pendingSubs s) (`M.difference` serviceQs)
        ServiceSub serviceId' n idsHash <-
          fromMaybe (ServiceSub serviceId 0 noIdsHash) <$> readTVar (activeServiceSub s)
        when (serviceId == serviceId') $ do
          let idsHash' = idsHash <> mconcat (map (queueIdHash . rcvId) serviceRQs)
              n' = n + fromIntegral (length serviceRQs)
          writeTVar (activeServiceSub s) $ Just $ ServiceSub serviceId n' idsHash'
    else do
      TM.union qs $ pendingSubs s
      when (isJust serviceId_ && not (null serviceRQs)) $ TM.union serviceQs $ pendingSubs s

batchAddPendingSubs :: SMPTransportSession -> [RcvQueueSub] -> TSessionSubs -> STM ()
batchAddPendingSubs tSess rqs ss = do
  s <- getSessSubs tSess ss
  modifyTVar' (pendingSubs s) $ M.union $ M.fromList $ map (\rq -> (rcvId rq, rq)) rqs

deletePendingSub :: SMPTransportSession -> RecipientId -> TSessionSubs -> STM ()
deletePendingSub tSess rId = lookupSubs tSess >=> mapM_ (TM.delete rId . pendingSubs)

batchDeletePendingSubs :: SMPTransportSession -> S.Set RecipientId -> TSessionSubs -> STM ()
batchDeletePendingSubs tSess rIds = lookupSubs tSess >=> mapM_ (delete . pendingSubs)
  where
    delete = (`modifyTVar'` (`M.withoutKeys` rIds))

deleteSub :: SMPTransportSession -> RecipientId -> TSessionSubs -> STM ()
deleteSub tSess rId = lookupSubs tSess >=> mapM_ (\s -> TM.delete rId (activeSubs s) >> TM.delete rId (pendingSubs s))

batchDeleteSubs :: SomeRcvQueue q => SMPTransportSession -> [q] -> TSessionSubs -> STM ()
batchDeleteSubs tSess rqs = lookupSubs tSess >=> mapM_ (\s -> delete (activeSubs s) >> delete (pendingSubs s))
  where
    rIds = S.fromList $ map queueId rqs
    delete = (`modifyTVar'` (`M.withoutKeys` rIds))

deleteServiceSub :: SMPTransportSession -> TSessionSubs -> STM ()
deleteServiceSub tSess = lookupSubs tSess >=> mapM_ (\s -> writeTVar (activeServiceSub s) Nothing >> writeTVar (pendingServiceSub s) Nothing)

hasPendingSubs :: SMPTransportSession -> TSessionSubs -> STM Bool
hasPendingSubs tSess = lookupSubs tSess >=> maybe (pure False) (\s -> anyM [hasSubs s, hasServiceSub s])
  where
    hasSubs = fmap (not . null) . readTVar . pendingSubs
    hasServiceSub = fmap isJust . readTVar . pendingServiceSub

getPendingSubs :: SMPTransportSession -> TSessionSubs -> STM (Map RecipientId RcvQueueSub, Maybe ServiceSub)
getPendingSubs tSess = lookupSubs tSess >=> maybe (pure (M.empty, Nothing)) get
  where
    get s = liftM2 (,) (readTVar $ pendingSubs s) (readTVar $ pendingServiceSub s)

getPendingQueueSubs :: SMPTransportSession -> TSessionSubs -> STM (Map RecipientId RcvQueueSub)
getPendingQueueSubs = getSubs_ pendingSubs
{-# INLINE getPendingQueueSubs #-}

getActiveSubs :: SMPTransportSession -> TSessionSubs -> STM (Map RecipientId RcvQueueSub)
getActiveSubs = getSubs_ activeSubs
{-# INLINE getActiveSubs #-}

getSubs_ :: (SessSubs -> TMap RecipientId RcvQueueSub) -> SMPTransportSession -> TSessionSubs -> STM (Map RecipientId RcvQueueSub)
getSubs_ subs tSess = lookupSubs tSess >=> maybe (pure M.empty) (readTVar . subs)

setSubsPending :: TransportSessionMode -> SMPTransportSession -> SessionId -> TSessionSubs -> STM (Map RecipientId RcvQueueSub, Maybe ServiceSub)
setSubsPending mode tSess@(uId, srv, connId_) sessId tss@(TSessionSubs ss)
  | entitySession == isJust connId_ =
      TM.lookup tSess ss >>= withSessSubs (`setSubsPending_` Nothing)
  | otherwise =
      TM.lookupDelete tSess ss >>= withSessSubs setPendingChangeMode
  where
    entitySession = mode == TSMEntity
    sessEntId = if entitySession then Just else const Nothing
    withSessSubs run = \case
      Nothing -> pure (M.empty, Nothing)
      Just s -> do
        sessId' <- readTVar $ subsSessId s
        if Just sessId == sessId' then run s else pure (M.empty, Nothing)
    setPendingChangeMode s = do
      subs <- M.union <$> readTVar (activeSubs s) <*> readTVar (pendingSubs s)
      unless (null subs) $
        forM_ subs $ \rq -> addPendingSub (uId, srv, sessEntId (connId rq)) rq tss
      (subs,) <$> setServiceSubPending_ s

setSubsPending_ :: SessSubs -> Maybe SessionId -> STM (Map RecipientId RcvQueueSub, Maybe ServiceSub)
setSubsPending_ s sessId_ = do
  writeTVar (subsSessId s) sessId_
  let as = activeSubs s
  subs <- readTVar as
  unless (null subs) $ do
    writeTVar as M.empty
    modifyTVar' (pendingSubs s) $ M.union subs
  (subs,) <$> setServiceSubPending_ s

setServiceSubPending_ :: SessSubs -> STM (Maybe ServiceSub)
setServiceSubPending_ s = do
  serviceSub_ <- readTVar $ activeServiceSub s
  forM_ serviceSub_ $ \serviceSub -> do
    writeTVar (activeServiceSub s) Nothing
    writeTVar (pendingServiceSub s) $ Just serviceSub
  pure serviceSub_

updateClientNotices :: SMPTransportSession -> [(RecipientId, Maybe Int64)] -> TSessionSubs -> STM ()
updateClientNotices tSess noticeIds ss = do
  s <- getSessSubs tSess ss
  modifyTVar' (pendingSubs s) $ \m -> foldl' (\m' (rcvId, clientNoticeId) -> M.adjust (\rq -> rq {clientNoticeId}) rcvId m') m noticeIds

foldSessionSubs :: (a -> (SMPTransportSession, SessSubs) -> IO a) -> a -> TSessionSubs -> IO a
foldSessionSubs f a = foldM f a . M.assocs <=< readTVarIO . sessionSubs

mapSubs :: (Map RecipientId RcvQueueSub -> a) -> SessSubs -> IO (a, a)
mapSubs f s = do
  active <- readTVarIO $ activeSubs s
  pending <- readTVarIO $ pendingSubs s
  pure (f active, f pending)
