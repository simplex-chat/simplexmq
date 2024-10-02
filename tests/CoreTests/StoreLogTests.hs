{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module CoreTests.StoreLogTests where

import Control.Monad
import qualified Data.ByteString.Char8 as B
import Data.Either (partitionEithers)
import qualified Data.Map.Strict as M
import SMPClient
import AgentTests.SQLiteTests
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Protocol
import Simplex.Messaging.Server.StoreLog
import Simplex.Messaging.Server.QueueStore
import Test.Hspec

testNewQueueRec :: Bool -> QueueRec
testNewQueueRec sndSecure = QueueRec
  { recipientId = EntityId "abcd",
    recipientKey = testPublicAuthKey,
    rcvDhSecret = testDhSecret,
    senderId = EntityId "efgh",
    senderKey = Just testPublicAuthKey,
    sndSecure,
    notifier = Nothing,
    status = QueueActive,
    updatedAt = Nothing
  }

testNtfCreds :: NtfCreds
testNtfCreds = NtfCreds
  { notifierId = EntityId "ijkl",
    notifierKey = testPublicAuthKey,
    rcvNtfDhSecret = testDhSecret
  }

data StoreLogTestCase r s = SLTC {name :: String, saved :: [r], state :: s, compacted :: [r]}

type SMPStoreLogTestCase = StoreLogTestCase StoreLogRecord (M.Map RecipientId QueueRec)

deriving instance Eq QueueRec

deriving instance Eq StoreLogRecord

deriving instance Eq NtfCreds

storeLogTests :: Spec
storeLogTests =
  forM_ [False, True] $ \sndSecure ->
    testSMPStoreLog ("SMP server store log, sndSecure = " <> show sndSecure)
      [ SLTC
          { name = "create new queue",
            saved = [CreateQueue $ testNewQueueRec sndSecure],
            compacted = [CreateQueue $ testNewQueueRec sndSecure],
            state = M.fromList [(EntityId "abcd", testNewQueueRec sndSecure)]
          },
        SLTC
          { name = "create and delete queue",
            saved = [CreateQueue $ testNewQueueRec sndSecure, DeleteQueue $ EntityId "abcd"],
            compacted = [],
            state = M.fromList []
          },
        SLTC
          { name = "create queue and add notifier",
            saved = [CreateQueue $ testNewQueueRec sndSecure, AddNotifier (EntityId "abcd") testNtfCreds],
            compacted = [CreateQueue $ (testNewQueueRec sndSecure) {notifier = Just testNtfCreds}],
            state = M.fromList [(EntityId "abcd", (testNewQueueRec sndSecure) {notifier = Just testNtfCreds})]
          }
      ]

testSMPStoreLog :: String -> [SMPStoreLogTestCase] -> Spec
testSMPStoreLog testSuite tests =
  fdescribe testSuite $ forM_ tests $ \t@SLTC {name, saved} -> it name $ do
    l <- openWriteStoreLog testStoreLogFile
    mapM_ (writeStoreLogRecord l) saved
    closeStoreLog l
    replicateM_ 3 $ testReadWrite t
  where
    testReadWrite SLTC {compacted, state} = do
      (state', l) <- readWriteStoreLog testStoreLogFile
      state' `shouldBe` state
      closeStoreLog l
      ([], compacted') <- partitionEithers . map strDecode . B.lines <$> B.readFile testStoreLogFile
      compacted' `shouldBe` compacted
