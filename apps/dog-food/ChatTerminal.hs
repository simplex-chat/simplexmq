{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module ChatTerminal
  ( ChatTerminal (..),
    newChatTerminal,
    chatTerminal,
    ttyContact,
    ttyFromContact,
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (race_)
import Control.Concurrent.STM
import Control.Monad
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Maybe (fromMaybe)
import qualified Data.Text as T
import Data.Text.Encoding
import Numeric.Natural
import Simplex.Messaging.Transport (getLn, putLn)
import qualified System.Console.ANSI as C
import System.IO
import Types

data ChatTerminal = ChatTerminal
  { inputQ :: TBQueue ByteString,
    outputQ :: TBQueue ByteString,
    activeContact :: TVar (Maybe Contact),
    termState :: TVar TerminalState,
    termSize :: (Int, Int),
    nextMessageRow :: TVar Int
  }

data TerminalState = TerminalState
  { inputString :: String,
    inputPosition :: Int
  }

inputHeight :: TerminalState -> ChatTerminal -> Int
inputHeight ts ct = length (inputString ts) `div` snd (termSize ct) + 1

data Key
  = KeyLeft
  | KeyRight
  | KeyUp
  | KeyDown
  | KeyEnter
  | KeyBack
  | KeyTab
  | KeyEsc
  | KeyChars String
  deriving (Eq)

newChatTerminal :: Natural -> IO ChatTerminal
newChatTerminal qSize = do
  inputQ <- newTBQueueIO qSize
  outputQ <- newTBQueueIO qSize
  activeContact <- newTVarIO Nothing
  termSize <- fromMaybe (0, 0) <$> C.getTerminalSize
  let lastRow = fst termSize - 1
  termState <- newTVarIO $ TerminalState {inputString = "", inputPosition = 0}
  nextMessageRow <- newTVarIO lastRow
  threadDelay 500000 -- this delay is the same as timeout in getTerminalSize
  return ChatTerminal {inputQ, outputQ, activeContact, termState, termSize, nextMessageRow}

chatTerminal :: ChatTerminal -> IO ()
chatTerminal ct = do
  hSetBuffering stdin NoBuffering
  hSetBuffering stdout NoBuffering
  hSetEcho stdin False
  let receive = if termSize ct == (0, 0) then receiveFromTTY else receiveFromTTY'
  race_ (receive ct) (sendToTTY ct)

receiveFromTTY :: ChatTerminal -> IO ()
receiveFromTTY ct@ChatTerminal {inputQ} =
  forever $ getChatLn ct >>= atomically . writeTBQueue inputQ

receiveFromTTY' :: ChatTerminal -> IO ()
receiveFromTTY' ct@ChatTerminal {inputQ, termState, nextMessageRow} =
  forever $
    getKey >>= atomically . processKey >> updateInput
  where
    processKey :: Key -> STM ()
    processKey = \case
      KeyEnter -> submitInput
      key -> modifyTVar termState $ updateTermState key

    submitInput :: STM ()
    submitInput = do
      ts <- readTVar termState
      writeTVar termState $ ts {inputString = "", inputPosition = 0}
      writeTBQueue inputQ . B.pack $ inputString ts

    updateTermState :: Key -> TerminalState -> TerminalState
    updateTermState key ts@TerminalState {inputString = s, inputPosition = p} = case key of
      KeyChars cs -> insertChars cs
      KeyTab -> insertChars "    "
      KeyBack -> backDeleteChar
      KeyLeft -> setPosition $ max 0 (p - 1)
      KeyRight -> setPosition $ min (length s) (p + 1)
      _ -> ts
      where
        insertChars = ts' . if p >= length s then append else insert
        append cs = let s' = s <> cs in (s', length s')
        insert cs = let (b, a) = splitAt p s in (b <> cs <> a, p + length cs)
        backDeleteChar
          | p == 0 || null s = ts
          | p >= length s = ts' backDeleteLast
          | otherwise = ts' backDelete
        backDeleteLast = if null s then (s, 0) else let s' = init s in (s', length s')
        backDelete = let (b, a) = splitAt p s in (init b <> a, p - 1)
        setPosition p' = ts' (s, p')
        ts' (s', p') = ts {inputString = s', inputPosition = p'}

    updateInput :: IO ()
    updateInput = do
      C.hideCursor
      ts <- readTVarIO termState
      nmr <- readTVarIO nextMessageRow
      let (th, tw) = termSize ct
          ih = inputHeight ts ct
          iStart = th - ih
      if nmr >= iStart
        then atomically $ writeTVar nextMessageRow iStart
        else clearLines nmr iStart
      C.setCursorPosition (max nmr iStart) 0
      putStr $ inputString ts <> " "
      C.clearFromCursorToLineEnd
      let (row, col) = relativeCursorPosition tw (inputPosition ts)
      C.setCursorPosition (iStart + row) col
      C.showCursor
      where
        clearLines :: Int -> Int -> IO ()
        clearLines from till
          | from >= till = return ()
          | otherwise = do
            C.setCursorPosition from 0
            C.clearFromCursorToLineEnd
            clearLines (from + 1) till

        relativeCursorPosition :: Int -> Int -> (Int, Int)
        relativeCursorPosition width pos =
          let row = pos `div` width
              col = pos - row * width
           in (row, col)

sendToTTY :: ChatTerminal -> IO ()
sendToTTY ChatTerminal {outputQ} =
  forever $ atomically (readTBQueue outputQ) >>= putLn stdout

getKey :: IO Key
getKey = charsToKey . reverse <$> keyChars ""
  where
    charsToKey = \case
      "\ESC" -> KeyEsc
      "\ESC[A" -> KeyUp
      "\ESC[B" -> KeyDown
      "\ESC[C" -> KeyRight
      "\ESC[D" -> KeyLeft
      "\n" -> KeyEnter
      "\DEL" -> KeyBack
      "\t" -> KeyTab
      cs -> KeyChars cs

    keyChars cs = do
      c <- getChar
      more <- hReady stdin
      (if more then keyChars else return) (c : cs)

getChatLn :: ChatTerminal -> IO ByteString
getChatLn ct = do
  setTTY NoBuffering
  getChar >>= \case
    '/' -> getRest "/"
    '@' -> getRest "@"
    ch -> do
      let s = encodeUtf8 $ T.singleton ch
      readTVarIO (activeContact ct) >>= \case
        Nothing -> getRest s
        Just a -> getWithContact a s
  where
    getWithContact :: Contact -> ByteString -> IO ByteString
    getWithContact a s = do
      C.cursorBackward 1
      B.hPut stdout $ ttyToContact a <> " " <> s
      getRest $ "@" <> toBs a <> " " <> s
    getRest :: ByteString -> IO ByteString
    getRest s = do
      setTTY LineBuffering
      (s <>) <$> getLn stdin

setTTY :: BufferMode -> IO ()
setTTY mode = do
  hSetBuffering stdin mode
  hSetBuffering stdout mode

ttyContact :: Contact -> ByteString
ttyContact (Contact a) = withSGR contactSGR a

ttyFromContact :: Contact -> ByteString
ttyFromContact (Contact a) = withSGR contactSGR $ a <> ">"

ttyToContact :: Contact -> ByteString
ttyToContact (Contact a) = withSGR selfSGR $ "@" <> a

contactSGR :: [C.SGR]
contactSGR = [C.SetColor C.Foreground C.Vivid C.Yellow]

selfSGR :: [C.SGR]
selfSGR = [C.SetColor C.Foreground C.Vivid C.Cyan]

withSGR :: [C.SGR] -> ByteString -> ByteString
withSGR sgr s = B.pack (C.setSGRCode sgr) <> s <> B.pack (C.setSGRCode [C.Reset])
