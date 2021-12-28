{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Simplex.Messaging.Util where

import Control.Monad.Except
import Control.Monad.IO.Unlift
import Control.Monad.Trans.Except
import Data.Bifunctor (first)
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import UnliftIO.Async
import UnliftIO.Exception (Exception)
import qualified UnliftIO.Exception as E

newtype InternalException e = InternalException {unInternalException :: e}
  deriving (Eq, Show)

instance Exception e => Exception (InternalException e)

instance (MonadUnliftIO m, Exception e) => MonadUnliftIO (ExceptT e m) where
  withRunInIO :: ((forall a. ExceptT e m a -> IO a) -> IO b) -> ExceptT e m b
  withRunInIO exceptToIO =
    withExceptT unInternalException . ExceptT . E.try $
      withRunInIO $ \run ->
        exceptToIO $ run . (either (E.throwIO . InternalException) return <=< runExceptT)

raceAny_ :: MonadUnliftIO m => [m a] -> m ()
raceAny_ = r []
  where
    r as (m : ms) = withAsync m $ \a -> r (a : as) ms
    r as [] = void $ waitAnyCancel as

infixl 4 <$$>, <$?>

(<$$>) :: (Functor f, Functor g) => (a -> b) -> f (g a) -> f (g b)
(<$$>) = fmap . fmap
{-# INLINE (<$$>) #-}

(<$?>) :: MonadFail m => (a -> Either String b) -> m a -> m b
f <$?> m = m >>= either fail pure . f
{-# INLINE (<$?>) #-}

bshow :: Show a => a -> ByteString
bshow = B.pack . show
{-# INLINE bshow #-}

maybeWord :: (a -> ByteString) -> Maybe a -> ByteString
maybeWord f = maybe "" $ B.cons ' ' . f
{-# INLINE maybeWord #-}

liftIOEither :: (MonadIO m, MonadError e m) => IO (Either e a) -> m a
liftIOEither a = liftIO a >>= liftEither
{-# INLINE liftIOEither #-}

liftError :: (MonadIO m, MonadError e' m) => (e -> e') -> ExceptT e IO a -> m a
liftError f = liftEitherError f . runExceptT
{-# INLINE liftError #-}

liftEitherError :: (MonadIO m, MonadError e' m) => (e -> e') -> IO (Either e a) -> m a
liftEitherError f a = liftIOEither (first f <$> a)
{-# INLINE liftEitherError #-}

tryError :: MonadError e m => m a -> m (Either e a)
tryError action = (Right <$> action) `catchError` (pure . Left)
{-# INLINE tryError #-}

handleError :: MonadError e m => (e -> m a) -> m a -> m a
handleError = flip catchError
{-# INLINE handleError #-}

tryE :: Monad m => ExceptT e m a -> ExceptT e m (Either e a)
tryE m = (Right <$> m) `catchE` (pure . Left)
{-# INLINE tryE #-}

ifM :: Monad m => m Bool -> m a -> m a -> m a
ifM ba t f = ba >>= \b -> if b then t else f
{-# INLINE ifM #-}

unlessM :: Monad m => m Bool -> m () -> m ()
unlessM b = ifM b $ pure ()
{-# INLINE unlessM #-}
