{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Simplex.Messaging.Util where

import qualified Control.Exception as E
import Control.Monad
import Control.Monad.Except
import Control.Monad.IO.Unlift
import Data.Bifunctor (first)
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Int (Int64)
import Data.List (groupBy, sortOn)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as L
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (decodeUtf8With)
import Data.Time (NominalDiffTime)
import GHC.Conc (labelThread, myThreadId, threadDelay)
import UnliftIO
import qualified UnliftIO.Exception as UE

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

liftEitherWith :: MonadError e' m => (e -> e') -> Either e a -> m a
liftEitherWith f = liftEither . first f
{-# INLINE liftEitherWith #-}

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

tryAllErrors :: (MonadUnliftIO m, MonadError e m) => (E.SomeException -> e) -> m a -> m (Either e a)
tryAllErrors err action = tryError action `UE.catch` (pure . Left . err)
{-# INLINE tryAllErrors #-}

catchAllErrors :: (MonadUnliftIO m, MonadError e m) => (E.SomeException -> e) -> m a -> (e -> m a) -> m a
catchAllErrors err action handler = tryAllErrors err action >>= either handler pure
{-# INLINE catchAllErrors #-}

catchThrow :: (MonadUnliftIO m, MonadError e m) => m a -> (E.SomeException -> e) -> m a
catchThrow action err = catchAllErrors err action throwError
{-# INLINE catchThrow #-}

allFinally :: (MonadUnliftIO m, MonadError e m) => (E.SomeException -> e) -> m a -> m b -> m a
allFinally err action final = tryAllErrors err action >>= \r -> final >> either throwError pure r
{-# INLINE allFinally #-}

eitherToMaybe :: Either a b -> Maybe b
eitherToMaybe = either (const Nothing) Just
{-# INLINE eitherToMaybe #-}

groupOn :: Eq k => (a -> k) -> [a] -> [[a]]
groupOn = groupBy . eqOn
  where
    -- it is equivalent to groupBy ((==) `on` f),
    -- but it redefines `on` to avoid duplicate computation for most values.
    -- source: https://hackage.haskell.org/package/extra-1.7.13/docs/src/Data.List.Extra.html#groupOn
    -- the on2 in this package is specialized to only use `==` as the function, `eqOn f` is equivalent to `(==) `on` f`
    eqOn f x = let fx = f x in \y -> fx == f y

groupAllOn :: Ord k => (a -> k) -> [a] -> [[a]]
groupAllOn f = groupOn f . sortOn f

toChunks :: Int -> [a] -> [NonEmpty a]
toChunks _ [] = []
toChunks n xs =
  let (ys, xs') = splitAt n xs
   in maybe id (:) (L.nonEmpty ys) (toChunks n xs')

safeDecodeUtf8 :: ByteString -> Text
safeDecodeUtf8 = decodeUtf8With onError
  where
    onError _ _ = Just '?'

timeoutThrow :: (MonadUnliftIO m, MonadError e m) => e -> Int -> m a -> m a
timeoutThrow e ms action = timeout ms action >>= maybe (throwError e) pure

threadDelay' :: Int64 -> IO ()
threadDelay' time
  | time <= 0 = pure ()
threadDelay' time = do
  let maxWait = min time $ fromIntegral (maxBound :: Int)
  threadDelay $ fromIntegral maxWait
  when (maxWait /= time) $ threadDelay' (time - maxWait)

diffToMicroseconds :: NominalDiffTime -> Int64
diffToMicroseconds diff = fromIntegral ((truncate $ diff * 1000000) :: Integer)

diffToMilliseconds :: NominalDiffTime -> Int64
diffToMilliseconds diff = fromIntegral ((truncate $ diff * 1000) :: Integer)

labelMyThread :: MonadIO m => String -> m ()
labelMyThread label = liftIO $ myThreadId >>= (`labelThread` label)
