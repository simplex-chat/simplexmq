module Simplex.Messaging.Util where

import Control.Monad.Except
import Control.Monad.IO.Unlift
import UnliftIO.Async
import UnliftIO.Exception (Exception)
import qualified UnliftIO.Exception as E

instance (MonadUnliftIO m, Exception e) => MonadUnliftIO (ExceptT e m) where
  withRunInIO inner = ExceptT . E.try $
    withRunInIO $ \run ->
      inner (run . (either E.throwIO pure <=< runExceptT))

raceAny_ :: MonadUnliftIO m => [m a] -> m ()
raceAny_ = r []
  where
    r as (m : ms) = withAsync m $ \a -> r (a : as) ms
    r as [] = void $ waitAnyCancel as

infixl 4 <$$>

(<$$>) :: (Functor f, Functor g) => (a -> b) -> f (g a) -> f (g b)
(<$$>) = fmap . fmap
