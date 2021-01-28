{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}

module Main where

import Control.Monad.IO.Unlift
import Control.Monad.Reader
import Data.Attoparsec.Text (Parser)
import qualified Data.Attoparsec.Text as A
import Data.Text
import Numeric.Natural
import Simplex.Messaging.Agent (getSMPAgentClient, runSMPAgentClient)
import Simplex.Messaging.Agent.Client (AgentClient)
import Simplex.Messaging.Agent.Env.SQLite
import Simplex.Messaging.Agent.Transmission (SMPQueueInfo)
import Simplex.Messaging.Client (smpDefaultConfig)
import System.IO
import UnliftIO.Async
import UnliftIO.STM

cfg :: AgentConfig
cfg =
  AgentConfig
    { tcpPort = undefined, -- TODO maybe take it out of config
      tbqSize = 16,
      connIdBytes = 12,
      dbFile = "smp-agent.db",
      smpCfg = smpDefaultConfig
    }

data ChatClient = ChatClient
  { inQ :: TBQueue ChatCommand,
    outQ :: TBQueue ChatResponse
  }

newtype Contact = Contact {contactToText :: Text}

-- | GroupMessage ChatGroup Text
-- | AddToGroup Contact
data ChatCommand
  = InviteContact
  | JoinInvitation SMPQueueInfo
  | SendMessage Contact Text

chatCommandP :: Parser ChatCommand
chatCommandP =
  "/invite" $> InviteContact
    <|> "/join " *> joinInvitation
    <|> "@" *> sendMessage
  where
    joinInvitation = JoinInvitation <$> smpQueueInfoP
    sendMessage = SendMessage <$> contact <* A.space <*> A.text <* A.endOfInput

data ChatResponse
  = Invitation SMPQueueInfo
  | Joined Contact
  | ReceivedMessage Contact Text
  | ErrorInput Text

serializeChatResponse :: ChatResponse -> Text
serializeChatResponse = \case
  Invitation qInfo -> "ask your contact to enter: /join " <> serializeQueueInfo qInfo
  Joined c -> "@" <> c <> " connected"
  ReceivedMessage c t -> "@" <> c <> ": " <> t
  ErrorInput t -> "invalid input: " <> t

main :: IO ()
main = do
  putStrLn "simplex chat"
  -- setLogLevel LogInfo -- LogError
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

dfSend :: Handle -> ChatClient -> m ()
dfSend h ChatClient {inQ} = getLn h >>= processOrError . A.parseOnly chatCommandP
  where
    processOrError = \case
      Right cmd -> atomically $ writeTBQueue inQ cmd
      Left err -> atomically $ writeTBQueue outQ $ ErrorInput err

dfReceive :: Handle -> ChatClient -> m ()
dfReceive h ChatClient {outQ} = atomically (readTBQueue outQ) >>= putLn h . serializeChatResponse

dfClient :: MonadUnliftIO m => ChatClient -> AgentClient -> m ()
dfClient _t _c = return ()

dfSubscriber :: MonadUnliftIO m => ChatClient -> AgentClient -> m ()
dfSubscriber _t _c = return ()
