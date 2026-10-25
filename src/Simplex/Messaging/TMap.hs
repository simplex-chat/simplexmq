module Simplex.Messaging.TMap
  ( TMap,
    emptyIO,
    empty,
    fromMapIO,
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
    lookupInsert,
    lookupDelete,
    adjust,
    update,
    alter,
    alterF,
    union,
    replace,
    toMap,
    toMapIO,
    flush,
    foldIO,
    sizeIO,
  )
where

import Control.Concurrent.STM
import Data.Hashable (Hashable)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Data.Maybe (isJust)
import qualified ListT
import qualified StmContainers.Map as SM

type TMap k a = SM.Map k a

emptyIO :: IO (TMap k a)
emptyIO = SM.newIO
{-# INLINE emptyIO #-}

empty :: STM (TMap k a)
empty = SM.new
{-# INLINE empty #-}

fromMapIO :: Hashable k => Map k a -> IO (TMap k a)
fromMapIO m' = do
  m <- SM.newIO
  atomically $ union m' m
  pure m
{-# INLINE fromMapIO #-}

singleton :: Hashable k => k -> a -> STM (TMap k a)
singleton k v = do
  m <- SM.new
  SM.insert v k m
  pure m
{-# INLINE singleton #-}

clear :: TMap k a -> STM ()
clear = SM.reset
{-# INLINE clear #-}

null :: TMap k a -> STM Bool
null = SM.null
{-# INLINE null #-}

lookup :: Hashable k => k -> TMap k a -> STM (Maybe a)
lookup = SM.lookup
{-# INLINE lookup #-}

lookupIO :: Hashable k => k -> TMap k a -> IO (Maybe a)
lookupIO k = atomically . SM.lookup k
{-# INLINE lookupIO #-}

member :: Hashable k => k -> TMap k a -> STM Bool
member k m = isJust <$> SM.lookup k m
{-# INLINE member #-}

memberIO :: Hashable k => k -> TMap k a -> IO Bool
memberIO k = atomically . member k
{-# INLINE memberIO #-}

insert :: Hashable k => k -> a -> TMap k a -> STM ()
insert k v = SM.insert v k
{-# INLINE insert #-}

insertM :: Hashable k => k -> STM a -> TMap k a -> STM ()
insertM k f m = (\v -> SM.insert v k m) =<< f
{-# INLINE insertM #-}

delete :: Hashable k => k -> TMap k a -> STM ()
delete = SM.delete
{-# INLINE delete #-}

lookupInsert :: Hashable k => k -> a -> TMap k a -> STM (Maybe a)
lookupInsert k v m = SM.lookup k m <* SM.insert v k m
{-# INLINE lookupInsert #-}

lookupDelete :: Hashable k => k -> TMap k a -> STM (Maybe a)
lookupDelete k m = SM.lookup k m <* SM.delete k m
{-# INLINE lookupDelete #-}

adjust :: Hashable k => (a -> a) -> k -> TMap k a -> STM ()
adjust f k m = mapM_ (\v -> SM.insert (f v) k m) =<< SM.lookup k m
{-# INLINE adjust #-}

update :: Hashable k => (a -> Maybe a) -> k -> TMap k a -> STM ()
update f k m = mapM_ (set k m . f) =<< SM.lookup k m
{-# INLINE update #-}

alter :: Hashable k => (Maybe a -> Maybe a) -> k -> TMap k a -> STM ()
alter f k m = set k m . f =<< SM.lookup k m
{-# INLINE alter #-}

alterF :: Hashable k => (Maybe a -> STM (Maybe a)) -> k -> TMap k a -> STM ()
alterF f k m = set k m =<< f =<< SM.lookup k m
{-# INLINE alterF #-}

union :: Hashable k => Map k a -> TMap k a -> STM ()
union m' m = mapM_ (\(k, v) -> SM.insert v k m) $ M.toList m'
{-# INLINE union #-}

replace :: Hashable k => Map k a -> TMap k a -> STM ()
replace m' m = SM.reset m >> union m' m
{-# INLINE replace #-}

toMap :: Ord k => TMap k a -> STM (Map k a)
toMap = fmap M.fromList . ListT.toList . SM.listT
{-# INLINE toMap #-}

toMapIO :: Ord k => TMap k a -> IO (Map k a)
toMapIO = foldIO (\m (k, v) -> pure $! M.insert k v m) M.empty
{-# INLINE toMapIO #-}

flush :: Ord k => TMap k a -> STM (Map k a)
flush m = toMap m <* SM.reset m
{-# INLINE flush #-}

foldIO :: (b -> (k, a) -> IO b) -> b -> TMap k a -> IO b
foldIO f acc0 = go acc0 . SM.listT
  where
    go acc l = atomically (ListT.uncons l) >>= maybe (pure acc) (\(kv, l') -> f acc kv >>= (`go` l'))
{-# INLINE foldIO #-}

sizeIO :: TMap k a -> IO Int
sizeIO = foldIO (\n _ -> pure $! n + 1) 0
{-# INLINE sizeIO #-}

set :: Hashable k => k -> TMap k a -> Maybe a -> STM ()
set k m = maybe (SM.delete k m) (\v -> SM.insert v k m)
{-# INLINE set #-}
