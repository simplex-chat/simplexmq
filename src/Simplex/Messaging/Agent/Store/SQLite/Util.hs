module Simplex.Messaging.Agent.Store.SQLite.Util where

import Control.Exception (SomeException, catch, mask_)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Database.SQLite3.Direct (Database (..), FuncArgs (..), FuncContext (..))
import Database.SQLite3.Bindings
import Foreign.C.String
import Foreign.Ptr
import Foreign.StablePtr

data CFuncPtrs = CFuncPtrs (FunPtr CFunc) (FunPtr CFunc) (FunPtr CFuncFinal)

type SQLiteFunc = Ptr CContext -> CArgCount -> Ptr (Ptr CValue) -> IO ()

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
