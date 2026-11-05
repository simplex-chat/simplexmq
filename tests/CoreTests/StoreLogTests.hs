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
import Simplex.FileTransfer.Protocol (FileInfo (..))
import Simplex.FileTransfer.Server.Store (FileRec (..), FileRecipient (..), FileStoreClass (..), RoundedFileTime, STMFileStore (..))
import Simplex.FileTransfer.Server.StoreLog (FileStoreLogRecord (..), readWriteFileStore, serverFileName)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Protocol
import Simplex.Messaging.Protocol.Types (ClientNotice (..))
import Simplex.Messaging.Server.Env.STM (readWriteQueueStore)
import Simplex.Messaging.Server.MsgStore.STM (STMMsgStore (..))
import Simplex.Messaging.Server.MsgStore.Types
import Simplex.Messaging.Server.QueueStore
import Simplex.Messaging.Server.QueueStore.STM (STMQueueStore (..), setStoreLog)
import Simplex.Messaging.Server.QueueStore.Types
import Simplex.Messaging.Server.StoreLog
import Simplex.Messaging.SystemTime
import Simplex.Messaging.Transport (SMPServiceRole (..))
import Simplex.Messaging.Transport.Credentials (genCredentials)
import System.FilePath ((</>))
import Test.Hspec hiding (fit, it)
import Util

#if defined(dbServerPostgres)
import Simplex.Messaging.Server.Main
#endif

testPublicAuthKey :: C.APublicAuthKey
testPublicAuthKey = C.APublicAuthKey C.SEd25519 (C.publicKey "MC4CAQAwBQYDK2VwBCIEIDfEfevydXXfKajz3sRkcQ7RPvfWUPoq6pu1TYHV1DEe")

data StoreLogTestCase r s = SLTC {name :: String, saved :: [r], state :: s, compacted :: [r]}

type SMPStoreLogTestCase = StoreLogTestCase StoreLogRecord (M.Map RecipientId QueueRec)

deriving instance Eq QueueRec

deriving instance Eq ServiceRec

deriving instance Eq StoreLogRecord

deriving instance Eq NtfCreds

