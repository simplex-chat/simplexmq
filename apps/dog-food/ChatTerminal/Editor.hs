{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE ScopedTypeVariables #-}

module ChatTerminal.Editor where

import ChatTerminal.Basic
import ChatTerminal.Core
import Styled
import System.Terminal
import UnliftIO.STM

-- debug :: MonadTerminal m => String -> m ()
-- debug s = do
--   saveCursor
--   setCursorPosition $ Position 0 0
--   putString s
--   restoreCursor

updateInput :: forall m. MonadTerminal m => ChatTerminal -> m ()
updateInput ct@ChatTerminal {termSize, termState, nextMessageRow} = do
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
    clearLines :: Int -> Int -> m ()
    clearLines from till
      | from >= till = return ()
      | otherwise = do
        setCursorPosition $ Position from 0
        eraseInLine EraseForward
        clearLines (from + 1) till

printMessage :: MonadTerminal m => ChatTerminal -> StyledString -> m ()
printMessage ChatTerminal {termSize, nextMessageRow} msg = do
  nmr <- readTVarIO nextMessageRow
  setCursorPosition $ Position nmr 0
  let (th, tw) = termSize
      lc = sLength msg `div` tw + 1
  putStyled msg
  eraseInLine EraseForward
  putLn
  flush
  atomically . writeTVar nextMessageRow $ min (th - 1) (nmr + lc)
