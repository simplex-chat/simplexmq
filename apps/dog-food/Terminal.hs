{-# LANGUAGE LambdaCase #-}

module Terminal where

import Control.Monad.IO.Class (liftIO)
import Data.ByteString.Char8 (ByteString)
import qualified Data.Text as T
import Data.Text.Encoding (decodeUtf8With, encodeUtf8)
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
    getChars s = awaitEvent >>= processKey s
    processKey s = \case
      Right (KeyEvent key ms) -> case key of
        CharKey c
          | ms == mempty || ms == shiftKey -> do
            C.putChar c
            flush
            getChars (c : s)
          | otherwise -> getChars s
        EnterKey -> do
          C.putLn
          flush
          pure $ reverse s
        BackspaceKey -> do
          moveCursorBackward 1
          eraseChars 1
          flush
          getChars $ if null s then s else tail s
        _ -> getChars s
      Left Interrupt -> liftIO exitSuccess
      _ -> getChars s
