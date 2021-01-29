{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module Main where

import Control.Applicative ((<|>))
import Control.Monad.IO.Unlift
import Control.Monad.Reader
import Data.Attoparsec.ByteString.Char8 (Parser)
import qualified Data.Attoparsec.ByteString.Char8 as A
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Functor
import Numeric.Natural
import Simplex.Messaging.Agent (getSMPAgentClient, runSMPAgentClient)
import Simplex.Messaging.Agent.Client (AgentClient)
import Simplex.Messaging.Agent.Env.SQLite
import Simplex.Messaging.Agent.Transmission (SMPQueueInfo, serializeSmpQueueInfo, smpQueueInfoP)
import Simplex.Messaging.Client (smpDefaultConfig)
import Simplex.Messaging.Transport (getLn, putLn)
import Simplex.Messaging.Util (raceAny_)
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

newtype Contact = Contact {toBs :: ByteString}

-- | GroupMessage ChatGroup ByteString
-- | AddToGroup Contact
data ChatCommand
  = InviteContact
  | JoinInvitation SMPQueueInfo
  | SendMessage Contact ByteString

chatCommandP :: Parser ChatCommand
chatCommandP =
  "/invite" $> InviteContact
    <|> "/join " *> joinInvitation
    <|> "@" *> sendMessage
  where
    joinInvitation :: Parser ChatCommand
    joinInvitation = JoinInvitation <$> smpQueueInfoP
    sendMessage = SendMessage <$> (Contact <$> A.takeTill (== ' ')) <* A.space <*> A.takeByteString

data ChatResponse
  = Invitation SMPQueueInfo
  | Joined Contact
  | ReceivedMessage Contact ByteString
  | ErrorInput ByteString

serializeChatResponse :: ChatResponse -> ByteString
serializeChatResponse = \case
  Invitation qInfo -> "ask your contact to enter: /join " <> serializeSmpQueueInfo qInfo
  Joined (Contact c) -> "@" <> c <> " connected"
  ReceivedMessage (Contact c) t -> "@" <> c <> ": " <> t
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

dfSend :: MonadUnliftIO m => Handle -> ChatClient -> m ()
dfSend h ChatClient {inQ, outQ} = liftIO (getLn h) >>= processOrError . A.parseOnly chatCommandP
  where
    processOrError = \case
      Right cmd -> atomically $ writeTBQueue inQ cmd
      Left err -> atomically . writeTBQueue outQ . ErrorInput $ B.pack err

dfReceive :: MonadUnliftIO m => Handle -> ChatClient -> m ()
dfReceive h ChatClient {outQ} = atomically (readTBQueue outQ) >>= liftIO . putLn h . serializeChatResponse

dfClient :: MonadUnliftIO m => ChatClient -> AgentClient -> m ()
dfClient _t _c = return ()

dfSubscriber :: MonadUnliftIO m => ChatClient -> AgentClient -> m ()
dfSubscriber _t _c = return ()
