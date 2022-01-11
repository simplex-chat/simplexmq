{-# LANGUAGE RankNTypes #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Simplex.Messaging.Util where

import Control.Monad.Except
import Control.Monad.IO.Unlift
import Data.Bifunctor (first)
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import UnliftIO.Async

raceAny_ :: MonadUnliftIO m => [m a] -> m ()
raceAny_ = r []
  where
    r as (m : ms) = withAsync m $ \a -> r (a : as) ms
    r as [] = void $ waitAnyCancel as

infixl 4 <$$>, <$?>

(<$$>) :: (Functor f, Functor g) => (a -> b) -> f (g a) -> f (g b)
(<$$>) = fmap . fmap

(<$?>) :: MonadFail m => (a -> Either String b) -> m a -> m b
f <$?> m = m >>= either fail pure . f

bshow :: Show a => a -> ByteString
bshow = B.pack . show

liftIOEither :: (MonadIO m, MonadError e m) => IO (Either e a) -> m a
liftIOEither a = liftIO a >>= liftEither

liftError :: (MonadIO m, MonadError e' m) => (e -> e') -> ExceptT e IO a -> m a
liftError f = liftEitherError f . runExceptT

liftEitherError :: (MonadIO m, MonadError e' m) => (e -> e') -> IO (Either e a) -> m a
liftEitherError f a = liftIOEither (first f <$> a)

tryError :: MonadError e m => m a -> m (Either e a)
tryError action = (Right <$> action) `catchError` (pure . Left)

ifM :: Monad m => m Bool -> m a -> m a -> m a
ifM ba t f = ba >>= \b -> if b then t else f
{-# INLINE ifM #-}

unlessM :: Monad m => m Bool -> m () -> m ()
unlessM b = ifM b $ pure ()
{-# INLINE unlessM #-}