storeLogTests :: Spec
storeLogTests = do
  it "should log link data swaps and restore them" testSwapLinkStoreLog
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
        rcvSr = sr {serviceRole = SRMessaging}
        blockedWithNotice = BlockingInfo {reason = BRContent, notice = Just ClientNotice {ttl = Just 86400}}
    newKeys <- runIO $ L.fromList <$> sequence [pubKey, pubKey]
    newKeys' <- runIO $ L.fromList <$> sequence [pubKey, pubKey, pubKey]
    let qd' = (fst qd, EncDataBytes "user data 1")
        qd'' = (fst qd, EncDataBytes "user data 2")
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
          { name = "create queue, register and associate messaging service, block queue with notice",
            saved = [CreateQueue rId qr, NewService rcvSr, QueueService rId (ASP SRecipientService) (Just serviceId), BlockQueue rId blockedWithNotice],
            compacted = [NewService rcvSr, CreateQueue rId qr {rcvServiceId = Just serviceId, status = EntityBlocked blockedWithNotice}],
            state = M.fromList [(rId, qr {rcvServiceId = Just serviceId, status = EntityBlocked blockedWithNotice})]
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
          },
        SLTC
          { name = "swap link data and recipient keys twice",
            saved = [CreateQueue rId' qr', CreateLinkKeys rId' lnkId qd' newKeys, UpdateKeys rId' newKeys, CreateLinkKeys rId' lnkId qd'' newKeys', UpdateKeys rId' newKeys'],
            compacted = [CreateQueue rId' qr' {recipientKeys = newKeys', queueData = Just (lnkId, qd'')}],
            state = M.fromList [(rId', qr' {recipientKeys = newKeys', queueData = Just (lnkId, qd'')})]
          },
        SLTC
          { name = "swap link data and recipient keys, then swap link data",
            saved = [CreateQueue rId' qr', CreateLinkKeys rId' lnkId qd' newKeys, UpdateKeys rId' newKeys, CreateLink rId' lnkId qd''],
            compacted = [CreateQueue rId' qr' {recipientKeys = newKeys, queueData = Just (lnkId, qd'')}],
            state = M.fromList [(rId', qr' {recipientKeys = newKeys, queueData = Just (lnkId, qd'')})]
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
    (sCnt, qCnt) <- importStoreLogToDatabase testStoreLogFile testStoreDBOpts
    fromIntegral (sCnt + qCnt) `shouldBe` length (compacted t)
    imported <- B.readFile $ testStoreLogFile <> ".bak"
    (sCnt', qCnt') <- exportDatabaseToStoreLog testStoreDBOpts testStoreLogFile
    sCnt' `shouldBe` fromIntegral sCnt
    qCnt' `shouldBe` fromIntegral qCnt
    exported <- B.readFile testStoreLogFile
    imported `shouldBe` exported
#endif
  where
    testReadWrite SLTC {compacted, state} = do
      st <- newMsgStore testSMTStoreConfig
      l <- readWriteQueueStore True (mkQueue st) testStoreLogFile $ queueStore st
      storeState st `shouldReturn` state
      closeStoreLog l
      ([], compacted') <- partitionEithers . map strDecode . B.lines <$> B.readFile testStoreLogFile
      compacted' `shouldBe` compacted
    storeState :: STMMsgStore -> IO (M.Map RecipientId QueueRec)
    storeState st = M.mapMaybe id <$> (readTVarIO (queues $ queueStore st) >>= mapM (readTVarIO . queueRec))

testSwapLinkStoreLog :: HasTestEnv => IO ()
testSwapLinkStoreLog = do
  g <- C.newRandom
  lnkId <- atomically $ EntityId <$> C.randomBytes 24 g
  (rId, qr) <- testNewQueueRecData g QMContact (Just (lnkId, testLinkData))
  (rKey2, _) <- atomically $ C.generateAuthKeyPair C.SEd25519 g
  let (fd, ud) = testLinkData
      d1 = (fd, EncDataBytes "user data 1")
      d2 = (fd, EncDataBytes "user data 2")
      rKeys = rKey2 L.<| recipientKeys qr
  ms <- newMsgStore testSMTStoreConfig
  setStoreLog (queueStore ms) =<< openWriteStoreLog False testStoreLogFile
  Right q <- addQueue ms rId qr
  swapQueueLinkData (queueStore ms) q lnkId (linkDataHash ud) (Just rKeys) d1 `shouldReturn` Right Nothing
  swapQueueLinkData (queueStore ms) q lnkId (linkDataHash $ snd d1) Nothing d2 `shouldReturn` Right Nothing
  closeMsgStore ms
  ([], logged) <- partitionEithers . map strDecode . B.lines <$> B.readFile testStoreLogFile
  logged `shouldBe` [CreateQueue rId qr, CreateLinkKeys rId lnkId d1 rKeys, UpdateKeys rId rKeys, CreateLink rId lnkId d2]
  ms' <- newMsgStore testSMTStoreConfig
  sl <- readWriteQueueStore True (mkQueue ms') testStoreLogFile $ queueStore ms'
  Right q' <- getQueue ms' SRecipient rId
  readTVarIO (queueRec q') `shouldReturn` Just qr {recipientKeys = rKeys, queueData = Just (lnkId, d2)}
  closeStoreLog sl

type FileRecState = (FileInfo, RoundedFileTime, Maybe RoundedFileTime, ServerEntityStatus)

type XFTPStoreLogTestCase = StoreLogTestCase FileStoreLogRecord (M.Map SenderId FileRecState)

deriving instance Eq FileInfo

deriving instance Eq FileRecipient

deriving instance Eq FileStoreLogRecord

testFileStoreLogFile :: HasTestEnv => FilePath
testFileStoreLogFile = testPath "xftp-server-store.log"

fileExpirationTests :: Spec
fileExpirationTests =
  describe "XFTP file expiration" $
    it "expires by stored expiration and by creation time" testExpiredFiles

testExpiredFiles :: Expectation
testExpiredFiles = do
  st <- newFileStore () :: IO STMFileStore
  g <- C.newRandom
  (sndKey, _) <- atomically $ C.generateAuthKeyPair C.SEd25519 g
  let file = FileInfo {sndKey, size = 16384, digest = "12345678"}
      created = RoundedSystemTime 100000
  addFile st (EntityId "expired_stored__") file created (Just (RoundedSystemTime 400000)) EntityActive `shouldReturn` Right ()
  addFile st (EntityId "stored_ahead____") file created (Just (RoundedSystemTime 900000)) EntityActive `shouldReturn` Right ()
  addFile st (EntityId "legacy_expired__") file created Nothing EntityActive `shouldReturn` Right ()
  addFile st (EntityId "legacy_in_grace_") file (RoundedSystemTime 297000) Nothing EntityActive `shouldReturn` Right ()
  expired <- expiredFiles st (RoundedSystemTime 500000) 300000 100
  map (\(sId, _, _) -> sId) expired `shouldMatchList` [EntityId "expired_stored__", EntityId "legacy_expired__"]

fileStoreLogTests :: Spec
fileStoreLogTests = do
  g <- runIO C.newRandom
  (sndKey, _) <- runIO $ atomically $ C.generateAuthKeyPair C.SEd25519 g
  sId <- runIO $ atomically $ EntityId <$> C.randomBytes 24 g
  let file = FileInfo {sndKey, size = 16384, digest = "12345678"}
      createdAt = RoundedSystemTime 1600000000
      expiresAt = RoundedSystemTime 1600172800
      blocked = BlockingInfo {reason = BRSpam, notice = Nothing}
      blockedWithNotice = BlockingInfo {reason = BRContent, notice = Just ClientNotice {ttl = Just 86400}}
  testXFTPStoreLog
    "XFTP server store log"
    [ SLTC
        { name = "create file",
          saved = [AddFile sId file createdAt (Just expiresAt) EntityActive],
          compacted = [AddFile sId file createdAt (Just expiresAt) EntityActive],
          state = M.fromList [(sId, (file, createdAt, Just expiresAt, EntityActive))]
        },
      SLTC
        { name = "create file without expiration",
          saved = [AddFile sId file createdAt Nothing EntityActive],
          compacted = [AddFile sId file createdAt Nothing EntityActive],
          state = M.fromList [(sId, (file, createdAt, Nothing, EntityActive))]
        },
      SLTC
        { name = "create and block file",
          saved = [AddFile sId file createdAt (Just expiresAt) EntityActive, BlockFile sId blocked],
          compacted = [AddFile sId file createdAt (Just expiresAt) (EntityBlocked blocked)],
          state = M.fromList [(sId, (file, createdAt, Just expiresAt, EntityBlocked blocked))]
        },
      SLTC
        { name = "create and block file with notice",
          saved = [AddFile sId file createdAt (Just expiresAt) EntityActive, BlockFile sId blockedWithNotice],
          compacted = [AddFile sId file createdAt (Just expiresAt) (EntityBlocked blockedWithNotice)],
          state = M.fromList [(sId, (file, createdAt, Just expiresAt, EntityBlocked blockedWithNotice))]
        },
      SLTC
        { name = "block file without expiration",
          saved = [AddFile sId file createdAt Nothing EntityActive, BlockFile sId blockedWithNotice],
          compacted = [AddFile sId file createdAt Nothing (EntityBlocked blockedWithNotice)],
          state = M.fromList [(sId, (file, createdAt, Nothing, EntityBlocked blockedWithNotice))]
        },
      SLTC
        { name = "put file with wrong file name",
          saved = [AddFile sId file createdAt (Just expiresAt) EntityActive, PutFile sId "/etc/passwd"],
          compacted = [AddFile sId file createdAt (Just expiresAt) EntityActive],
          state = M.fromList [(sId, (file, createdAt, Just expiresAt, EntityActive))]
        },
      SLTC
        { name = "put file in another directory",
          saved = [AddFile sId file createdAt (Just expiresAt) EntityActive, PutFile sId ("/srv/xftp" </> serverFileName sId)],
          compacted = [AddFile sId file createdAt (Just expiresAt) EntityActive, PutFile sId ("/srv/xftp" </> serverFileName sId)],
          state = M.fromList [(sId, (file, createdAt, Just expiresAt, EntityActive))]
        }
    ]

testXFTPStoreLog :: String -> [XFTPStoreLogTestCase] -> Spec
testXFTPStoreLog testSuite tests =
  describe testSuite $ forM_ tests $ \t@SLTC {name, saved} -> it name $ do
    l <- openWriteStoreLog False testFileStoreLogFile
    mapM_ (writeStoreLogRecord l) saved
    closeStoreLog l
    replicateM_ 3 $ testReadWrite t
  where
    testReadWrite SLTC {compacted, state} = do
      st <- newFileStore () :: IO STMFileStore
      l <- readWriteFileStore testFileStoreLogFile st
      storeState st `shouldReturn` state
      closeStoreLog l
      ([], compacted') <- partitionEithers . map strDecode . B.lines <$> B.readFile testFileStoreLogFile
      compacted' `shouldBe` compacted
    storeState :: STMFileStore -> IO (M.Map SenderId FileRecState)
    storeState st = readTVarIO (files st) >>= mapM fileState
    fileState FileRec {fileInfo, createdAt, expiresAt, fileStatus} = do
      status <- readTVarIO fileStatus
      pure (fileInfo, createdAt, expiresAt, status)
