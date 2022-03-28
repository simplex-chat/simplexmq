module Simplex.Messaging.TMap
  ( TMap (..),
    empty,
    Simplex.Messaging.TMap.lookup,
    member,
    insert,
    delete,
    lookupInsert,
    lookupDelete,
    adjust,
    update,
    alter,
  )
where

import Control.Concurrent.STM
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M

newtype TMap k a = TMap {tVar :: TVar (Map k a)}

empty :: STM (TMap k a)
empty = TMap <$> newTVar M.empty
{-# INLINE empty #-}

lookup :: Ord k => k -> TMap k a -> STM (Maybe a)
lookup k (TMap m) = M.lookup k <$> readTVar m
{-# INLINE lookup #-}

member :: Ord k => k -> TMap k a -> STM Bool
member k (TMap m) = M.member k <$> readTVar m
{-# INLINE member #-}

insert :: Ord k => k -> a -> TMap k a -> STM ()
insert k v (TMap m) = modifyTVar' m $ M.insert k v
{-# INLINE insert #-}

delete :: Ord k => k -> TMap k a -> STM ()
delete k (TMap m) = modifyTVar' m $ M.delete k
{-# INLINE delete #-}

lookupInsert :: Ord k => k -> a -> TMap k a -> STM (Maybe a)
lookupInsert k v (TMap m) = stateTVar m $ \mv -> (M.lookup k mv, M.insert k v mv)
{-# INLINE lookupInsert #-}

lookupDelete :: Ord k => k -> TMap k a -> STM (Maybe a)
lookupDelete k (TMap m) = stateTVar m $ \mv -> (M.lookup k mv, M.delete k mv)
{-# INLINE lookupDelete #-}

adjust :: Ord k => (a -> a) -> k -> TMap k a -> STM ()
adjust f k (TMap m) = modifyTVar' m $ M.adjust f k
{-# INLINE adjust #-}

update :: Ord k => (a -> Maybe a) -> k -> TMap k a -> STM ()
update f k (TMap m) = modifyTVar' m $ M.update f k
{-# INLINE update #-}

alter :: Ord k => (Maybe a -> Maybe a) -> k -> TMap k a -> STM ()
alter f k (TMap m) = modifyTVar' m $ M.alter f k
{-# INLINE alter #-}
