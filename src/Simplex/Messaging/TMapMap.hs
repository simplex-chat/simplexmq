{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}

module Simplex.Messaging.TMapMap
  ( TMapMap,
    Simplex.Messaging.TMapMap.lookup,
    insert,
    delete,
  )
where

import Control.Concurrent.STM
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Util (whenM, ($>>=))

type TMapMap k1 k2 a = TMap k1 (TMap k2 a)

lookup :: (Ord k1, Ord k2) => k1 -> k2 -> TMapMap k1 k2 a -> STM (Maybe a)
lookup k1 k2 m = TM.lookup k1 m $>>= (TM.lookup k2)

insert :: (Ord k1, Ord k2) => k1 -> k2 -> a -> TMapMap k1 k2 a -> STM ()
insert k1 k2 v m =
  TM.lookup k1 m >>= \case
    Just m' -> TM.insert k2 v m'
    _ -> do
      m' <- TM.singleton k2 v
      TM.insert k1 m' m

delete :: (Ord k1, Ord k2) => k1 -> k2 -> TMapMap k1 k2 a -> STM ()
delete k1 k2 m =
  TM.lookup k1 m >>= mapM_ (\m' -> TM.delete k2 m' >> whenM (TM.null m') (TM.delete k1 m))
