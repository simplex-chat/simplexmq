{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeApplications #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module CoreTests.StoreLogTests where

import Control.Concurrent.STM
import Control.Monad
import CoreTests.MsgStoreTests
import Crypto.Random (ChaChaDRG)
import qualified Data.ByteString.Char8 as B
import Data.Either (partitionEithers)
import qualified Data.List.NonEmpty as L
import qualified Data.Map.Strict as M
import SMPClient
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Protocol
import Simplex.Messaging.Server.Env.STM (readWriteQueueStore)
import Simplex.Messaging.Server.MsgStore.Journal
import Simplex.Messaging.Server.MsgStore.Types
import Simplex.Messaging.Server.QueueStore
import Simplex.Messaging.Server.QueueStore.STM (STMQueueStore (..))
import Simplex.Messaging.Server.QueueStore.Types
import Simplex.Messaging.Server.StoreLog
import Test.Hspec

testPublicAuthKey :: C.APublicAuthKey
testPublicAuthKey = C.APublicAuthKey C.SEd25519 (C.publicKey "MC4CAQAwBQYDK2VwBCIEIDfEfevydXXfKajz3sRkcQ7RPvfWUPoq6pu1TYHV1DEe")

testNtfCreds :: TVar ChaChaDRG -> IO NtfCreds
testNtfCreds g = do
  (nKey, _) <- atomically $ C.generateAuthKeyPair C.SX25519 g
  (k, pk) <- atomically $ C.generateKeyPair @'C.X25519 g
  pure
    NtfCreds
      { notifierId = EntityId "ijkl",
        notifierKey = Just nKey,
        ntfServerHost = Nothing,
        rcvNtfDhSecret = C.dh' k pk
      }

data StoreLogTestCase r s = SLTC {name :: String, saved :: [r], state :: s, compacted :: [r]}

type SMPStoreLogTestCase = StoreLogTestCase StoreLogRecord (M.Map RecipientId QueueRec)

deriving instance Eq QueueRec

deriving instance Eq StoreLogRecord

deriving instance Eq NtfCreds

-- TODO [short links] test store log with queue data
storeLogTests :: Spec
storeLogTests =
  forM_ [QMMessaging, QMContact] $ \qm -> do
    g <- runIO C.newRandom
    ((rId, qr), ntfCreds, date) <- runIO $
      (,,) <$> testNewQueueRec g qm <*> testNtfCreds g <*> getSystemDate
    ((rId', qr'), lnkId, qd) <- runIO $ do
      lnkId <- atomically $ EntityId <$> C.randomBytes 24 g
      let qd = (EncDataBytes "fixed data", EncDataBytes "user data")
      q <- testNewQueueRecData g qm (Just (lnkId, qd))
      pure (q, lnkId, qd)
    let pubKey = fst <$> atomically (C.generateAuthKeyPair C.SEd25519 g)
    newKeys <- runIO $ L.fromList <$> sequence [pubKey, pubKey]
    testSMPStoreLog
      ("SMP server store log, queueMode = " <> show qm)
      [ SLTC
          { name = "create new queue",
            saved = [CreateQueue rId qr],
            compacted = [CreateQueue rId qr],
            state = M.fromList [(rId, qr)]
          },
        SLTC
          { name = "create new queue with link data",
            saved = [CreateQueue rId' qr'],
            compacted = [CreateQueue rId' qr'],
            state = M.fromList [(rId', qr')]
          },          
        SLTC
          { name = "create new queue, add link data",
            saved = [CreateQueue rId' qr' {queueData = Nothing}, CreateLink rId' lnkId qd],
            compacted = [CreateQueue rId' qr'],
            state = M.fromList [(rId', qr')]
          },          
        SLTC
          { name = "create new queue with link data, delete data",
            saved = [CreateQueue rId' qr', DeleteLink rId'],
            compacted = [CreateQueue rId' qr' {queueData = Nothing}],
            state = M.fromList [(rId', qr' {queueData = Nothing})]
          },          
        SLTC
          { name = "secure queue",
            saved = [CreateQueue rId qr, SecureQueue rId testPublicAuthKey],
            compacted = [CreateQueue rId qr {senderKey = Just testPublicAuthKey}],
            state = M.fromList [(rId, qr {senderKey = Just testPublicAuthKey})]
          },
        SLTC
          { name = "create and delete queue",
            saved = [CreateQueue rId qr, DeleteQueue rId],
            compacted = [],
            state = M.fromList []
          },
        SLTC
          { name = "create queue and add notifier",
            saved = [CreateQueue rId qr, AddNotifier rId ntfCreds],
            compacted = [CreateQueue rId qr {notifier = Just ntfCreds}],
            state = M.fromList [(rId, qr {notifier = Just ntfCreds})]
          },
        SLTC
          { name = "delete notifier",
            saved = [CreateQueue rId qr, AddNotifier rId ntfCreds, DeleteNotifier rId],
            compacted = [CreateQueue rId qr],
            state = M.fromList [(rId, qr)]
          },
        SLTC
          { name = "update time",
            saved = [CreateQueue rId qr, UpdateTime rId date],
            compacted = [CreateQueue rId qr {updatedAt = Just date}],
            state = M.fromList [(rId, qr {updatedAt = Just date})]
          },
        SLTC
          { name = "update recipient keys",
            saved = [CreateQueue rId qr, UpdateKeys rId newKeys],
            compacted = [CreateQueue rId qr {recipientKeys = newKeys}],
            state = M.fromList [(rId, qr {recipientKeys = newKeys})]
          }
      ]

testSMPStoreLog :: String -> [SMPStoreLogTestCase] -> Spec
testSMPStoreLog testSuite tests =
  describe testSuite $ forM_ tests $ \t@SLTC {name, saved} -> it name $ do
    l <- openWriteStoreLog False testStoreLogFile
    mapM_ (writeStoreLogRecord l) saved
    closeStoreLog l
    replicateM_ 3 $ testReadWrite t
  where
    testReadWrite SLTC {compacted, state} = do
      st <- newMsgStore $ testJournalStoreCfg MQStoreCfg
      l <- readWriteQueueStore True (mkQueue st True) testStoreLogFile $ queueStore st
      storeState st `shouldReturn` state
      closeStoreLog l
      ([], compacted') <- partitionEithers . map strDecode . B.lines <$> B.readFile testStoreLogFile
      compacted' `shouldBe` compacted
    storeState :: JournalMsgStore 'QSMemory -> IO (M.Map RecipientId QueueRec)
    storeState st = M.mapMaybe id <$> (readTVarIO (queues $ stmQueueStore st) >>= mapM (readTVarIO . queueRec))
