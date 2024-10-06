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
import Crypto.Random (ChaChaDRG)
import qualified Data.ByteString.Char8 as B
import Data.Either (partitionEithers)
import qualified Data.Map.Strict as M
import SMPClient
import AgentTests.SQLiteTests
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Protocol
import Simplex.Messaging.Server.StoreLog
import Simplex.Messaging.Server.QueueStore
import Test.Hspec

testNewQueueRec :: TVar ChaChaDRG -> Bool -> IO QueueRec
testNewQueueRec g sndSecure = do
  recipientId <- atomically $ EntityId <$> C.randomBytes 24 g
  senderId <- atomically $ EntityId <$> C.randomBytes 24 g
  (recipientKey, _) <- atomically $ C.generateAuthKeyPair C.SX25519 g
  (k, pk) <- atomically $ C.generateKeyPair @'C.X25519 g
  pure QueueRec
    { recipientId,
      recipientKey,
      rcvDhSecret = C.dh' k pk,
      senderId,
      senderKey = Nothing,
      sndSecure,
      notifier = Nothing,
      status = QueueActive,
      updatedAt = Nothing
    }

testNtfCreds :: TVar ChaChaDRG -> IO NtfCreds
testNtfCreds g = do
  (notifierKey, _) <- atomically $ C.generateAuthKeyPair C.SX25519 g
  (k, pk) <- atomically $ C.generateKeyPair @'C.X25519 g
  pure
    NtfCreds
      { notifierId = EntityId "ijkl",
        notifierKey,
        rcvNtfDhSecret = C.dh' k pk
      }

data StoreLogTestCase r s = SLTC {name :: String, saved :: [r], state :: s, compacted :: [r]}

type SMPStoreLogTestCase = StoreLogTestCase StoreLogRecord (M.Map RecipientId QueueRec)

deriving instance Eq QueueRec

deriving instance Eq StoreLogRecord

deriving instance Eq NtfCreds

storeLogTests :: Spec
storeLogTests =
  forM_ [False, True] $ \sndSecure -> do
    (qr, ntfCreds, date) <- runIO $ do
      g <- C.newRandom
      (,,) <$> testNewQueueRec g sndSecure <*> testNtfCreds g <*> getSystemDate
    testSMPStoreLog ("SMP server store log, sndSecure = " <> show sndSecure)
      [ SLTC
          { name = "create new queue",
            saved = [CreateQueue qr],
            compacted = [CreateQueue qr],
            state = M.fromList [(recipientId qr, qr)]
          },
        SLTC
          { name = "secure queue",
            saved = [CreateQueue qr, SecureQueue (recipientId qr) testPublicAuthKey],
            compacted = [CreateQueue qr {senderKey = Just testPublicAuthKey}],
            state = M.fromList [(recipientId qr, qr {senderKey = Just testPublicAuthKey})]
          },          
        SLTC
          { name = "create and delete queue",
            saved = [CreateQueue qr, DeleteQueue $ recipientId qr],
            compacted = [],
            state = M.fromList []
          },
        SLTC
          { name = "create queue and add notifier",
            saved = [CreateQueue qr, AddNotifier (recipientId qr) ntfCreds],
            compacted = [CreateQueue $ qr {notifier = Just ntfCreds}],
            state = M.fromList [(recipientId qr, qr {notifier = Just ntfCreds})]
          },
        SLTC
          { name = "delete notifier",
            saved = [CreateQueue qr, AddNotifier (recipientId qr) ntfCreds, DeleteNotifier (recipientId qr)],
            compacted = [CreateQueue qr],
            state = M.fromList [(recipientId qr, qr)]
          },
        SLTC
          { name = "update time",
            saved = [CreateQueue qr, UpdateTime (recipientId qr) date],
            compacted = [CreateQueue qr {updatedAt = Just date}],
            state = M.fromList [(recipientId qr, qr {updatedAt = Just date})]
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
