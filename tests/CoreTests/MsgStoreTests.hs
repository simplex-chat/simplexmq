{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE RankNTypes #-}

module CoreTests.MsgStoreTests where

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
  around withSTMStore $ describe "STM message store" someMsgStoreTests
  around withJournalStore $ describe "Journal message store" someMsgStoreTests
  where
    someMsgStoreTests :: MsgStoreClass s => SpecWith s
    someMsgStoreTests = do
      it "should get queue and store/read messages" testGetQueue
      it "should not fail on EOF when changing read journal" testChangeReadJournal

withSTMStore :: (STMMsgStore -> IO ()) -> IO ()
withSTMStore =
  bracket
    (newMsgStore STMStoreConfig {storePath = Nothing, quota = 3})
    (\_ -> pure ())

withJournalStore :: (JournalMsgStore -> IO ()) -> IO ()
withJournalStore =
  bracket
    (newMsgStore testJournalStoreCfg)
    (\_st -> pure ()) -- close all handles

testJournalStoreCfg :: JournalStoreConfig
testJournalStoreCfg =
  JournalStoreConfig
    { storePath = "tests/tmp/messages",
      pathParts = 4,
      quota = 3,
      maxMsgCount = 4
    }

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
  q <- getMsgQueue st rId
  Just (Message {msgId = mId1}, True) <- writeMsg q =<< testMessage "message 1"
  Just (Message {msgId = mId2}, False) <- writeMsg q =<< testMessage "message 2"
  Just (Message {msgId = mId3}, False) <- writeMsg q =<< testMessage "message 3"
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
  Just (Message {msgId = mId4}, True) <- writeMsg q =<< testMessage "message 4"
  Msg "message 4" <- tryPeekMsg q
  Just (Message {msgId = mId5}, False) <- writeMsg q =<< testMessage "message 5"
  (Nothing, Msg "message 4") <- tryDelPeekMsg q mId3
  (Msg "message 4", Msg "message 5") <- tryDelPeekMsg q mId4
  Just (Message {msgId = mId6}, False) <- writeMsg q =<< testMessage "message 6"
  Just (Message {msgId = mId7}, False) <- writeMsg q =<< testMessage "message 7"
  Nothing <- writeMsg q =<< testMessage "message 8"
  Msg "message 5" <- tryPeekMsg q
  (Nothing, Msg "message 5") <- tryDelPeekMsg q mId4
  (Msg "message 5", Msg "message 6") <- tryDelPeekMsg q mId5
  (Msg "message 6", Msg "message 7") <- tryDelPeekMsg q mId6
  (Msg "message 7", Just MessageQuota {msgId = mId8}) <- tryDelPeekMsg q mId7
  (Just MessageQuota {}, Nothing) <- tryDelPeekMsg q mId8
  (Nothing, Nothing) <- tryDelPeekMsg q mId8
  delMsgQueue st rId

testChangeReadJournal :: MsgStoreClass s => s -> IO ()
testChangeReadJournal st = do
  g <- C.newRandom
  rId <- EntityId <$> atomically (C.randomBytes 24 g)
  q <- getMsgQueue st rId
  Just (Message {msgId = mId1}, True) <- writeMsg q =<< testMessage "message 1"
  (Msg "message 1", Nothing) <- tryDelPeekMsg q mId1
  Just (Message {msgId = mId2}, True) <- writeMsg q =<< testMessage "message 2"
  (Msg "message 2", Nothing) <- tryDelPeekMsg q mId2
  Just (Message {msgId = mId3}, True) <- writeMsg q =<< testMessage "message 3"
  (Msg "message 3", Nothing) <- tryDelPeekMsg q mId3
  Just (Message {msgId = mId4}, True) <- writeMsg q =<< testMessage "message 4"
  (Msg "message 4", Nothing) <- tryDelPeekMsg q mId4
  Just (Message {msgId = mId5}, True) <- writeMsg q =<< testMessage "message 5"
  (Msg "message 5", Nothing) <- tryDelPeekMsg q mId5
  delMsgQueue st rId
