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

import Control.Concurrent.Async (race_)
import Control.Concurrent.STM
import Control.Monad
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
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
    inputState :: TVar InputState,
    activeContact :: TVar (Maybe Contact)
  }

data InputState = InputState
  { inputString :: String,
    caretPosition :: Int
  }

newChatTerminal :: Natural -> STM ChatTerminal
newChatTerminal qSize = do
  inputQ <- newTBQueue qSize
  outputQ <- newTBQueue qSize
  inputState <- newTVar $ InputState "" 0
  activeContact <- newTVar Nothing
  return ChatTerminal {inputQ, outputQ, inputState, activeContact}

chatTerminal :: ChatTerminal -> IO ()
chatTerminal ct = race_ (receiveFromTTY ct) (sendToTTY ct)

receiveFromTTY :: ChatTerminal -> IO ()
receiveFromTTY ct@ChatTerminal {inputQ} =
  forever $ getChatLn ct >>= atomically . writeTBQueue inputQ

sendToTTY :: ChatTerminal -> IO ()
sendToTTY ChatTerminal {outputQ} =
  forever $ atomically (readTBQueue outputQ) >>= putLn stdout

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
