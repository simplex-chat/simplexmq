{-# LANGUAGE TupleSections #-}

module Simplex.Messaging.TMap
  ( TMap,
    emptyIO,
    singleton,
    clear,
    Simplex.Messaging.TMap.null,
    Simplex.Messaging.TMap.lookup,
    lookupIO,
    member,
    memberIO,
    insert,
    insertM,
    delete,
    lookupDelete,
    adjust,
    update,
    alter,
    alterF,
    union,
  )
where

import Control.Concurrent.STM
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M

type TMap k a = TVar (Map k a)

emptyIO :: IO (TMap k a)
emptyIO = newTVarIO M.empty
{-# INLINE emptyIO #-}

singleton :: k -> a -> STM (TMap k a)
singleton k v = newTVar $ M.singleton k v
{-# INLINE singleton #-}

clear :: TMap k a -> STM ()
clear m = writeTVar m M.empty
{-# INLINE clear #-}

null :: TMap k a -> STM Bool
null m = M.null <$> readTVar m
{-# INLINE null #-}

lookup :: Ord k => k -> TMap k a -> STM (Maybe a)
lookup k m = M.lookup k <$> readTVar m
{-# INLINE lookup #-}

lookupIO :: Ord k => k -> TMap k a -> IO (Maybe a)
lookupIO k m = M.lookup k <$> readTVarIO m
{-# INLINE lookupIO #-}

member :: Ord k => k -> TMap k a -> STM Bool
member k m = M.member k <$> readTVar m
{-# INLINE member #-}

memberIO :: Ord k => k -> TMap k a -> IO Bool
memberIO k m = M.member k <$> readTVarIO m
{-# INLINE memberIO #-}

insert :: Ord k => k -> a -> TMap k a -> STM ()
insert k v m = modifyTVar' m $ M.insert k v
{-# INLINE insert #-}

insertM :: Ord k => k -> STM a -> TMap k a -> STM ()
insertM k f m = modifyTVar' m . M.insert k =<< f
{-# INLINE insertM #-}

delete :: Ord k => k -> TMap k a -> STM ()
delete k m = modifyTVar' m $ M.delete k
{-# INLINE delete #-}

lookupDelete :: Ord k => k -> TMap k a -> STM (Maybe a)
lookupDelete k m = stateTVar m $ M.alterF (,Nothing) k
{-# INLINE lookupDelete #-}

adjust :: Ord k => (a -> a) -> k -> TMap k a -> STM ()
adjust f k m = modifyTVar' m $ M.adjust f k
{-# INLINE adjust #-}

update :: Ord k => (a -> Maybe a) -> k -> TMap k a -> STM ()
update f k m = modifyTVar' m $ M.update f k
{-# INLINE update #-}

alter :: Ord k => (Maybe a -> Maybe a) -> k -> TMap k a -> STM ()
alter f k m = modifyTVar' m $ M.alter f k
{-# INLINE alter #-}

alterF :: Ord k => (Maybe a -> STM (Maybe a)) -> k -> TMap k a -> STM ()
alterF f k m = do
  mv <- M.alterF f k =<< readTVar m
  writeTVar m $! mv
{-# INLINE alterF #-}

union :: Ord k => Map k a -> TMap k a -> STM ()
union m' m = modifyTVar' m $ M.union m'
{-# INLINE union #-}
