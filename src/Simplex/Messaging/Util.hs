{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Simplex.Messaging.Util where

import qualified Control.Exception as E
import Control.Monad.Except
import Control.Monad.IO.Unlift
import Control.Monad.Trans.Except
import Data.Bifunctor (first)
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Function (on)
import Data.List (sortBy)
import Data.Text (Text)
import qualified Data.Text as T
import UnliftIO.Async

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
f <$?> m = either fail pure . f =<< m
{-# INLINE (<$?>) #-}

bshow :: Show a => a -> ByteString
bshow = B.pack . show
{-# INLINE bshow #-}

tshow :: Show a => a -> Text
tshow = T.pack . show
{-# INLINE tshow #-}

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

tryE :: Monad m => ExceptT e m a -> ExceptT e m (Either e a)
tryE m = (Right <$> m) `catchE` (pure . Left)
{-# INLINE tryE #-}

liftE :: (e -> e') -> ExceptT e IO a -> ExceptT e' IO a
liftE f a = ExceptT $ first f <$> runExceptT a
{-# INLINE liftE #-}

ifM :: Monad m => m Bool -> m a -> m a -> m a
ifM ba t f = ba >>= \b -> if b then t else f
{-# INLINE ifM #-}

whenM :: Monad m => m Bool -> m () -> m ()
whenM b a = ifM b a $ pure ()
{-# INLINE whenM #-}

unlessM :: Monad m => m Bool -> m () -> m ()
unlessM b = ifM b $ pure ()
{-# INLINE unlessM #-}

($>>=) :: (Monad m, Monad f, Traversable f) => m (f a) -> (a -> m (f b)) -> m (f b)
f $>>= g = f >>= fmap join . mapM g

catchAll :: IO a -> (E.SomeException -> IO a) -> IO a
catchAll = E.catch
{-# INLINE catchAll #-}

catchAll_ :: IO a -> IO a -> IO a
catchAll_ a = catchAll a . const
{-# INLINE catchAll_ #-}

eitherToMaybe :: Either a b -> Maybe b
eitherToMaybe = either (const Nothing) Just
{-# INLINE eitherToMaybe #-}

-- | Uses a function to determine which of two output lists an input element should join
partitionWith :: (a -> Either b c) -> [a] -> ([b], [c])
partitionWith _ [] = ([], [])
partitionWith f (x : xs) = case f x of
  Left b -> (b : bs, cs)
  Right c -> (bs, c : cs)
  where
    (bs, cs) = partitionWith f xs

taggedEither :: (i, Either a b) -> Either (i, a) (i, b)
taggedEither = \case
  (t, Left a) -> Left (t, a)
  (t, Right b) -> Right (t, b)

sortTagged :: Ord i => [(i, a)] -> [a]
sortTagged = map snd . sortBy (compare `on` fst)
