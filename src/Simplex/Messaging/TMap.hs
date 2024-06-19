module Simplex.Messaging.TMap
  ( TMap,
    empty,
    singleton,
    clear,
    Simplex.Messaging.TMap.null,
    Simplex.Messaging.TMap.lookup,
    member,
    insert,
    delete,
    lookupInsert,
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

empty :: STM (TMap k a)
empty = newTVar M.empty
{-# INLINE empty #-}

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

member :: Ord k => k -> TMap k a -> STM Bool
member k m = M.member k <$> readTVar m
{-# INLINE member #-}

insert :: Ord k => k -> a -> TMap k a -> STM ()
insert k v m = modifyTVar' m $ M.insert k v
{-# INLINE insert #-}

delete :: Ord k => k -> TMap k a -> STM ()
delete k m = modifyTVar' m $ M.delete k
{-# INLINE delete #-}

lookupInsert :: Ord k => k -> a -> TMap k a -> STM (Maybe a)
lookupInsert k v m = stateTVar m $ \mv -> (M.lookup k mv, M.insert k v mv)
{-# INLINE lookupInsert #-}

lookupDelete :: Ord k => k -> TMap k a -> STM (Maybe a)
lookupDelete k m = stateTVar m $ \mv -> (M.lookup k mv, M.delete k mv)
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
