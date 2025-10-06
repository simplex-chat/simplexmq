{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
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
    getActiveConns,
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
import Simplex.Messaging.Agent.Protocol (ConnId, SMPQueue (..))
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
    activeSubs :: TMap RecipientId ConnId,
    pendingSubs :: TMap RecipientId ConnId
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

hasQueue_ :: (SessSubs -> TMap RecipientId ConnId) -> RecipientId -> SMPTransportSession -> TSessionSubs -> STM Bool
hasQueue_ subs rId tSess ss = isJust <$> (lookupSubs tSess ss $>>= TM.lookup rId . subs)

addPendingSub :: RcvQueueSub -> SMPTransportSession -> TSessionSubs -> STM ()
addPendingSub RcvQueueSub {rcvId, connId} = addPendingSub_ rcvId connId
{-# INLINE addPendingSub #-}

addPendingSub_ :: RecipientId -> ConnId -> SMPTransportSession -> TSessionSubs -> STM ()
addPendingSub_ rId cId tSess ss = getSessSubs tSess ss >>= TM.insert rId cId . pendingSubs

setSessionId :: SessionId -> SMPTransportSession -> TSessionSubs -> STM ()
setSessionId sessId tSess ss = do
  s <- getSessSubs tSess ss
  readTVar (subsSessId s) >>= \case
    Nothing -> writeTVar (subsSessId s) (Just sessId)
    Just sessId' -> unless (sessId == sessId') $ void $ setSubsPending_ s $ Just sessId

addActiveSub :: SessionId -> RcvQueueSub -> SMPTransportSession -> TSessionSubs -> STM ()
addActiveSub sessId RcvQueueSub {rcvId, connId} tSess ss = do
  s <- getSessSubs tSess ss
  sessId' <- readTVar $ subsSessId s
  if Just sessId == sessId'
    then do
      TM.insert rcvId connId $ activeSubs s
      TM.delete rcvId $ pendingSubs s
    else TM.insert rcvId connId $ pendingSubs s

batchAddPendingSubs :: [RcvQueueSub] -> SMPTransportSession -> TSessionSubs -> STM ()
batchAddPendingSubs rqs tSess ss = do
  s <- getSessSubs tSess ss
  modifyTVar' (pendingSubs s) $ M.union $ M.fromList $ map (\rq -> (rcvId rq, connId rq)) rqs

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

getPendingSubs :: SMPTransportSession -> TSessionSubs -> STM [(RecipientId, ConnId)]
getPendingSubs tSess = fmap M.assocs . getSubs_ pendingSubs tSess
{-# INLINE getPendingSubs #-}

getActiveConns :: SMPTransportSession -> TSessionSubs -> STM (S.Set ConnId)
getActiveConns tSess = fmap (S.fromList . M.elems) . getSubs_ activeSubs tSess
{-# INLINE getActiveConns #-}

getSubs_ :: (SessSubs -> TMap RecipientId ConnId) -> SMPTransportSession -> TSessionSubs -> STM (Map RecipientId ConnId)
getSubs_ subs tSess = lookupSubs tSess >=> maybe (pure M.empty) (readTVar . subs)

setSubsPending :: TransportSessionMode -> SMPTransportSession -> SessionId -> TSessionSubs -> STM [(RecipientId, ConnId)]
setSubsPending mode tSess@(uId, srv, connId_) sessId tss@(TSessionSubs ss)
  | entitySession == isJust connId_ =
      TM.lookup tSess ss >>= withSessSubs (`setSubsPending_` Nothing)
  | otherwise =
      TM.lookupDelete tSess ss >>= withSessSubs setPendingChangeMode
  where
    entitySession = mode == TSMEntity
    sessEntId = if entitySession then Just else const Nothing
    withSessSubs run = \case
      Nothing -> pure []
      Just s -> do
        sessId' <- readTVar $ subsSessId s
        if Just sessId == sessId' then run s else pure []
    setPendingChangeMode s = do
      subs <- M.union <$> readTVar (activeSubs s) <*> readTVar (pendingSubs s)
      let subs' = M.assocs subs
      unless (null subs') $
        forM_ subs' $ \(rId, cId) -> addPendingSub_ rId cId (uId, srv, sessEntId cId) tss
      pure subs'

setSubsPending_ :: SessSubs -> Maybe SessionId -> STM [(RecipientId, ConnId)]
setSubsPending_ s sessId_ = do
  writeTVar (subsSessId s) sessId_
  let as = activeSubs s
  subs <- readTVar as
  unless (M.null subs) $ do
    writeTVar as M.empty
    modifyTVar' (pendingSubs s) $ M.union subs
  pure $ M.assocs subs

foldSessionSubs :: (a -> (SMPTransportSession, SessSubs) -> IO a) -> a -> TSessionSubs -> IO a
foldSessionSubs f a = foldM f a . M.assocs <=< readTVarIO . sessionSubs

mapSubs :: (Map RecipientId ConnId -> a) -> SessSubs -> IO (a, a)
mapSubs f s = do
  active <- readTVarIO $ activeSubs s
  pending <- readTVarIO $ pendingSubs s
  pure (f active, f pending)
