{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}

module ChatTerminal.Editor where

import ChatTerminal.Core as C
import Control.Monad.IO.Class (liftIO)
import Styled
import System.Exit (exitSuccess)
import System.Terminal as T
import UnliftIO.STM

initTTY :: IO ()
initTTY = pure ()

updateInput :: ChatTerminal -> IO ()
updateInput ct@ChatTerminal {termSize, termState, nextMessageRow} = withTerminal . runTerminalT $ do
  hideCursor
  ts <- readTVarIO termState
  nmr <- readTVarIO nextMessageRow
  let (th, tw) = termSize
      ih = inputHeight ts ct
      iStart = th - ih
      prompt = inputPrompt ts
      (cRow, cCol) = positionRowColumn tw $ length prompt + inputPosition ts
  if nmr >= iStart
    then atomically $ writeTVar nextMessageRow iStart
    else clearLines nmr iStart
  setCursorPosition $ Position (max nmr iStart) 0
  putString $ prompt <> inputString ts <> " "
  eraseInLine EraseForward
  setCursorPosition $ Position (iStart + cRow) cCol
  showCursor
  flush
  where
    clearLines :: MonadTerminal m => Int -> Int -> m ()
    clearLines from till
      | from >= till = return ()
      | otherwise = do
        setCursorPosition $ Position from 0
        eraseInLine EraseForward
        clearLines (from + 1) till

printMessage :: ChatTerminal -> StyledString -> IO ()
printMessage ChatTerminal {termSize, nextMessageRow} msg = withTerminal . runTerminalT $ do
  nmr <- readTVarIO nextMessageRow
  setCursorPosition $ Position nmr 0
  let (th, tw) = termSize
  lc <- printLines tw msg
  atomically . writeTVar nextMessageRow $ min (th - 1) (nmr + lc)
  where
    printLines :: MonadTerminal m => Int -> StyledString -> m Int
    printLines tw ss = do
      let s = styledToANSITerm ss
          ls
            | null s = [""]
            | otherwise = lines s <> ["" | last s == '\n']
      print_ ls
      flush
      return $ foldl (\lc l -> lc + (length l `div` tw) + 1) 0 ls

    print_ :: MonadTerminal m => [String] -> m ()
    print_ [] = return ()
    print_ (l : ls) = do
      putString l
      eraseInLine EraseForward
      putString "\n"
      print_ ls

getKey :: IO C.Key
getKey = withTerminal $ runTerminalT readKey
  where
    readKey :: MonadTerminal m => m C.Key
    readKey =
      flush >> awaitEvent >>= \case
        Left Interrupt -> liftIO exitSuccess
        Right (KeyEvent key ms) -> pure $ eventToKey key ms
        _ -> readKey

    eventToKey :: T.Key -> Modifiers -> C.Key
    eventToKey key ms = case key of
      EscapeKey -> KeyEsc
      ArrowKey Upwards -> KeyUp
      ArrowKey Downwards -> KeyDown
      ArrowKey Leftwards -> KeyLeft
      ArrowKey Rightwards -> KeyRight
      EnterKey -> KeyEnter
      BackspaceKey -> KeyBack
      TabKey -> KeyTab
      CharKey c
        | ms == mempty || ms == shiftKey -> KeyChars [c]
        | otherwise -> KeyUnsupported
      _ -> KeyUnsupported

-- "\ESCb" -> KeyAltLeft
-- "\ESCf" -> KeyAltRight
-- "\ESC[1;5D" -> KeyCtrlLeft
-- "\ESC[1;5C" -> KeyCtrlRight
-- "\ESC[1;2D" -> KeyShiftLeft
-- "\ESC[1;2C" -> KeyShiftRight

-- keyChars cs = do
--   c <- getChar
--   more <- hReady stdin
--   -- for debugging - uncomment this, comment line after:
--   -- (if more then keyChars else \c' -> print (reverse c') >> return c') (c : cs)
--   (if more then keyChars else return) (c : cs)
