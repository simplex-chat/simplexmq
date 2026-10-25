{-# LANGUAGE CPP #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# OPTIONS_GHC -fno-warn-ambiguous-fields #-}

module CoreTests.MsgStoreTests where

import AgentTests.FunctionalAPITests (runRight_)
import Control.Concurrent.STM
import Control.Exception (bracket)
import Control.Monad
import Control.Monad.IO.Class
import Control.Monad.Trans.Except
import Crypto.Random (ChaChaDRG)
import Data.ByteString.Char8 (ByteString)
import Data.Int (Int64)
import qualified Data.Map.Strict as M
import Data.Time.Clock.System (SystemTime (..), getSystemTime)
import Simplex.Messaging.Crypto (pattern MaxLenBS)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Protocol (EncDataBytes (..), EntityId (..), ErrorType (..), LinkId, Message (..), NotifierId, QueueLinkData, RecipientId, SParty (..), noMsgFlags, randomMsgId)
import Simplex.Messaging.Server.MsgStore.STM
import Simplex.Messaging.Server.MsgStore.Types
import Simplex.Messaging.Server.NtfStore
import Simplex.Messaging.Server.QueueStore
import Simplex.Messaging.Server.QueueStore.QueueInfo
import Simplex.Messaging.Server.QueueStore.STM (STMQueueStore (..))
import Simplex.Messaging.Server.QueueStore.Types
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM
import Test.Hspec hiding (fit, it)
import Util

#if defined(dbServerPostgres)
import AgentTests.FunctionalAPITests (runRight)
import Control.Concurrent (threadDelay)
import Database.PostgreSQL.Simple (Only (..))
import qualified Database.PostgreSQL.Simple as DB
import Simplex.Messaging.Agent.Store.Postgres.Common
import Simplex.Messaging.Agent.Store.Shared (MigrationConfirmation (..))
import Simplex.Messaging.Server.MsgStore.Postgres
import Simplex.Messaging.Server.QueueStore.Postgres
import SMPClient (testStoreDBOpts)
#endif

msgStoreTests :: Spec
msgStoreTests = do
  describe "STM message store" $ do
    someMsgStoreTests testSMTStoreConfig
    it "should remove deleted queues from queue store maps" $ withMsgStore testSMTStoreConfig testDeleteQueueMaps
#if defined(dbServerPostgres)
  describe "Postgres-only message store" $ do
    someMsgStoreTests testPostgresStoreConfig
    it "should correctly update message counts and canWrite flag" $ withMsgStore testPostgresStoreConfig testUpdateMessageCounts
    it "tryDelPeekMsg (ACK not from NSE) should reset message counts when queue is empty" $ withMsgStore testPostgresStoreConfig testResetMessageCounts
    it "should expire messages across commit batches" $ withMsgStore testPostgresStoreConfig testExpireMessagesInBatches
#endif
  describe "Notification store" $ do
    it "should remove keys of expired notifications" testExpireNtfs
    it "should remove keys of delivered notifications" testDeleteEmptyNtfs
  where
    someMsgStoreTests :: MsgStoreClass s => (HasTestEnv => MsgStoreConfig s) -> Spec
    someMsgStoreTests cfg = do
      it "should get queue and store/read messages" $ withMsgStore cfg testGetQueue
      it "should write/ack messages" $ withMsgStore cfg testWriteAckMessages
      it "should not add link data to secured messaging queue" $ withMsgStore cfg testLinkDataSecuredQueue

-- TODO constrain to STM stores?
withMsgStore :: MsgStoreClass s => MsgStoreConfig s -> (s -> IO ()) -> IO ()
withMsgStore cfg = bracket (newMsgStore cfg) closeMsgStore

testSMTStoreConfig :: STMStoreConfig
testSMTStoreConfig = STMStoreConfig {storePath = Nothing, quota = 3}

#if defined(dbServerPostgres)
testPostgresStoreConfig :: HasTestEnv => PostgresMsgStoreCfg
testPostgresStoreConfig =
  PostgresMsgStoreCfg
    { queueStoreCfg = testPostgresStoreCfg,
      quota = 3
    }

testPostgresStoreCfg :: HasTestEnv => PostgresStoreCfg
testPostgresStoreCfg =
  PostgresStoreCfg
    { dbOpts = testStoreDBOpts,
      dbStoreLogPath = Nothing,
      confirmMigrations = MCYesUp,
      deletedTTL = 86400
    }
#endif

mkMessage :: MonadIO m => ByteString -> m Message
mkMessage body = liftIO $ do
  g <- C.newRandom
  msgTs <- getSystemTime
  msgId <- atomically $ randomMsgId 24 g
  pure Message {msgId, msgTs, msgFlags = noMsgFlags, msgBody = C.unsafeMaxLenBS body}

pattern Msg :: ByteString -> Maybe Message
pattern Msg s <- Just Message {msgBody = MaxLenBS s}

testNewQueueRec :: TVar ChaChaDRG -> QueueMode -> IO (RecipientId, QueueRec)
testNewQueueRec g qm = testNewQueueRecData g qm Nothing

testNewQueueRecData :: TVar ChaChaDRG -> QueueMode -> Maybe (LinkId, QueueLinkData) -> IO (RecipientId, QueueRec)
testNewQueueRecData g qm queueData = do
  rId <- rndId
  senderId <- rndId
  (rKey, _) <- atomically $ C.generateAuthKeyPair C.SEd25519 g
  (k, pk) <- atomically $ C.generateKeyPair @'C.X25519 g
  let qr =
        QueueRec
          { recipientKeys = [rKey],
            rcvDhSecret = C.dh' k pk,
            senderId,
            senderKey = Nothing,
            queueMode = Just qm,
            queueData,
            notifier = Nothing,
            status = EntityActive,
            updatedAt = Nothing,
            rcvServiceId = Nothing
          }
  pure (rId, qr)
  where
    rndId = atomically $ EntityId <$> C.randomBytes 24 g

testNtfCreds :: TVar ChaChaDRG -> IO NtfCreds
testNtfCreds g = do
  (notifierKey, _) <- atomically $ C.generateAuthKeyPair C.SX25519 g
  (k, pk) <- atomically $ C.generateKeyPair @'C.X25519 g
  pure
    NtfCreds
      { notifierId = EntityId "ijkl",
        notifierKey,
        rcvNtfDhSecret = C.dh' k pk,
        ntfServiceId = Nothing
      }

testGetQueue :: MsgStoreClass s => s -> IO ()
testGetQueue ms = do
  g <- C.newRandom
  (rId, qr) <- testNewQueueRec g QMMessaging
  runRight_ $ do
    q <- ExceptT $ addQueue ms rId qr
    let write s = writeMsg ms q True =<< mkMessage s
    Just (Message {msgId = mId1}, True) <- write "message 1"
    Just (Message {msgId = mId2}, False) <- write "message 2"
    Just (Message {msgId = mId3}, False) <- write "message 3"
    Msg "message 1" <- tryPeekMsg ms q
    Msg "message 1" <- tryPeekMsg ms q
    Nothing <- tryDelMsg ms q mId2
    Msg "message 1" <- tryDelMsg ms q mId1
    Nothing <- tryDelMsg ms q mId1
    Msg "message 2" <- tryPeekMsg ms q
    Nothing <- tryDelMsg ms q mId1
    (Nothing, Msg "message 2") <- tryDelPeekMsg ms q mId1
    (Msg "message 2", Msg "message 3") <- tryDelPeekMsg ms q mId2
    (Nothing, Msg "message 3") <- tryDelPeekMsg ms q mId2
    Msg "message 3" <- tryPeekMsg ms q
    (Msg "message 3", Nothing) <- tryDelPeekMsg ms q mId3
    Nothing <- tryDelMsg ms q mId2
    Nothing <- tryDelMsg ms q mId3
    Nothing <- tryPeekMsg ms q
    Just (Message {msgId = mId4}, True) <- write "message 4"
    Msg "message 4" <- tryPeekMsg ms q
    Just (Message {msgId = mId5}, False) <- write "message 5"
    (Nothing, Msg "message 4") <- tryDelPeekMsg ms q mId3
    (Msg "message 4", Msg "message 5") <- tryDelPeekMsg ms q mId4
    Just (Message {msgId = mId6}, False) <- write "message 6"
    Just (Message {msgId = mId7}, False) <- write "message 7"
    Nothing <- write "message 8"
    Msg "message 5" <- tryPeekMsg ms q
    (Nothing, Msg "message 5") <- tryDelPeekMsg ms q mId4
    (Msg "message 5", Msg "message 6") <- tryDelPeekMsg ms q mId5
    (Msg "message 6", Msg "message 7") <- tryDelPeekMsg ms q mId6
    (Msg "message 7", Just MessageQuota {msgId = mId8}) <- tryDelPeekMsg ms q mId7
    (Just MessageQuota {}, Nothing) <- tryDelPeekMsg ms q mId8
    (Nothing, Nothing) <- tryDelPeekMsg ms q mId8
    void $ ExceptT $ deleteQueue ms q

-- TODO [messages] test concurrent writing and reading
testWriteAckMessages :: MsgStoreClass s => s -> IO ()
testWriteAckMessages ms = do
  g <- C.newRandom
  (rId1, qr1) <- testNewQueueRec g QMMessaging
  (rId2, qr2) <- testNewQueueRec g QMMessaging
  runRight_ $ do
    q1 <- ExceptT $ addQueue ms rId1 qr1
    q2 <- ExceptT $ addQueue ms rId2 qr2
    let write q s = writeMsg ms q True =<< mkMessage s
    0 <- deleteExpiredMsgs ms q1 0 -- won't expire anything, used here to mimic message sending with expiration on SEND
    Just (Message {msgId = mId1}, True) <- write q1 "message 1"
    (Msg "message 1", Nothing) <- tryDelPeekMsg ms q1 mId1
    0 <- deleteExpiredMsgs ms q2 0
    Just (Message {msgId = mId2}, True) <- write q2 "message 2"
    (Msg "message 2", Nothing) <- tryDelPeekMsg ms q2 mId2
    0 <- deleteExpiredMsgs ms q2 0
    Just (Message {msgId = mId3}, True) <- write q2 "message 3"
    (Msg "message 3", Nothing) <- tryDelPeekMsg ms q2 mId3
    void $ ExceptT $ deleteQueue ms q1
    void $ ExceptT $ deleteQueue ms q2

testLinkDataSecuredQueue :: MsgStoreClass s => s -> IO ()
testLinkDataSecuredQueue ms = do
  g <- C.newRandom
  (sKey, _) <- atomically $ C.generateAuthKeyPair C.SEd25519 g
  let st = queueStore ms
      ld = (EncDataBytes "fixed data", EncDataBytes "user data")
      rndId = atomically $ EntityId <$> C.randomBytes 24 g
  (rId, qr) <- testNewQueueRec g QMMessaging
  (cId, cqr) <- testNewQueueRec g QMContact
  lnkId <- rndId
  cLnkId <- rndId
  runRight_ $ do
    q <- ExceptT $ addQueue ms rId qr
    -- the handle is read before SKEY, as in a command that raced with it
    staleQ <- ExceptT $ getQueue ms SRecipient rId
    ExceptT $ secureQueue st q sKey
    liftIO $ addQueueLinkData st staleQ lnkId ld `shouldReturn` Left AUTH
    freshQ <- ExceptT $ getQueue ms SRecipient rId
    liftIO $ getQueueLinkData st freshQ lnkId `shouldReturn` Left AUTH
    cq <- ExceptT $ addQueue ms cId cqr
    ExceptT $ secureQueue st cq sKey
    ExceptT $ addQueueLinkData st cq cLnkId ld
    ld' <- ExceptT $ getQueueLinkData st cq cLnkId
    liftIO $ ld' `shouldBe` ld
    void $ ExceptT $ deleteQueue ms q
    void $ ExceptT $ deleteQueue ms cq

-- sizes of queues, senders, links and notifiers maps
type QueueMapSizes = (Int, Int, Int, Int)

queueMapSizes :: STMMsgStore -> IO QueueMapSizes
queueMapSizes ms = (,,,) <$> size queues <*> size senders <*> size links <*> size notifiers
  where
    STMQueueStore {queues, senders, links, notifiers} = queueStore ms
    size :: TMap k v -> IO Int
    size = fmap M.size . readTVarIO

testDeleteQueueMaps :: STMMsgStore -> IO ()
testDeleteQueueMaps ms = do
  g <- C.newRandom
  ntfCreds <- testNtfCreds g
  let newLinkId = atomically $ EntityId <$> C.randomBytes 24 g
  lnkId1 <- newLinkId
  lnkId2 <- newLinkId
  lnkId3 <- newLinkId
  (rId1, qr1) <- testNewQueueRec g QMMessaging
  (rId2, qr2) <- testNewQueueRecData g QMContact (Just (lnkId1, testLinkData))
  (rId3, qr3) <- testNewQueueRec g QMMessaging
  (rId4, qr4) <- testNewQueueRec g QMMessaging
  let rIds = [rId1, rId2, rId3, rId4] :: [RecipientId]
      sIds = map senderId [qr1, qr2, qr3, qr4]
      lnkIds = [lnkId1, lnkId2, lnkId3] :: [LinkId]
  queueMapSizes ms `shouldReturn` (0, 0, 0, 0)
  runRight_ $ do
    q1 <- ExceptT $ addQueue ms rId1 qr1 {notifier = Just ntfCreds}
    q2 <- ExceptT $ addQueue ms rId2 qr2
    q3 <- ExceptT $ addQueue ms rId3 qr3
    q4 <- ExceptT $ addQueue ms rId4 qr4
    ExceptT $ addQueueLinkData (queueStore ms) q3 lnkId2 testLinkData
    ExceptT $ addQueueLinkData (queueStore ms) q4 lnkId3 testLinkData
    forM_ sIds $ void . ExceptT . getQueue ms SSender
    forM_ lnkIds $ void . ExceptT . getQueue ms SSenderLink
    liftIO $ queueMapSizes ms `shouldReturn` (4, 4, 3, 1)
    ExceptT $ deleteQueueLinkData (queueStore ms) q3
    liftIO $ queueMapSizes ms `shouldReturn` (4, 4, 2, 1)
    forM_ ([q1, q2, q3, q4] :: [STMQueue]) $ void . ExceptT . deleteQueue ms
  queueMapSizes ms `shouldReturn` (0, 0, 0, 0)
  forM_ rIds $ \rId -> getQueue ms SRecipient rId >>= expectAuth
  forM_ sIds $ \sId -> getQueue ms SSender sId >>= expectAuth
  forM_ lnkIds $ \lnkId -> getQueue ms SSenderLink lnkId >>= expectAuth
  queueMapSizes ms `shouldReturn` (0, 0, 0, 0)
  where
    expectAuth = either (`shouldBe` AUTH) (\_ -> expectationFailure "deleted queue is still found")

mkMsgNtf :: TVar ChaChaDRG -> Int64 -> IO MsgNtf
mkMsgNtf g ts = do
  ntfMsgId <- atomically $ randomMsgId 24 g
  ntfNonce <- atomically $ C.randomCbNonce g
  pure MsgNtf {ntfMsgId, ntfTs = MkSystemTime ts 0, ntfNonce, ntfEncMeta = "meta"}

ntfCounts :: NtfStore -> IO [(NotifierId, Int)]
ntfCounts (NtfStore ns) = M.assocs <$> (mapM (fmap length . readTVarIO) =<< readTVarIO ns)

testExpireNtfs :: IO ()
testExpireNtfs = do
  g <- C.newRandom
  st@(NtfStore ns) <- NtfStore <$> TM.emptyIO
  now <- systemSeconds <$> getSystemTime
  let old = now - 100
      nId1 = EntityId "notifier 1"
      nId2 = EntityId "notifier 2"
      nId3 = EntityId "notifier 3"
  storeNtf st nId1 =<< mkMsgNtf g old
  storeNtf st nId2 =<< mkMsgNtf g old
  storeNtf st nId2 =<< mkMsgNtf g now
  atomically $ TM.insertM nId3 (newTVar []) ns
  ntfCounts st `shouldReturn` [(nId1, 1), (nId2, 2), (nId3, 0)]
  deleteExpiredNtfs st (now - 50) `shouldReturn` 2
  ntfCounts st `shouldReturn` [(nId2, 1)]
  storeNtf st nId1 =<< mkMsgNtf g now
  deleteExpiredNtfs st (now - 50) `shouldReturn` 0
  ntfCounts st `shouldReturn` [(nId1, 1), (nId2, 1)]

testDeleteEmptyNtfs :: IO ()
testDeleteEmptyNtfs = do
  g <- C.newRandom
  st@(NtfStore ns) <- NtfStore <$> TM.emptyIO
  now <- systemSeconds <$> getSystemTime
  let nId1 = EntityId "notifier 1"
      nId2 = EntityId "notifier 2"
      nId3 = EntityId "notifier 3"
      nId4 = EntityId "notifier 4"
  forM_ ([nId1, nId2, nId3, nId4] :: [NotifierId]) $ \nId -> storeNtf st nId =<< mkMsgNtf g now
  ntfs <- M.assocs <$> readTVarIO ns
  let flush nId = forM_ (lookup nId ntfs) $ \v -> atomically $ writeTVar v []
  mapM_ flush ([nId1, nId2, nId4] :: [NotifierId])
  storeNtf st nId2 =<< mkMsgNtf g now
  deleteNtfs st nId4 `shouldReturn` 0
  storeNtf st nId4 =<< mkMsgNtf g now
  deleteEmptyNtfs st ntfs
  ntfCounts st `shouldReturn` [(nId2, 1), (nId3, 1), (nId4, 1)]

testLinkData :: QueueLinkData
testLinkData = (EncDataBytes "fixed data", EncDataBytes "user data")

#if defined(dbServerPostgres)
testUpdateMessageCounts :: PostgresMsgStore -> IO ()
testUpdateMessageCounts ms = do
  g <- C.newRandom
  (rId, qr) <- testNewQueueRec g QMMessaging
  runRight_ $ do
    q <- ExceptT $ addQueue ms rId qr
    let write s = writeMsg ms q True =<< mkMessage s
        hasSize = checkQueueSize ms
    q `hasSize` (0, True)
    Just (Message {msgId = mId1}, True) <- write "message 1"
    q `hasSize` (1, True)
    Just (Message {msgId = mId2}, False) <- write "message 2"
    q `hasSize` (2, True)
    Just (Message {msgId = mId3}, False) <- write "message 3"
    q `hasSize` (3, True)
    Nothing <- write "message 4"
    q `hasSize` (4, False)
    Msg "message 1" <- tryPeekMsg ms q
    q `hasSize` (4, False)
    Msg "message 1" <- tryDelMsg ms q mId1
    q `hasSize` (3, False)
    Msg "message 2" <- tryPeekMsg ms q
    (Msg "message 2", Msg "message 3") <- tryDelPeekMsg ms q mId2
    q `hasSize` (2, False)
    (Msg "message 3", Just MessageQuota {msgId = mId4}) <- tryDelPeekMsg ms q mId3
    q `hasSize` (1, False)
    (Just MessageQuota {}, Nothing) <- tryDelPeekMsg ms q mId4
    q `hasSize` (0, True)

checkQueueSize :: PostgresMsgStore -> PostgresQueue -> (Int64, Bool) -> ExceptT ErrorType IO ()
checkQueueSize ms q (size, canWrt) = liftIO $ do
  [(size', canWrt')] <-
    withTransaction (dbStore $ queueStore ms) $ \db ->
      DB.query db "SELECT msg_queue_size, msg_can_write FROM msg_queues WHERE recipient_id = ?" (Only (recipientId q))
  size' `shouldBe` size
  canWrt' `shouldBe` canWrt

testResetMessageCounts :: PostgresMsgStore -> IO ()
testResetMessageCounts ms = do
  g <- C.newRandom
  (rId, qr) <- testNewQueueRec g QMMessaging
  runRight_ $ do
    q <- ExceptT $ addQueue ms rId qr
    let write s = writeMsg ms q True =<< mkMessage s
        hasSize = checkQueueSize ms
    Just (Message {msgId = mId1}, True) <- write "message 1"
    Just (Message {msgId = mId2}, False) <- write "message 2"
    Just (Message {msgId = mId3}, False) <- write "message 3"
    Nothing <- write "message 4"
    q `hasSize` (4, False)
    liftIO $ setIncorrectSize q (10, True)
    Nothing <- write "message 5"
    q `hasSize` (11, False)
    (Msg "message 1", Msg "message 2") <- tryDelPeekMsg ms q mId1
    q `hasSize` (10, False)
    (Msg "message 2", Msg "message 3") <- tryDelPeekMsg ms q mId2
    q `hasSize` (9, False)
    (Msg "message 3", Just MessageQuota {msgId = mId4}) <- tryDelPeekMsg ms q mId3
    q `hasSize` (8, False)
    (Just MessageQuota {}, Just MessageQuota {msgId = mId5}) <- tryDelPeekMsg ms q mId4
    q `hasSize` (7, False)
    (Just MessageQuota {}, Nothing) <- tryDelPeekMsg ms q mId5
    q `hasSize` (0, True) -- reset
  where
    setIncorrectSize :: PostgresQueue -> (Int64, Bool) -> IO ()
    setIncorrectSize q (size, canWrt) =
      void $ withTransaction (dbStore $ queueStore ms) $ \db ->
        DB.execute db "UPDATE msg_queues SET msg_queue_size = ?, msg_can_write = ? WHERE recipient_id = ?" (size, canWrt, recipientId q)

testExpireMessagesInBatches :: PostgresMsgStore -> IO ()
testExpireMessagesInBatches ms = do
  g <- C.newRandom
  emptiedQs <- replicateM emptiedCount $ newQueue g
  partialQs <- replicateM partialCount $ newQueue g
  overQuotaQs <- replicateM overQuotaCount $ newQueue g
  quotaMsgs <- runRight $ do
    forM_ (emptiedQs <> partialQs) $ \q -> void $ write q "old 1"
    forM_ emptiedQs $ \q -> void $ write q "old 2"
    mapM fillPastQuota overQuotaQs
  -- msg_ts has second granularity, so the recent messages need a new second to be kept
  threadDelay 1100000
  boundary <- systemSeconds <$> getSystemTime
  runRight_ $ forM_ partialQs $ \q -> void $ write q "recent"

  MessageStats {expiredMsgsCount, storedMsgsCount, storedQueues} <- expireOldMessages False ms boundary 0
  expiredMsgsCount `shouldBe` (emptiedCount * 2 + partialCount + sum quotaMsgs)
  storedMsgsCount `shouldBe` (partialCount + overQuotaCount) -- recent messages and quota markers
  storedQueues `shouldBe` (emptiedCount + partialCount + overQuotaCount)
  runRight_ $ do
    forM_ emptiedQs $ \q -> checkQueueSize ms q (0, True)
    forM_ partialQs $ \q -> checkQueueSize ms q (1, True)
    -- the quota marker is never expired, and the queue stays blocked until it is acked
    forM_ overQuotaQs $ \q -> checkQueueSize ms q (1, False)
  where
    -- expire_old_messages pages through expired messages and commits per page, so these
    -- counts put a page boundary inside each group of queues.
    emptiedCount = 120 :: Int
    partialCount = 40 :: Int
    overQuotaCount = 10 :: Int
    newQueue g = do
      (rId, qr) <- testNewQueueRec g QMMessaging
      runRight $ ExceptT $ addQueue ms rId qr
    write q s = writeMsg ms q True =<< mkMessage s
    fillPastQuota q = go 0
      where
        go n = write q "fill" >>= maybe (pure n) (const $ go (n + 1))
#endif
