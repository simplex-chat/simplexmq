{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Simplex.Messaging.Session where

import Control.Concurrent.STM
import Control.Monad
import Data.Composition ((.:.))
import Data.Functor (($>))
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Util (($>>=))

data SessionVar a = SessionVar
  { sessionVar :: TMVar a,
    sessionVarId :: Int
  }

getSessVar :: forall k a. Ord k => TVar Int -> k -> TMap k (SessionVar a) -> STM (Either (SessionVar a) (SessionVar a))
getSessVar sessSeq sessKey vs = maybe (Left <$> newSessionVar) (pure . Right) =<< TM.lookup sessKey vs
  where
    newSessionVar :: STM (SessionVar a)
    newSessionVar = do
      sessionVar <- newEmptyTMVar
      sessionVarId <- stateTVar sessSeq $ \next -> (next, next + 1)
      let v = SessionVar {sessionVar, sessionVarId}
      TM.insert sessKey v vs
      pure v

removeSessVar :: Ord k => SessionVar a -> k -> TMap k (SessionVar a) -> STM ()
removeSessVar = void .:. removeSessVar'
{-# INLINE removeSessVar #-}

removeSessVar' :: Ord k => SessionVar a -> k -> TMap k (SessionVar a) -> STM Bool
removeSessVar' v sessKey vs =
  TM.lookup sessKey vs >>= \case
    Just v' | sessionVarId v == sessionVarId v' -> TM.delete sessKey vs $> True
    _ -> pure False

tryReadSessVar :: Ord k => k -> TMap k (SessionVar a) -> STM (Maybe a)
tryReadSessVar sessKey vs = TM.lookup sessKey vs $>>= (tryReadTMVar . sessionVar)
