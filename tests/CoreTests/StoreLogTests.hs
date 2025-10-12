{-# LANGUAGE CPP #-}
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
import qualified Data.X509 as X
import qualified Data.X509.Validation as XV
import SMPClient
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Protocol
import Simplex.Messaging.Server.Env.STM (readWriteQueueStore)
import Simplex.Messaging.Server.Main
import Simplex.Messaging.Server.MsgStore.Journal
import Simplex.Messaging.Server.MsgStore.Types
import Simplex.Messaging.Server.QueueStore
import Simplex.Messaging.Server.QueueStore.STM (STMQueueStore (..))
import Simplex.Messaging.Server.QueueStore.Types
import Simplex.Messaging.Server.StoreLog
import Simplex.Messaging.SystemTime
import Simplex.Messaging.Transport (SMPServiceRole (..))
import Simplex.Messaging.Transport.Credentials (genCredentials)
import Test.Hspec hiding (fit, it)
import Util

testPublicAuthKey :: C.APublicAuthKey
testPublicAuthKey = C.APublicAuthKey C.SEd25519 (C.publicKey "MC4CAQAwBQYDK2VwBCIEIDfEfevydXXfKajz3sRkcQ7RPvfWUPoq6pu1TYHV1DEe")

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

data StoreLogTestCase r s = SLTC {name :: String, saved :: [r], state :: s, compacted :: [r]}

type SMPStoreLogTestCase = StoreLogTestCase StoreLogRecord (M.Map RecipientId QueueRec)

deriving instance Eq QueueRec

deriving instance Eq ServiceRec

deriving instance Eq StoreLogRecord

deriving instance Eq NtfCreds

storeLogTests :: Spec
storeLogTests =
  forM_ [QMMessaging, QMContact] $ \qm -> do
    g <- runIO C.newRandom
    ((rId, qr), ntfCreds, date, sr@ServiceRec {serviceId}) <- runIO $
      (,,,) <$> testNewQueueRec g qm <*> testNtfCreds g <*> getSystemDate <*> newTestServiceRec g
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
          { name = "create queue, add notifier, register and associate notification service",
            saved = [CreateQueue rId qr, AddNotifier rId ntfCreds, NewService sr, QueueService rId (ASP SNotifierService) (Just serviceId)],
            compacted = [NewService sr, CreateQueue rId qr {notifier = Just ntfCreds {ntfServiceId = Just serviceId}}],
            state = M.fromList [(rId, qr {notifier = Just ntfCreds {ntfServiceId = Just serviceId}})]
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

newTestServiceRec :: TVar ChaChaDRG -> IO ServiceRec
newTestServiceRec g = do
  serviceId <- atomically $ EntityId <$> C.randomBytes 24 g
  (_, cert) <- genCredentials g Nothing (0, 2400) "ntf.example.com"
  serviceCreatedAt <- getSystemDate
  pure
    ServiceRec
      { serviceId,
        serviceRole = SRNotifier,
        serviceCert  = X.CertificateChain [cert],
        serviceCertHash = XV.getFingerprint cert X.HashSHA256,
        serviceCreatedAt
      }

testSMPStoreLog :: String -> [SMPStoreLogTestCase] -> Spec
testSMPStoreLog testSuite tests =
  describe testSuite $ forM_ tests $ \t@SLTC {name, saved} -> it name $ do
    l <- openWriteStoreLog False testStoreLogFile
    mapM_ (writeStoreLogRecord l) saved
    closeStoreLog l
    replicateM_ 3 $ testReadWrite t
#if defined(dbServerPostgres)
    (sCnt, qCnt) <- importStoreLogToDatabase "tests/tmp/" testStoreLogFile testStoreDBOpts
    fromIntegral (sCnt + qCnt) `shouldBe` length (compacted t)
    imported <- B.readFile $ testStoreLogFile <> ".bak"
    (sCnt', qCnt') <- exportDatabaseToStoreLog "tests/tmp/" testStoreDBOpts testStoreLogFile
    sCnt' `shouldBe` fromIntegral sCnt
    qCnt' `shouldBe` fromIntegral qCnt
    exported <- B.readFile testStoreLogFile
    imported `shouldBe` exported
#endif
  where
    testReadWrite SLTC {compacted, state} = do
      st <- newMsgStore $ testJournalStoreCfg MQStoreCfg
      l <- readWriteQueueStore True (mkQueue st True) testStoreLogFile $ stmQueueStore st
      storeState st `shouldReturn` state
      closeStoreLog l
      ([], compacted') <- partitionEithers . map strDecode . B.lines <$> B.readFile testStoreLogFile
      compacted' `shouldBe` compacted
    storeState :: JournalMsgStore 'QSMemory -> IO (M.Map RecipientId QueueRec)
    storeState st = M.mapMaybe id <$> (readTVarIO (queues $ stmQueueStore st) >>= mapM (readTVarIO . queueRec))
