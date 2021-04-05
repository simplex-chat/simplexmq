{-# LANGUAGE LambdaCase #-}

module Terminal where

import Control.Monad.IO.Class (liftIO)
import Data.ByteString.Char8 (ByteString)
import Data.Functor (($>))
import qualified Data.Text as T
import Data.Text.Encoding (encodeUtf8, decodeUtf8With)
import System.Exit (exitSuccess)
import System.Terminal as C

getLn :: IO ByteString
getLn = encodeUtf8 . T.pack <$> withTerminal (runTerminalT getTermLine)

putLn :: ByteString -> IO ()
putLn s = withTerminal . runTerminalT . putStringLn . T.unpack $ decodeUtf8With onError s
  where
    onError _ _ = Just '?'

getTermLine :: MonadTerminal m => m String
getTermLine = getChars ""
  where
    getChars s = do
      awaitEvent >>= \case
        Right (KeyEvent key ms) -> case key of
          CharKey c
            | ms == mempty || ms == shiftKey -> addChar c
            | otherwise -> skip
          EnterKey -> C.putLn $> reverse s
          BackspaceKey -> do
            moveCursorBackward 1
            eraseChars 1
            getChars $ if null s then s else tail s
          _ -> skip
        _ -> liftIO exitSuccess
      where
        addChar c = C.putChar c >> getChars (c : s)
        skip = getChars s
