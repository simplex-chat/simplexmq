{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE ScopedTypeVariables #-}

module ServerTests where

import Control.Concurrent (ThreadId, killThread)
import Control.Concurrent.STM
import Control.Exception (SomeException, try)
import Control.Monad.Except (forM_, runExceptT)
import Data.ByteString.Base64
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import SMPClient
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Protocol
import Simplex.Messaging.Transport
import System.Directory (removeFile)
import System.TimeIt (timeItT)
import System.Timeout
import Test.HUnit
import Test.Hspec

rsaKeySize :: Int
rsaKeySize = 2048 `div` 8

serverTests :: ATransport -> Spec
serverTests t = do
  describe "SMP syntax" $ syntaxTests t
  describe "SMP queues" do
    describe "NEW and KEY commands, SEND messages" $ testCreateSecure t
    describe "NEW, OFF and DEL commands, SEND messages" $ testCreateDelete t
  describe "SMP messages" do
    describe "duplex communication over 2 SMP connections" $ testDuplex t
    describe "switch subscription to another SMP queue" $ testSwitchSub t
  describe "Store log" $ testWithStoreLog t
  describe "Timing of AUTH error" $ testTiming t
  describe "Message notifications" $ testMessageNotifications t

pattern Resp :: CorrId -> QueueId -> Command 'Broker -> SignedTransmissionOrError
pattern Resp corrId queueId command <- ("", (corrId, queueId, Right (Cmd SBroker command)))

sendRecv :: Transport c => THandle c -> (ByteString, ByteString, ByteString, ByteString) -> IO SignedTransmissionOrError
sendRecv h (sgn, corrId, qId, cmd) = tPutRaw h (sgn, corrId, encode qId, cmd) >> tGet fromServer h

signSendRecv :: Transport c => THandle c -> C.SafePrivateKey -> (ByteString, ByteString, ByteString) -> IO SignedTransmissionOrError
signSendRecv h pk (corrId, qId, cmd) = do
  let t = B.intercalate " " [corrId, encode qId, cmd]
  Right sig <- runExceptT $ C.sign pk t
  _ <- tPut h (sig, t)
  tGet fromServer h

cmdSEND :: ByteString -> ByteString
cmdSEND msg = serializeCommand (Cmd SSender . SEND $ msg)

(#==) :: (HasCallStack, Eq a, Show a) => (a, a) -> String -> Assertion
(actual, expected) #== message = assertEqual message expected actual

testCreateSecure :: ATransport -> Spec
testCreateSecure (ATransport t) =
  it "should create (NEW) and secure (KEY) queue" $
    smpTest t $ \h -> do
      (rPub, rKey) <- C.generateKeyPair rsaKeySize
      Resp "abcd" rId1 (IDS rId sId) <- signSendRecv h rKey ("abcd", "", "NEW " <> C.serializePubKey rPub)
      (rId1, "") #== "creates queue"

      Resp "bcda" sId1 ok1 <- sendRecv h ("", "bcda", sId, "SEND 5 hello ")
      (ok1, OK) #== "accepts unsigned SEND"
      (sId1, sId) #== "same queue ID in response 1"

      Resp "" _ (MSG _ _ msg1) <- tGet fromServer h
      (msg1, "hello") #== "delivers message"

      Resp "cdab" _ ok4 <- signSendRecv h rKey ("cdab", rId, "ACK")
      (ok4, OK) #== "replies OK when message acknowledged if no more messages"

      Resp "dabc" _ err6 <- signSendRecv h rKey ("dabc", rId, "ACK")
      (err6, ERR NO_MSG) #== "replies ERR when message acknowledged without messages"

      (sPub, sKey) <- C.generateKeyPair rsaKeySize
      Resp "abcd" sId2 err1 <- signSendRecv h sKey ("abcd", sId, "SEND 5 hello ")
      (err1, ERR AUTH) #== "rejects signed SEND"
      (sId2, sId) #== "same queue ID in response 2"

      let keyCmd = "KEY " <> C.serializePubKey sPub
      Resp "bcda" _ err2 <- sendRecv h (sampleSig, "bcda", rId, keyCmd)
      (err2, ERR AUTH) #== "rejects KEY with wrong signature"

      Resp "cdab" _ err3 <- signSendRecv h rKey ("cdab", sId, keyCmd)
      (err3, ERR AUTH) #== "rejects KEY with sender's ID"

      Resp "dabc" rId2 ok2 <- signSendRecv h rKey ("dabc", rId, keyCmd)
      (ok2, OK) #== "secures queue"
      (rId2, rId) #== "same queue ID in response 3"

      Resp "abcd" _ err4 <- signSendRecv h rKey ("abcd", rId, keyCmd)
      (err4, ERR AUTH) #== "rejects KEY if already secured"

      Resp "bcda" _ ok3 <- signSendRecv h sKey ("bcda", sId, "SEND 11 hello again ")
      (ok3, OK) #== "accepts signed SEND"

      Resp "" _ (MSG _ _ msg) <- tGet fromServer h
      (msg, "hello again") #== "delivers message 2"

      Resp "cdab" _ ok5 <- signSendRecv h rKey ("cdab", rId, "ACK")
      (ok5, OK) #== "replies OK when message acknowledged 2"

      Resp "dabc" _ err5 <- sendRecv h ("", "dabc", sId, "SEND 5 hello ")
      (err5, ERR AUTH) #== "rejects unsigned SEND"

testCreateDelete :: ATransport -> Spec
testCreateDelete (ATransport t) =
  it "should create (NEW), suspend (OFF) and delete (DEL) queue" $
    smpTest2 t $ \rh sh -> do
      (rPub, rKey) <- C.generateKeyPair rsaKeySize
      Resp "abcd" rId1 (IDS rId sId) <- signSendRecv rh rKey ("abcd", "", "NEW " <> C.serializePubKey rPub)
      (rId1, "") #== "creates queue"

      (sPub, sKey) <- C.generateKeyPair rsaKeySize
      Resp "bcda" _ ok1 <- signSendRecv rh rKey ("bcda", rId, "KEY " <> C.serializePubKey sPub)
      (ok1, OK) #== "secures queue"

      Resp "cdab" _ ok2 <- signSendRecv sh sKey ("cdab", sId, "SEND 5 hello ")
      (ok2, OK) #== "accepts signed SEND"

      Resp "dabc" _ ok7 <- signSendRecv sh sKey ("dabc", sId, "SEND 7 hello 2 ")
      (ok7, OK) #== "accepts signed SEND 2 - this message is not delivered because the first is not ACKed"

      Resp "" _ (MSG _ _ msg1) <- tGet fromServer rh
      (msg1, "hello") #== "delivers message"

      Resp "abcd" _ err1 <- sendRecv rh (sampleSig, "abcd", rId, "OFF")
      (err1, ERR AUTH) #== "rejects OFF with wrong signature"

      Resp "bcda" _ err2 <- signSendRecv rh rKey ("bcda", sId, "OFF")
      (err2, ERR AUTH) #== "rejects OFF with sender's ID"

      Resp "cdab" rId2 ok3 <- signSendRecv rh rKey ("cdab", rId, "OFF")
      (ok3, OK) #== "suspends queue"
      (rId2, rId) #== "same queue ID in response 2"

      Resp "dabc" _ err3 <- signSendRecv sh sKey ("dabc", sId, "SEND 5 hello ")
      (err3, ERR AUTH) #== "rejects signed SEND"

      Resp "abcd" _ err4 <- sendRecv sh ("", "abcd", sId, "SEND 5 hello ")
      (err4, ERR AUTH) #== "reject unsigned SEND too"

      Resp "bcda" _ ok4 <- signSendRecv rh rKey ("bcda", rId, "OFF")
      (ok4, OK) #== "accepts OFF when suspended"

      Resp "cdab" _ (MSG _ _ msg) <- signSendRecv rh rKey ("cdab", rId, "SUB")
      (msg, "hello") #== "accepts SUB when suspended and delivers the message again (because was not ACKed)"

      Resp "dabc" _ err5 <- sendRecv rh (sampleSig, "dabc", rId, "DEL")
      (err5, ERR AUTH) #== "rejects DEL with wrong signature"

      Resp "abcd" _ err6 <- signSendRecv rh rKey ("abcd", sId, "DEL")
      (err6, ERR AUTH) #== "rejects DEL with sender's ID"

      Resp "bcda" rId3 ok6 <- signSendRecv rh rKey ("bcda", rId, "DEL")
      (ok6, OK) #== "deletes queue"
      (rId3, rId) #== "same queue ID in response 3"

      Resp "cdab" _ err7 <- signSendRecv sh sKey ("cdab", sId, "SEND 5 hello ")
      (err7, ERR AUTH) #== "rejects signed SEND when deleted"

      Resp "dabc" _ err8 <- sendRecv sh ("", "dabc", sId, "SEND 5 hello ")
      (err8, ERR AUTH) #== "rejects unsigned SEND too when deleted"

      Resp "abcd" _ err11 <- signSendRecv rh rKey ("abcd", rId, "ACK")
      (err11, ERR AUTH) #== "rejects ACK when conn deleted - the second message is deleted"

      Resp "bcda" _ err9 <- signSendRecv rh rKey ("bcda", rId, "OFF")
      (err9, ERR AUTH) #== "rejects OFF when deleted"

      Resp "cdab" _ err10 <- signSendRecv rh rKey ("cdab", rId, "SUB")
      (err10, ERR AUTH) #== "rejects SUB when deleted"

testDuplex :: ATransport -> Spec
testDuplex (ATransport t) =
  it "should create 2 simplex connections and exchange messages" $
    smpTest2 t $ \alice bob -> do
      (arPub, arKey) <- C.generateKeyPair rsaKeySize
      Resp "abcd" _ (IDS aRcv aSnd) <- signSendRecv alice arKey ("abcd", "", "NEW " <> C.serializePubKey arPub)
      -- aSnd ID is passed to Bob out-of-band

      (bsPub, bsKey) <- C.generateKeyPair rsaKeySize
      Resp "bcda" _ OK <- sendRecv bob ("", "bcda", aSnd, cmdSEND $ "key " <> C.serializePubKey bsPub)
      -- "key ..." is ad-hoc, different from SMP protocol

      Resp "" _ (MSG _ _ msg1) <- tGet fromServer alice
      Resp "cdab" _ OK <- signSendRecv alice arKey ("cdab", aRcv, "ACK")
      ["key", bobKey] <- return $ B.words msg1
      (bobKey, C.serializePubKey bsPub) #== "key received from Bob"
      Resp "dabc" _ OK <- signSendRecv alice arKey ("dabc", aRcv, "KEY " <> bobKey)

      (brPub, brKey) <- C.generateKeyPair rsaKeySize
      Resp "abcd" _ (IDS bRcv bSnd) <- signSendRecv bob brKey ("abcd", "", "NEW " <> C.serializePubKey brPub)
      Resp "bcda" _ OK <- signSendRecv bob bsKey ("bcda", aSnd, cmdSEND $ "reply_id " <> encode bSnd)
      -- "reply_id ..." is ad-hoc, it is not a part of SMP protocol

      Resp "" _ (MSG _ _ msg2) <- tGet fromServer alice
      Resp "cdab" _ OK <- signSendRecv alice arKey ("cdab", aRcv, "ACK")
      ["reply_id", bId] <- return $ B.words msg2
      (bId, encode bSnd) #== "reply queue ID received from Bob"

      (asPub, asKey) <- C.generateKeyPair rsaKeySize
      Resp "dabc" _ OK <- sendRecv alice ("", "dabc", bSnd, cmdSEND $ "key " <> C.serializePubKey asPub)
      -- "key ..." is ad-hoc, different from SMP protocol

      Resp "" _ (MSG _ _ msg3) <- tGet fromServer bob
      Resp "abcd" _ OK <- signSendRecv bob brKey ("abcd", bRcv, "ACK")
      ["key", aliceKey] <- return $ B.words msg3
      (aliceKey, C.serializePubKey asPub) #== "key received from Alice"
      Resp "bcda" _ OK <- signSendRecv bob brKey ("bcda", bRcv, "KEY " <> aliceKey)

      Resp "cdab" _ OK <- signSendRecv bob bsKey ("cdab", aSnd, "SEND 8 hi alice ")

      Resp "" _ (MSG _ _ msg4) <- tGet fromServer alice
      Resp "dabc" _ OK <- signSendRecv alice arKey ("dabc", aRcv, "ACK")
      (msg4, "hi alice") #== "message received from Bob"

      Resp "abcd" _ OK <- signSendRecv alice asKey ("abcd", bSnd, cmdSEND "how are you bob")

      Resp "" _ (MSG _ _ msg5) <- tGet fromServer bob
      Resp "bcda" _ OK <- signSendRecv bob brKey ("bcda", bRcv, "ACK")
      (msg5, "how are you bob") #== "message received from alice"

testSwitchSub :: ATransport -> Spec
testSwitchSub (ATransport t) =
  it "should create simplex connections and switch subscription to another TCP connection" $
    smpTest3 t $ \rh1 rh2 sh -> do
      (rPub, rKey) <- C.generateKeyPair rsaKeySize
      Resp "abcd" _ (IDS rId sId) <- signSendRecv rh1 rKey ("abcd", "", "NEW " <> C.serializePubKey rPub)
      Resp "bcda" _ ok1 <- sendRecv sh ("", "bcda", sId, "SEND 5 test1 ")
      (ok1, OK) #== "sent test message 1"
      Resp "cdab" _ ok2 <- sendRecv sh ("", "cdab", sId, cmdSEND "test2, no ACK")
      (ok2, OK) #== "sent test message 2"

      Resp "" _ (MSG _ _ msg1) <- tGet fromServer rh1
      (msg1, "test1") #== "test message 1 delivered to the 1st TCP connection"
      Resp "abcd" _ (MSG _ _ msg2) <- signSendRecv rh1 rKey ("abcd", rId, "ACK")
      (msg2, "test2, no ACK") #== "test message 2 delivered, no ACK"

      Resp "bcda" _ (MSG _ _ msg2') <- signSendRecv rh2 rKey ("bcda", rId, "SUB")
      (msg2', "test2, no ACK") #== "same simplex queue via another TCP connection, tes2 delivered again (no ACK in 1st queue)"
      Resp "cdab" _ OK <- signSendRecv rh2 rKey ("cdab", rId, "ACK")

      Resp "" _ end <- tGet fromServer rh1
      (end, END) #== "unsubscribed the 1st TCP connection"

      Resp "dabc" _ OK <- sendRecv sh ("", "dabc", sId, "SEND 5 test3 ")

      Resp "" _ (MSG _ _ msg3) <- tGet fromServer rh2
      (msg3, "test3") #== "delivered to the 2nd TCP connection"

      Resp "abcd" _ err <- signSendRecv rh1 rKey ("abcd", rId, "ACK")
      (err, ERR NO_MSG) #== "rejects ACK from the 1st TCP connection"

      Resp "bcda" _ ok3 <- signSendRecv rh2 rKey ("bcda", rId, "ACK")
      (ok3, OK) #== "accepts ACK from the 2nd TCP connection"

      1000 `timeout` tGet fromServer rh1 >>= \case
        Nothing -> return ()
        Just _ -> error "nothing else is delivered to the 1st TCP connection"

testWithStoreLog :: ATransport -> Spec
testWithStoreLog at@(ATransport t) =
  it "should store simplex queues to log and restore them after server restart" $ do
    (sPub1, sKey1) <- C.generateKeyPair rsaKeySize
    (sPub2, sKey2) <- C.generateKeyPair rsaKeySize
    senderId1 <- newTVarIO ""
    senderId2 <- newTVarIO ""

    withSmpServerStoreLogOn at testPort . runTest t $ \h -> do
      (sId1, _, _) <- createAndSecureQueue h sPub1
      atomically $ writeTVar senderId1 sId1
      Resp "bcda" _ OK <- signSendRecv h sKey1 ("bcda", sId1, "SEND 5 hello ")
      Resp "" _ (MSG _ _ "hello") <- tGet fromServer h

      (sId2, rId2, rKey2) <- createAndSecureQueue h sPub2
      atomically $ writeTVar senderId2 sId2
      Resp "cdab" _ OK <- signSendRecv h sKey2 ("cdab", sId2, "SEND 9 hello too ")
      Resp "" _ (MSG _ _ "hello too") <- tGet fromServer h

      Resp "dabc" _ OK <- signSendRecv h rKey2 ("dabc", rId2, "DEL")
      pure ()

    logSize `shouldReturn` 5

    withSmpServerThreadOn at testPort . runTest t $ \h -> do
      sId1 <- readTVarIO senderId1
      -- fails if store log is disabled
      Resp "bcda" _ (ERR AUTH) <- signSendRecv h sKey1 ("bcda", sId1, "SEND 5 hello ")
      pure ()

    withSmpServerStoreLogOn at testPort . runTest t $ \h -> do
      -- this queue is restored
      sId1 <- readTVarIO senderId1
      Resp "bcda" _ OK <- signSendRecv h sKey1 ("bcda", sId1, "SEND 5 hello ")
      -- this queue is removed - not restored
      sId2 <- readTVarIO senderId2
      Resp "cdab" _ (ERR AUTH) <- signSendRecv h sKey2 ("cdab", sId2, "SEND 9 hello too ")
      pure ()

    logSize `shouldReturn` 1
    removeFile testStoreLogFile
  where
    runTest :: Transport c => TProxy c -> (THandle c -> IO ()) -> ThreadId -> Expectation
    runTest _ test' server = do
      testSMPClient test' `shouldReturn` ()
      killThread server

    logSize :: IO Int
    logSize =
      try (length . B.lines <$> B.readFile testStoreLogFile) >>= \case
        Right l -> pure l
        Left (_ :: SomeException) -> logSize

createAndSecureQueue :: Transport c => THandle c -> SenderPublicKey -> IO (SenderId, RecipientId, C.SafePrivateKey)
createAndSecureQueue h sPub = do
  (rPub, rKey) <- C.generateKeyPair rsaKeySize
  Resp "abcd" "" (IDS rId sId) <- signSendRecv h rKey ("abcd", "", "NEW " <> C.serializePubKey rPub)
  let keyCmd = "KEY " <> C.serializePubKey sPub
  Resp "dabc" rId' OK <- signSendRecv h rKey ("dabc", rId, keyCmd)
  (rId', rId) #== "same queue ID"
  pure (sId, rId, rKey)

testTiming :: ATransport -> Spec
testTiming (ATransport t) =
  it "should have similar time for auth error, whether queue exists or not, for all key sizes" $
    smpTest2 t $ \rh sh ->
      mapM_
        (testSameTiming rh sh)
        [ (128, 128, 100),
          (128, 256, 25),
          (128, 384, 15),
          -- (128, 512, 15),
          (256, 128, 100),
          (256, 256, 25),
          (256, 384, 15),
          -- (256, 512, 15),
          (384, 128, 100),
          (384, 256, 25),
          (384, 384, 15)
          -- (384, 512, 15),
          -- (512, 128, 100),
          -- (512, 256, 25),
          -- (512, 384, 15),
          -- (512, 512, 15)
        ]
  where
    timeRepeat n = fmap fst . timeItT . forM_ (replicate n ()) . const
    similarTime t1 t2 = abs (t1 - t2) / t1 < 0.2 `shouldBe` True
    testSameTiming :: Transport c => THandle c -> THandle c -> (Int, Int, Int) -> Expectation
    testSameTiming rh sh (senderKeySize, badKeySize, n) = do
      (rPub, rKey) <- C.generateKeyPair rsaKeySize
      Resp "abcd" "" (IDS rId sId) <- signSendRecv rh rKey ("abcd", "", "NEW " <> C.serializePubKey rPub)

      (sPub, sKey) <- C.generateKeyPair senderKeySize
      let keyCmd = "KEY " <> C.serializePubKey sPub
      Resp "dabc" _ OK <- signSendRecv rh rKey ("dabc", rId, keyCmd)

      (_, badKey) <- C.generateKeyPair badKeySize
      Resp "bcda" _ OK <- signSendRecv sh sKey ("bcda", sId, "SEND 5 hello ")
      timeWrongKey <- timeRepeat n $ do
        Resp "cdab" _ (ERR AUTH) <- signSendRecv sh badKey ("cdab", sId, "SEND 5 hello ")
        return ()
      timeNoQueue <- timeRepeat n $ do
        Resp "dabc" _ (ERR AUTH) <- signSendRecv sh badKey ("dabc", "1234", "SEND 5 hello ")
        return ()
      Resp "" _ (MSG _ _ "hello") <- tGet fromServer rh
      similarTime timeNoQueue timeWrongKey

testMessageNotifications :: ATransport -> Spec
testMessageNotifications (ATransport t) =
  it "should create simplex connection, subscribe notifier and deliver notifications" $ do
    (sPub, sKey) <- C.generateKeyPair rsaKeySize
    (nPub, nKey) <- C.generateKeyPair rsaKeySize
    smpTest4 t $ \rh sh nh1 nh2 -> do
      (sId, rId, rKey) <- createAndSecureQueue rh sPub
      Resp "1" _ (NID nId) <- signSendRecv rh rKey ("1", rId, "NKEY " <> C.serializePubKey nPub)
      Resp "2" _ OK <- signSendRecv nh1 nKey ("2", nId, "NSUB")
      Resp "3" _ OK <- signSendRecv sh sKey ("3", sId, "SEND 5 hello ")
      Resp "" _ (MSG _ _ "hello") <- tGet fromServer rh
      Resp "3a" _ OK <- signSendRecv rh rKey ("3a", rId, "ACK")
      Resp "" _ NMSG <- tGet fromServer nh1
      Resp "4" _ OK <- signSendRecv nh2 nKey ("4", nId, "NSUB")
      Resp "" _ END <- tGet fromServer nh1
      Resp "5" _ OK <- signSendRecv sh sKey ("5", sId, "SEND 11 hello again ")
      Resp "" _ (MSG _ _ "hello again") <- tGet fromServer rh
      Resp "" _ NMSG <- tGet fromServer nh2
      1000 `timeout` tGet fromServer nh1 >>= \case
        Nothing -> return ()
        Just _ -> error "nothing else should be delivered to the 1st notifier's TCP connection"

samplePubKey :: ByteString
samplePubKey = "rsa:MIIBoDANBgkqhkiG9w0BAQEFAAOCAY0AMIIBiAKCAQEAtn1NI2tPoOGSGfad0aUg0tJ0kG2nzrIPGLiz8wb3dQSJC9xkRHyzHhEE8Kmy2cM4q7rNZIlLcm4M7oXOTe7SC4x59bLQG9bteZPKqXu9wk41hNamV25PWQ4zIcIRmZKETVGbwN7jFMpH7wxLdI1zzMArAPKXCDCJ5ctWh4OWDI6OR6AcCtEj+toCI6N6pjxxn5VigJtwiKhxYpoUJSdNM60wVEDCSUrZYBAuDH8pOxPfP+Tm4sokaFDTIG3QJFzOjC+/9nW4MUjAOFll9PCp9kaEFHJ/YmOYKMWNOCCPvLS6lxA83i0UaardkNLNoFS5paWfTlroxRwOC2T6PwO2ywKBgDjtXcSED61zK1seocQMyGRINnlWdhceD669kIHju/f6kAayvYKW3/lbJNXCmyinAccBosO08/0sUxvtuniIo18kfYJE0UmP1ReCjhMP+O+yOmwZJini/QelJk/Pez8IIDDWnY1qYQsN/q7ocjakOYrpGG7mig6JMFpDJtD6istR"

sampleSig :: ByteString
sampleSig = "\128\207*\159eq\220i!\"\157\161\130\184\226\246\232_\\\170`\180\160\230sI\154\197\211\252\SUB\246\206ELL\t9K\ESC\196?\128\215%\222\148\NAK;9\155f\164\217e\242\156\CAN9\253\r\170\174'w\211\228?\205)\215\150\255\247z\DC115\DC1{\bn\145\rKD,K\230\202d8\233\167|7y\t_S\EM\248\EOT\216\172\167d\181\224)\137\ACKo\197j#c\217\243\228.\167\228\205\144\vr\134"

syntaxTests :: ATransport -> Spec
syntaxTests (ATransport t) = do
  it "unknown command" $ ("", "abcd", "1234", "HELLO") >#> ("", "abcd", "1234", "ERR CMD SYNTAX")
  describe "NEW" do
    it "no parameters" $ (sampleSig, "bcda", "", "NEW") >#> ("", "bcda", "", "ERR CMD SYNTAX")
    it "many parameters" $ (sampleSig, "cdab", "", "NEW 1 " <> samplePubKey) >#> ("", "cdab", "", "ERR CMD SYNTAX")
    it "no signature" $ ("", "dabc", "", "NEW " <> samplePubKey) >#> ("", "dabc", "", "ERR CMD NO_AUTH")
    it "queue ID" $ (sampleSig, "abcd", "12345678", "NEW " <> samplePubKey) >#> ("", "abcd", "12345678", "ERR CMD HAS_AUTH")
  describe "KEY" do
    it "valid syntax" $ (sampleSig, "bcda", "12345678", "KEY " <> samplePubKey) >#> ("", "bcda", "12345678", "ERR AUTH")
    it "no parameters" $ (sampleSig, "cdab", "12345678", "KEY") >#> ("", "cdab", "12345678", "ERR CMD SYNTAX")
    it "many parameters" $ (sampleSig, "dabc", "12345678", "KEY 1 " <> samplePubKey) >#> ("", "dabc", "12345678", "ERR CMD SYNTAX")
    it "no signature" $ ("", "abcd", "12345678", "KEY " <> samplePubKey) >#> ("", "abcd", "12345678", "ERR CMD NO_AUTH")
    it "no queue ID" $ (sampleSig, "bcda", "", "KEY " <> samplePubKey) >#> ("", "bcda", "", "ERR CMD NO_AUTH")
  noParamsSyntaxTest "SUB"
  noParamsSyntaxTest "ACK"
  noParamsSyntaxTest "OFF"
  noParamsSyntaxTest "DEL"
  describe "SEND" do
    it "valid syntax 1" $ (sampleSig, "cdab", "12345678", "SEND 5 hello ") >#> ("", "cdab", "12345678", "ERR AUTH")
    it "valid syntax 2" $ (sampleSig, "dabc", "12345678", "SEND 11 hello there ") >#> ("", "dabc", "12345678", "ERR AUTH")
    it "no parameters" $ (sampleSig, "abcd", "12345678", "SEND") >#> ("", "abcd", "12345678", "ERR CMD SYNTAX")
    it "no queue ID" $ (sampleSig, "bcda", "", "SEND 5 hello ") >#> ("", "bcda", "", "ERR CMD NO_QUEUE")
    it "bad message body 1" $ (sampleSig, "cdab", "12345678", "SEND 11 hello ") >#> ("", "cdab", "12345678", "ERR CMD SYNTAX")
    it "bad message body 2" $ (sampleSig, "dabc", "12345678", "SEND hello ") >#> ("", "dabc", "12345678", "ERR CMD SYNTAX")
    it "bigger body" $ (sampleSig, "abcd", "12345678", "SEND 4 hello ") >#> ("", "abcd", "12345678", "ERR CMD SYNTAX")
  describe "PING" do
    it "valid syntax" $ ("", "abcd", "", "PING") >#> ("", "abcd", "", "PONG")
  describe "broker response not allowed" do
    it "OK" $ (sampleSig, "bcda", "12345678", "OK") >#> ("", "bcda", "12345678", "ERR CMD PROHIBITED")
  where
    noParamsSyntaxTest :: ByteString -> Spec
    noParamsSyntaxTest cmd = describe (B.unpack cmd) do
      it "valid syntax" $ (sampleSig, "abcd", "12345678", cmd) >#> ("", "abcd", "12345678", "ERR AUTH")
      it "wrong terminator" $ (sampleSig, "bcda", "12345678", cmd <> "=") >#> ("", "bcda", "12345678", "ERR CMD SYNTAX")
      it "no signature" $ ("", "cdab", "12345678", cmd) >#> ("", "cdab", "12345678", "ERR CMD NO_AUTH")
      it "no queue ID" $ (sampleSig, "dabc", "", cmd) >#> ("", "dabc", "", "ERR CMD NO_AUTH")
    (>#>) :: RawTransmission -> RawTransmission -> Expectation
    command >#> response = smpServerTest t command `shouldReturn` response
