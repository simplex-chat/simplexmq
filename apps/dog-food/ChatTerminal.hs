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
inputHeight ts ct = (length (inputString ts) - 1) `div` fst (termSize ct) + 1

data Key
  = KeyLeft
  | KeyRight
  | KeyUp
  | KeyDown
  | KeyEnter
  | KeyDel
  | KeyTab
  | KeyEsc
  | KeyChars String

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
  race_ (receiveFromTTY' ct) (sendToTTY ct)

receiveFromTTY :: ChatTerminal -> IO ()
receiveFromTTY ct@ChatTerminal {inputQ} =
  forever $ getChatLn ct >>= atomically . writeTBQueue inputQ

receiveFromTTY' :: ChatTerminal -> IO ()
receiveFromTTY' ct@ChatTerminal {inputQ, termState, nextMessageRow} = forever $ do
  key <- getKey
  -- InputState {inputString, inputHeight, inputPosition} <- readTVarIO inputState
  case key of
    KeyChars cs -> do
      -- when emptyInput insertActiveContact
      insertChars cs
      updateInput
    -- KeyDel -> deleteChar
    -- KeyEnter -> when (not emptyInput) submitInput
    -- KeyLeft -> moveCaret -1
    -- KeyRight -> moveCaret 1
    -- KeyUp -> return () -- moveCaret (0, -1)
    -- KeyDown -> return () -- moveCaret (0, 1)
    -- KeyEsc -> clearInput
    KeyTab -> do
      insertChars "    "
      updateInput
    _ -> return ()
  where
    insertChars :: String -> IO ()
    insertChars cs = do
      ts <- readTVarIO termState
      let s = inputString ts
          p = inputPosition ts
          (s', p') = if p >= length s then appendTo s else s `insertAt` p
      atomically $ writeTVar termState ts {inputString = s', inputPosition = p'}
      where
        appendTo :: String -> (String, Int)
        appendTo s = let s' = s <> cs in (s', length s')
        insertAt :: String -> Int -> (String, Int)
        insertAt s pos = let (b, a) = splitAt pos s in (b <> cs <> a, pos + length cs)

    updateInput = do
      C.hideCursor
      ts <- readTVarIO termState
      nmr <- readTVarIO nextMessageRow
      let (th, tw) = termSize ct
          ih = inputHeight ts ct
          iStart = th - ih
      if nmr >= iStart
        then do
          C.setCursorPosition nmr 0
          atomically $ writeTVar nextMessageRow iStart
        else do
          -- clearLines nmr iStart -- from to
          C.setCursorPosition iStart 0
      putStr (inputString ts)
      C.clearFromCursorToLineEnd
      let (row, col) = relativeCursorPosition tw (inputPosition ts)
      -- setCursor iStart tw (inputPosition ts)
      C.setCursorPosition (iStart + row) col
      C.showCursor
      where
        -- setCursor :: Int -> Int -> Int -> IO ()
        -- setCursor iStart tw pos = do
        --   let row = (pos - 1) `div` tw
        --       col = pos - row * tw
        --   C.setCursorPosition (iStart + row) col

        relativeCursorPosition :: Int -> Int -> (Int, Int)
        relativeCursorPosition width pos =
          let row = (pos - 1) `div` width
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
      "\DEL" -> KeyDel
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
