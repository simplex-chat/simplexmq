{-# LANGUAGE MonadComprehensions #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Simplex.Messaging.Util where

import qualified Control.Exception as E
import Control.Monad
import Control.Monad.Except
import Control.Monad.IO.Unlift
import Control.Monad.Trans.Except
import Control.Monad.Trans.State.Strict (StateT (..))
import Data.Aeson (FromJSON, ToJSON)
import qualified Data.Aeson as J
import Data.Bifunctor (first, second)
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy.Char8 as LB
import Data.IORef
import Data.Int (Int64)
import Data.List (groupBy, sortOn)
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as L
import Data.Maybe (listToMaybe)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (decodeUtf8With, encodeUtf8)
import Data.Time (NominalDiffTime)
import Data.Tuple (swap)
import GHC.Conc (labelThread, myThreadId, threadDelay)
import UnliftIO hiding (atomicModifyIORef')
import qualified UnliftIO.Exception as UE

raceAny_ :: MonadUnliftIO m => [m a] -> m ()
raceAny_ = r []
  where
    r as (m : ms) = withAsync m $ \a -> r (a : as) ms
    r as [] = void $ waitAnyCancel as

infixl 4 <$$>, <$$, <$?>

(<$$>) :: (Functor f, Functor g) => (a -> b) -> f (g a) -> f (g b)
(<$$>) = fmap . fmap
{-# INLINE (<$$>) #-}

(<$$) :: (Functor f, Functor g) => b -> f (g a) -> f (g b)
(<$$) = fmap . fmap . const
{-# INLINE (<$$) #-}

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

liftError :: MonadIO m => (e -> e') -> ExceptT e IO a -> ExceptT e' m a
liftError f = liftError' f . runExceptT
{-# INLINE liftError #-}

liftError' :: MonadIO m => (e -> e') -> IO (Either e a) -> ExceptT e' m a
liftError' f = ExceptT . fmap (first f) . liftIO
{-# INLINE liftError' #-}

liftEitherWith :: MonadIO m => (e -> e') -> Either e a -> ExceptT e' m a
liftEitherWith f = liftEither . first f
{-# INLINE liftEitherWith #-}

ifM :: Monad m => m Bool -> m a -> m a -> m a
ifM ba t f = ba >>= \b -> if b then t else f
{-# INLINE ifM #-}

whenM :: Monad m => m Bool -> m () -> m ()
whenM b a = ifM b a $ pure ()
{-# INLINE whenM #-}

unlessM :: Monad m => m Bool -> m () -> m ()
unlessM b = ifM b $ pure ()
{-# INLINE unlessM #-}

anyM :: Monad m => [m Bool] -> m Bool
anyM = foldM (\r a -> if r then pure r else (r ||) <$!> a) False
{-# INLINE anyM #-}

infixl 1  $>>, $>>=

($>>=) :: (Monad m, Monad f, Traversable f) => m (f a) -> (a -> m (f b)) -> m (f b)
f $>>= g = f >>= fmap join . mapM g
{-# INLINE ($>>=) #-}

($>>) :: (Monad m, Monad f, Traversable f) => m (f a) -> m (f b) -> m (f b)
f $>> g = f $>>= \_ -> g
{-# INLINE ($>>) #-}

mapME :: (Monad m, Traversable t) => (a -> m (Either e b)) -> t (Either e a) -> m (t (Either e b))
mapME f = mapM (bindRight f)
{-# INLINE mapME #-}

bindRight :: Monad m => (a -> m (Either e b)) -> Either e a -> m (Either e b)
bindRight = either (pure . Left)
{-# INLINE bindRight #-}

forME :: (Monad m, Traversable t) => t (Either e a) -> (a -> m (Either e b)) -> m (t (Either e b))
forME = flip mapME
{-# INLINE forME #-}


-- | Monadic version of mapAccumL
-- Copied from ghc-9.6.3 package: https://hackage.haskell.org/package/ghc-9.12.1/docs/GHC-Utils-Monad.html#v:mapAccumLM
-- for backward compatibility with 8.10.7.
mapAccumLM :: (Monad m, Traversable t)
            => (acc -> x -> m (acc, y)) -- ^ combining function
            -> acc                      -- ^ initial state
            -> t x                      -- ^ inputs
            -> m (acc, t y)             -- ^ final state, outputs
{-# INLINE [1] mapAccumLM #-}
-- INLINE pragma.  mapAccumLM is called in inner loops.  Like 'map',
-- we inline it so that we can take advantage of knowing 'f'.
-- This makes a few percent difference (in compiler allocations)
-- when compiling perf/compiler/T9675
mapAccumLM f s = fmap swap . flip runStateT s . traverse f'
  where
    f' = StateT . (fmap . fmap) swap . flip f
{-# RULES "mapAccumLM/List" mapAccumLM = mapAccumLM_List #-}
{-# RULES "mapAccumLM/NonEmpty" mapAccumLM = mapAccumLM_NonEmpty #-}

mapAccumLM_List
 :: Monad m
 => (acc -> x -> m (acc, y))
 -> acc -> [x] -> m (acc, [y])
{-# INLINE mapAccumLM_List #-}
mapAccumLM_List f = go
  where
    go s (x : xs) = do
      (s1, x')  <- f s x
      (s2, xs') <- go s1 xs
      return    (s2, x' : xs')
    go s [] = return (s, [])

mapAccumLM_NonEmpty
 :: Monad m
 => (acc -> x -> m (acc, y))
 -> acc -> NonEmpty x -> m (acc, NonEmpty y)
{-# INLINE mapAccumLM_NonEmpty #-}
mapAccumLM_NonEmpty f s (x :| xs) =
  [(s2, x' :| xs') | (s1, x') <- f s x, (s2, xs') <- mapAccumLM_List f s1 xs]

tryWriteTBQueue :: TBQueue a -> a -> STM Bool
tryWriteTBQueue q a = do
  full <- isFullTBQueue q
  unless full $ writeTBQueue q a
  pure $ not full
{-# INLINE tryWriteTBQueue #-}

catchAll :: IO a -> (E.SomeException -> IO a) -> IO a
catchAll = E.catch
{-# INLINE catchAll #-}

catchAll_ :: IO a -> IO a -> IO a
catchAll_ a = catchAll a . const
{-# INLINE catchAll_ #-}

tryAllErrors :: MonadUnliftIO m => (E.SomeException -> e) -> ExceptT e m a -> ExceptT e m (Either e a)
tryAllErrors err action = ExceptT $ Right <$> runExceptT action `UE.catch` (pure . Left . err)
{-# INLINE tryAllErrors #-}

tryAllErrors' :: MonadUnliftIO m => (E.SomeException -> e) -> ExceptT e m a -> m (Either e a)
tryAllErrors' err action = runExceptT action `UE.catch` (pure . Left . err)
{-# INLINE tryAllErrors' #-}

catchAllErrors :: MonadUnliftIO m => (E.SomeException -> e) -> ExceptT e m a -> (e -> ExceptT e m a) -> ExceptT e m a
catchAllErrors err action handler = tryAllErrors err action >>= either handler pure
{-# INLINE catchAllErrors #-}

catchAllErrors' :: MonadUnliftIO m => (E.SomeException -> e) -> ExceptT e m a -> (e -> m a) -> m a
catchAllErrors' err action handler = tryAllErrors' err action >>= either handler pure
{-# INLINE catchAllErrors' #-}

catchThrow :: MonadUnliftIO m => ExceptT e m a -> (E.SomeException -> e) -> ExceptT e m a
catchThrow action err = catchAllErrors err action throwE
{-# INLINE catchThrow #-}

allFinally :: MonadUnliftIO m => (E.SomeException -> e) -> ExceptT e m a -> ExceptT e m b -> ExceptT e m a
allFinally err action final = tryAllErrors err action >>= \r -> final >> either throwE pure r
{-# INLINE allFinally #-}

eitherToMaybe :: Either a b -> Maybe b
eitherToMaybe = either (const Nothing) Just
{-# INLINE eitherToMaybe #-}

listToEither :: e -> [a] -> Either e a
listToEither _ (x : _) = Right x
listToEither e _ = Left e

firstRow :: (a -> b) -> e -> IO [a] -> IO (Either e b)
firstRow f e a = second f . listToEither e <$> a

maybeFirstRow :: Functor f => (a -> b) -> f [a] -> f (Maybe b)
maybeFirstRow f q = fmap f . listToMaybe <$> q

firstRow' :: (a -> Either e b) -> e -> IO [a] -> IO (Either e b)
firstRow' f e a = (f <=< listToEither e) <$> a

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

timeoutThrow :: MonadUnliftIO m => e -> Int -> ExceptT e m a -> ExceptT e m a
timeoutThrow e ms action = ExceptT (sequence <$> (ms `timeout` runExceptT action)) >>= maybe (throwE e) pure

threadDelay' :: Int64 -> IO ()
threadDelay' = loop
  where
    loop time
      | time <= 0 = pure ()
      | otherwise = do
          let maxWait = min time $ fromIntegral (maxBound :: Int)
          threadDelay $ fromIntegral maxWait
          loop $ time - maxWait

diffToMicroseconds :: NominalDiffTime -> Int64
diffToMicroseconds diff = truncate $ diff * 1000000
{-# INLINE diffToMicroseconds #-}

diffToMilliseconds :: NominalDiffTime -> Int64
diffToMilliseconds diff = truncate $ diff * 1000
{-# INLINE diffToMilliseconds #-}

labelMyThread :: MonadIO m => String -> m ()
labelMyThread label = liftIO $ myThreadId >>= (`labelThread` label)

atomicModifyIORef'_ :: IORef a -> (a -> a) -> IO ()
atomicModifyIORef'_ r f = atomicModifyIORef' r (\v -> (f v, ()))

encodeJSON :: ToJSON a => a -> Text
encodeJSON = safeDecodeUtf8 . LB.toStrict . J.encode

decodeJSON :: FromJSON a => Text -> Maybe a
decodeJSON = J.decode . LB.fromStrict . encodeUtf8

traverseWithKey_ :: Monad m => (k -> v -> m ()) -> Map k v -> m ()
traverseWithKey_ f = M.foldrWithKey (\k v -> (f k v >>)) (pure ())
{-# INLINE traverseWithKey_ #-}
