module Simplex.Messaging.TSet
  ( TSet,
    emptyIO,
    empty,
    clear,
    size,
    member,
    insert,
    delete,
    toSet,
    toSetIO,
    foldIO,
  )
where

import Control.Concurrent.STM
import Data.Hashable (Hashable)
import Data.Set (Set)
import qualified Data.Set as S
import qualified ListT
import qualified StmContainers.Set as SS

type TSet a = SS.Set a

emptyIO :: IO (TSet a)
emptyIO = SS.newIO
{-# INLINE emptyIO #-}

empty :: STM (TSet a)
empty = SS.new
{-# INLINE empty #-}

clear :: TSet a -> STM ()
clear = SS.reset
{-# INLINE clear #-}

size :: TSet a -> STM Int
size = SS.size
{-# INLINE size #-}

member :: Hashable a => a -> TSet a -> STM Bool
member = SS.lookup
{-# INLINE member #-}

insert :: Hashable a => a -> TSet a -> STM ()
insert = SS.insert
{-# INLINE insert #-}

delete :: Hashable a => a -> TSet a -> STM ()
delete = SS.delete
{-# INLINE delete #-}

toSet :: Ord a => TSet a -> STM (Set a)
toSet = fmap S.fromList . ListT.toList . SS.listT
{-# INLINE toSet #-}

toSetIO :: Ord a => TSet a -> IO (Set a)
toSetIO = foldIO (\s x -> pure $! S.insert x s) S.empty
{-# INLINE toSetIO #-}

foldIO :: (b -> a -> IO b) -> b -> TSet a -> IO b
foldIO f acc0 = go acc0 . SS.listT
  where
    go acc l = atomically (ListT.uncons l) >>= maybe (pure acc) (\(x, l') -> f acc x >>= (`go` l'))
{-# INLINE foldIO #-}
