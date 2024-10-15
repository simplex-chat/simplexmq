{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE RankNTypes #-}

module CoreTests.MsgStoreTests where

-- import Control.Concurrent (threadDelay)
import Control.Concurrent.STM
import Control.Exception (bracket)
import Data.ByteString.Char8 (ByteString)
import Data.Time.Clock.System (getSystemTime)
import Simplex.Messaging.Crypto (pattern MaxLenBS)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Protocol (EntityId (..), Message (..), noMsgFlags)
import Simplex.Messaging.Server.MsgStore.Journal
import Simplex.Messaging.Server.MsgStore.STM
import Simplex.Messaging.Server.MsgStore.Types
import Test.Hspec

msgStoreTests :: Spec
msgStoreTests = do
  around withSTMStore $ fdescribe "STM message store" $ someMsgStoreTests
  around withJournalStore $ fdescribe "Journal message store" $ someMsgStoreTests
  where
    someMsgStoreTests :: MsgStoreClass s => SpecWith s
    someMsgStoreTests = do
      it "should get queue" testGetQueue

withSTMStore :: (STMMsgStore -> IO ()) -> IO ()
withSTMStore = bracket newMsgStore (\_ -> pure ())

withJournalStore :: (JournalMsgStore -> IO ()) -> IO ()
withJournalStore =
  bracket
    (newJournalMsgStore "tests/tmp/messages" 5 =<< C.newRandom)
    (\_st -> pure ()) -- close all handles

testMessage :: ByteString -> IO Message
testMessage body = do
  g <- C.newRandom
  msgTs <- getSystemTime
  msgId <- atomically $ C.randomBytes 24 g
  pure Message {msgId, msgTs, msgFlags = noMsgFlags, msgBody = C.unsafeMaxLenBS body}

pattern Msg :: ByteString -> Maybe Message
pattern Msg s <- Just Message {msgBody = MaxLenBS s}

testGetQueue :: MsgStoreClass s => s -> IO ()
testGetQueue st = do
  g <- C.newRandom
  rId <- EntityId <$> atomically (C.randomBytes 24 g)
  q <- getMsgQueue st rId 128
  msg1 <- testMessage "message 1"
  Just (Message {msgId = mId1}, True) <- writeMsg q msg1
  msg2 <- testMessage "message 2"
  Just (Message {msgId = mId2}, False) <- writeMsg q msg2
  msg3 <- testMessage "message 3"
  Just (Message {msgId = mId3}, False) <- writeMsg q msg3
  Msg "message 1" <- tryPeekMsg q
  Msg "message 1" <- tryPeekMsg q
  Nothing <- tryDelMsg q mId2
  Msg "message 1" <- tryDelMsg q mId1
  Nothing <- tryDelMsg q mId1
  Msg "message 2" <- tryPeekMsg q
  Nothing <- tryDelMsg q mId1
  (Nothing, Msg "message 2") <- tryDelPeekMsg q mId1
  (Msg "message 2", Msg "message 3") <- tryDelPeekMsg q mId2
  (Nothing, Msg "message 3") <- tryDelPeekMsg q mId2
  Msg "message 3" <- tryPeekMsg q
  (Msg "message 3", Nothing) <- tryDelPeekMsg q mId3
  Nothing <- tryDelMsg q mId2
  Nothing <- tryDelMsg q mId3
  Nothing <- tryPeekMsg q
  delMsgQueue st rId
