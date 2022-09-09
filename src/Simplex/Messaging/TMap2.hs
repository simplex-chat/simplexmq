{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}

module Simplex.Messaging.TMap2
  ( TMap2,
    empty,
    clear,
    Simplex.Messaging.TMap2.lookup,
    lookup1,
    member,
    insert,
    insert1,
    delete,
    lookupDelete1,
  )
where

import Control.Concurrent.STM
import Control.Monad (forM_, (>=>))
import qualified Data.Map.Strict as M
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Util (whenM, ($>>=))

-- | this type is designed for k2 being unique in the whole data, to allow direct access both via k1 and via k2
data TMap2 k1 k2 a = TMap2
  { _m1 :: TMap k1 (TMap k2 a),
    _m2 :: TMap k2 k1
  }

empty :: STM (TMap2 k1 k2 a)
empty = TMap2 <$> TM.empty <*> TM.empty

clear :: TMap2 k1 k2 a -> STM ()
clear TMap2 {_m1, _m2} = TM.clear _m1 >> TM.clear _m2

lookup :: (Ord k1, Ord k2) => k2 -> TMap2 k1 k2 a -> STM (Maybe a)
lookup k2 TMap2 {_m1, _m2} = do
  TM.lookup k2 _m2 $>>= (`TM.lookup` _m1) $>>= TM.lookup k2

lookup1 :: Ord k1 => k1 -> TMap2 k1 k2 a -> STM (Maybe (TMap k2 a))
lookup1 k1 TMap2 {_m1} = TM.lookup k1 _m1
{-# INLINE lookup1 #-}

member :: Ord k2 => k2 -> TMap2 k1 k2 a -> STM Bool
member k2 TMap2 {_m2} = TM.member k2 _m2
{-# INLINE member #-}

insert :: (Ord k1, Ord k2) => k1 -> k2 -> a -> TMap2 k1 k2 a -> STM ()
insert k1 k2 v TMap2 {_m1, _m2} =
  TM.lookup k2 _m2 >>= \case
    Just k1'
      | k1 == k1' -> _insert1
      | otherwise -> _delete1 k1' k2 _m1 >> _insert2
    _ -> _insert2
  where
    _insert1 =
      TM.lookup k1 _m1 >>= \case
        Just m -> TM.insert k2 v m
        _ -> TM.singleton k2 v >>= \m -> TM.insert k1 m _m1
    _insert2 = TM.insert k2 k1 _m2 >> _insert1

insert1 :: (Ord k1, Ord k2) => k1 -> TMap k2 a -> TMap2 k1 k2 a -> STM ()
insert1 k1 m' TMap2 {_m1, _m2} =
  TM.lookup k1 _m1 >>= \case
    Just m -> readTVar m' >>= (`TM.union` m)
    _ -> TM.insert k1 m' _m1

delete :: (Ord k1, Ord k2) => k2 -> TMap2 k1 k2 a -> STM ()
delete k2 TMap2 {_m1, _m2} = TM.lookupDelete k2 _m2 >>= mapM_ (\k1 -> _delete1 k1 k2 _m1)

_delete1 :: (Ord k1, Ord k2) => k1 -> k2 -> TMap k1 (TMap k2 a) -> STM ()
_delete1 k1 k2 m1 =
  TM.lookup k1 m1
    >>= mapM_ (\m -> TM.delete k2 m >> whenM (TM.null m) (TM.delete k1 m1))

lookupDelete1 :: (Ord k1, Ord k2) => k1 -> TMap2 k1 k2 a -> STM (Maybe (TMap k2 a))
lookupDelete1 k1 TMap2 {_m1, _m2} = do
  m_ <- TM.lookupDelete k1 _m1
  forM_ m_ $ readTVar >=> modifyTVar' _m2 . flip M.withoutKeys . M.keysSet
  pure m_
