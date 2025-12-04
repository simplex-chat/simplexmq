module Simplex.Messaging.Agent.Store.SQLite.Util where

import Control.Exception (SomeException, catch, mask_)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Data.IORef
import Database.SQLite3.Direct (Database (..), FuncArgs (..), FuncContext (..))
import Database.SQLite3.Bindings
import Foreign.C.String
import Foreign.Ptr
import Foreign.StablePtr
import Foreign.Storable

data CFuncPtrs = CFuncPtrs (FunPtr CFunc) (FunPtr CFunc) (FunPtr CFuncFinal)

type SQLiteFunc = Ptr CContext -> CArgCount -> Ptr (Ptr CValue) -> IO ()

type SQLiteFuncFinal = Ptr CContext -> IO ()

mkSQLiteFunc :: (FuncContext -> FuncArgs -> IO ()) -> SQLiteFunc
mkSQLiteFunc f cxt nArgs cvals = catchAsResultError cxt $ f (FuncContext cxt) (FuncArgs nArgs cvals)
{-# INLINE mkSQLiteFunc #-}

-- Based on createFunction from Database.SQLite3.Direct, but uses static function pointer to avoid dynamic wrapper that triggers DCL.
createStaticFunction :: Database -> ByteString -> CArgCount -> Bool -> FunPtr SQLiteFunc -> IO (Either Error ())
createStaticFunction (Database db) name nArgs isDet funPtr = mask_ $ do
  u <- newStablePtr $ CFuncPtrs funPtr nullFunPtr nullFunPtr
  let flags = if isDet then c_SQLITE_DETERMINISTIC else 0
  B.useAsCString name $ \namePtr ->
    toResult () <$> c_sqlite3_create_function_v2 db namePtr nArgs flags (castStablePtrToPtr u) funPtr nullFunPtr nullFunPtr nullFunPtr

mkSQLiteAggStep :: a -> (FuncContext -> FuncArgs -> a -> IO a) -> SQLiteFunc
mkSQLiteAggStep initSt xStep cxt nArgs cvals = catchAsResultError cxt $ do
  -- we store the aggregate state in the buffer returned by
  -- c_sqlite3_aggregate_context as a StablePtr pointing to an IORef that
  -- contains the actual aggregate state
  aggCtx <- getAggregateContext cxt
  aggStPtr <- peek aggCtx
  aggStRef <-
    if castStablePtrToPtr aggStPtr /= nullPtr
      then deRefStablePtr aggStPtr
      else do
        aggStRef <- newIORef initSt
        aggStPtr' <- newStablePtr aggStRef
        poke aggCtx aggStPtr'
        return aggStRef
  aggSt <- readIORef aggStRef
  aggSt' <- xStep (FuncContext cxt) (FuncArgs nArgs cvals) aggSt
  writeIORef aggStRef aggSt'

mkSQLiteAggFinal :: a -> (FuncContext -> a -> IO ()) -> SQLiteFuncFinal
mkSQLiteAggFinal initSt xFinal cxt = do
  aggCtx <- getAggregateContext cxt
  aggStPtr <- peek aggCtx
  if castStablePtrToPtr aggStPtr == nullPtr
    then catchAsResultError cxt $ xFinal (FuncContext cxt) initSt
    else do
      catchAsResultError cxt $ do
        aggStRef <- deRefStablePtr aggStPtr
        aggSt <- readIORef aggStRef
        xFinal (FuncContext cxt) aggSt
      freeStablePtr aggStPtr

getAggregateContext :: Ptr CContext -> IO (Ptr a)
getAggregateContext cxt = c_sqlite3_aggregate_context cxt stPtrSize
  where
    stPtrSize = fromIntegral $ sizeOf (undefined :: StablePtr ())

-- Based on createAggregate from Database.SQLite3.Direct, but uses static function pointers to avoid dynamic wrappers that trigger DCL.
createStaticAggregate :: Database -> ByteString -> CArgCount -> FunPtr SQLiteFunc -> FunPtr SQLiteFuncFinal -> IO (Either Error ())
createStaticAggregate (Database db) name nArgs stepPtr finalPtr = mask_ $ do
  u <- newStablePtr $ CFuncPtrs nullFunPtr stepPtr finalPtr
  B.useAsCString name $ \namePtr ->
    toResult () <$> c_sqlite3_create_function_v2 db namePtr nArgs 0 (castStablePtrToPtr u) nullFunPtr stepPtr finalPtr nullFunPtr

-- Convert a 'CError' to a 'Either Error', in the common case where
-- SQLITE_OK signals success and anything else signals an error.
--
-- Note that SQLITE_OK == 0.
toResult :: a -> CError -> Either Error a
toResult a (CError 0) = Right a
toResult _ code = Left $ decodeError code

-- call c_sqlite3_result_error in the event of an error
catchAsResultError :: Ptr CContext -> IO () -> IO ()
catchAsResultError ctx action = catch action $ \exn -> do
  let msg = show (exn :: SomeException)
  withCAStringLen msg $ \(ptr, len) ->
    c_sqlite3_result_error ctx ptr (fromIntegral len)
