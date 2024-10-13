{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

module CoreTests.MsgStoreTests where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM
import Control.Exception (bracket)
import Data.ByteString.Char8 (ByteString)
import Data.Time.Clock.System (getSystemTime)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Protocol (EntityId (..), Message (..), noMsgFlags)
import Simplex.Messaging.Server.Env.STM
import Simplex.Messaging.Server.MsgStore.Journal
import Simplex.Messaging.Server.MsgStore.STM
import Simplex.Messaging.Server.MsgStore.Types
import Test.Hspec

msgStoreTests :: Spec
msgStoreTests = do
  around withSTMStore $ fdescribe "STM message store" $ someMsgStoreTests
  around withJournalStore $ fdescribe "Journal message store" $ someMsgStoreTests
  where
    someMsgStoreTests :: SpecWith AMsgStore
    someMsgStoreTests = do
      it "should get queue" testGetQueue

withSTMStore :: (AMsgStore -> IO ()) -> IO ()
withSTMStore = bracket (AMS SMSMemory <$> newMsgStore) (\_ -> pure ())

withJournalStore :: (AMsgStore -> IO ()) -> IO ()
withJournalStore =
  bracket
    (AMS SMSJournal <$> (newJournalMsgStore "tests/tmp/messages" 5 =<< C.newRandom))
    (\_st -> pure ()) -- close all handles

testMessage :: ByteString -> IO Message
testMessage body = do
  g <- C.newRandom
  msgTs <- getSystemTime
  msgId <- atomically $ C.randomBytes 24 g
  pure Message {msgId, msgTs, msgFlags = noMsgFlags, msgBody = C.unsafeMaxLenBS body}

testGetQueue :: AMsgStore -> IO ()
testGetQueue st = do
  g <- C.newRandom
  rId <- atomically $ C.randomBytes 24 g
  q <- getMsgQueue st (EntityId rId) 128
  msg1 <- testMessage "message 1"
  Just (Message {msgId = mId1}, True) <- writeMsg q msg1
  msg2 <- testMessage "message 2"
  Just (Message {msgId = mId2}, False) <- writeMsg q msg2
  msg3 <- testMessage "message 3"
  Just (Message {msgId = mId3}, False) <- writeMsg q msg3
  Just Message {msgBody = C.MaxLenBS "message 1"} <- tryPeekMsg q
  Just Message {msgBody = C.MaxLenBS "message 1"} <- tryPeekMsg q
  Nothing <- tryDelMsg q mId2
  Just Message {msgBody = C.MaxLenBS "message 1"} <- tryDelMsg q mId1
  Nothing <- tryDelMsg q mId1
  Just Message {msgBody = C.MaxLenBS "message 2"} <- tryPeekMsg q
  Nothing <- tryDelMsg q mId1
  Just Message {msgBody = C.MaxLenBS "message 2"} <- tryDelMsg q mId2
  Nothing <- tryDelMsg q mId2
  pure ()
