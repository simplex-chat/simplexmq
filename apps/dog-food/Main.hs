{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module Main where

import Control.Applicative ((<|>))
import Control.Logger.Simple
import Control.Monad.IO.Unlift
import Control.Monad.Reader
import Data.Attoparsec.ByteString.Char8 (Parser)
import qualified Data.Attoparsec.ByteString.Char8 as A
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Numeric.Natural
import Simplex.Messaging.Agent (getSMPAgentClient, runSMPAgentClient)
import Simplex.Messaging.Agent.Client (AgentClient (..))
import Simplex.Messaging.Agent.Env.SQLite
import Simplex.Messaging.Agent.Transmission
import Simplex.Messaging.Client (smpDefaultConfig)
import Simplex.Messaging.Transport (getLn, putLn)
import Simplex.Messaging.Util (bshow, raceAny_)
import System.IO
import UnliftIO.Async
import UnliftIO.STM

cfg :: AgentConfig
cfg =
  AgentConfig
    { tcpPort = undefined, -- TODO maybe take it out of config
      tbqSize = 16,
      connIdBytes = 12,
      dbFile = "dog-food.db",
      smpCfg = smpDefaultConfig
    }

logCfg :: LogConfig
logCfg = LogConfig {lc_file = Nothing, lc_stderr = True}

data ChatClient = ChatClient
  { inQ :: TBQueue ChatCommand,
    outQ :: TBQueue ChatResponse
  }

newtype Contact = Contact {toBs :: ByteString}

-- | GroupMessage ChatGroup ByteString
-- | AddToGroup Contact
data ChatCommand
  = InviteContact Contact
  | JoinInvitation Contact SMPQueueInfo
  | TalkTo Contact
  | SendMessage Contact ByteString

chatCommandP :: Parser ChatCommand
chatCommandP =
  "/invite " *> inviteContact
    <|> "/join " *> joinInvitation
    <|> "/talk " *> talkTo
    <|> "@" *> sendMessage
  where
    inviteContact = InviteContact . Contact <$> A.takeByteString
    joinInvitation = JoinInvitation <$> contact <* A.space <*> smpQueueInfoP
    talkTo = TalkTo . Contact <$> A.takeByteString
    sendMessage = SendMessage <$> contact <* A.space <*> A.takeByteString
    contact = Contact <$> A.takeTill (== ' ')

data ChatResponse
  = Invitation SMPQueueInfo
  | Joined Contact
  | ReceivedMessage Contact ByteString
  | Disconnected Contact
  | YesYes
  | ErrorInput ByteString
  | ChatError AgentErrorType

serializeChatResponse :: ChatResponse -> ByteString
serializeChatResponse = \case
  Invitation qInfo -> "ask your contact to enter: /join <name> " <> serializeSmpQueueInfo qInfo
  Joined (Contact c) -> "@" <> c <> " connected"
  ReceivedMessage (Contact c) t -> "@" <> c <> ": " <> t
  Disconnected (Contact c) -> "disconnected from @" <> c <> " - try sending \"/talk " <> c <> "\""
  YesYes -> "on it!"
  ErrorInput t -> "invalid input: " <> t
  ChatError e -> "chat error: " <> bshow e

main :: IO ()
main = do
  putStrLn "simplex chat"
  setLogLevel LogInfo -- LogError
  withGlobalLogging logCfg $ do
    env <- newSMPAgentEnv cfg
    runReaderT dogFoodChat env

dogFoodChat :: (MonadUnliftIO m, MonadReader Env m) => m ()
dogFoodChat = do
  c <- getSMPAgentClient
  t <- getChatClient
  raceAny_ [connectClient t, runDogFoodChat t c, runSMPAgentClient c]

connectClient :: MonadUnliftIO m => ChatClient -> m ()
connectClient t = race_ (dfSend stdout t) (dfReceive stdin t)

runDogFoodChat :: MonadUnliftIO m => ChatClient -> AgentClient -> m ()
runDogFoodChat t c = race_ (dfClient t c) (dfSubscriber t c)

getChatClient :: (MonadUnliftIO m, MonadReader Env m) => m ChatClient
getChatClient = do
  q <- asks $ tbqSize . config
  atomically $ newChatClient q

newChatClient :: Natural -> STM ChatClient
newChatClient qSize = do
  inQ <- newTBQueue qSize
  outQ <- newTBQueue qSize
  return ChatClient {inQ, outQ}

dfReceive :: MonadUnliftIO m => Handle -> ChatClient -> m ()
dfReceive h ChatClient {inQ, outQ} =
  forever $ liftIO (getLn h) >>= processOrError . A.parseOnly chatCommandP
  where
    processOrError = \case
      Right cmd -> atomically $ writeTBQueue inQ cmd
      Left err -> atomically . writeTBQueue outQ . ErrorInput $ B.pack err

dfSend :: MonadUnliftIO m => Handle -> ChatClient -> m ()
dfSend h ChatClient {outQ} =
  forever $ atomically (readTBQueue outQ) >>= liftIO . putLn h . serializeChatResponse

dfClient :: MonadUnliftIO m => ChatClient -> AgentClient -> m ()
dfClient t c =
  forever . atomically $ readTBQueue (inQ t) >>= writeTBQueue (rcvQ c) . agentTransmission
  where
    agentTransmission :: ChatCommand -> ATransmission 'Client
    agentTransmission = \case
      InviteContact (Contact a) -> ("1", a, NEW (SMPServer "localhost" (Just "5223") Nothing))
      JoinInvitation (Contact a) qInfo -> ("1", a, JOIN qInfo ReplyOn)
      TalkTo (Contact a) -> ("1", a, SUB)
      SendMessage (Contact a) msg -> ("1", a, SEND msg)

dfSubscriber :: MonadUnliftIO m => ChatClient -> AgentClient -> m ()
dfSubscriber t c =
  forever . atomically $ readTBQueue (sndQ c) >>= writeTBQueue (outQ t) . chatResponse
  where
    chatResponse :: ATransmission 'Agent -> ChatResponse
    chatResponse (_, a, resp) = case resp of
      INV qInfo -> Invitation qInfo
      CON -> Joined (Contact a)
      END -> Disconnected (Contact a)
      MSG {m_body} -> ReceivedMessage (Contact a) m_body
      OK -> YesYes
      ERR e -> ChatError e
