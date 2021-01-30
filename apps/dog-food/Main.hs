{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module Main where

import ChatOptions
import Control.Applicative ((<|>))
import Control.Logger.Simple
import Control.Monad.IO.Unlift
import Control.Monad.Reader
import Data.Attoparsec.ByteString.Char8 (Parser)
import qualified Data.Attoparsec.ByteString.Char8 as A
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Functor (($>))
import Numeric.Natural
import Simplex.Messaging.Agent (getSMPAgentClient, runSMPAgentClient)
import Simplex.Messaging.Agent.Client (AgentClient (..))
import Simplex.Messaging.Agent.Env.SQLite
import Simplex.Messaging.Agent.Transmission
import Simplex.Messaging.Client (smpDefaultConfig)
import Simplex.Messaging.Transport (getLn, putLn)
import Simplex.Messaging.Util (bshow, raceAny_)
import System.IO
import UnliftIO.STM

cfg :: AgentConfig
cfg =
  AgentConfig
    { tcpPort = undefined, -- TODO maybe take it out of config
      tbqSize = 16,
      connIdBytes = 12,
      dbFile = "smp-chat.db",
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
  = ChatHelp
  | InviteContact Contact
  | AcceptInvitation Contact SMPQueueInfo
  | ChatWith Contact
  | SendMessage Contact ByteString

chatCommandP :: Parser ChatCommand
chatCommandP =
  "/help" $> ChatHelp
    <|> "/invite " *> inviteContact
    <|> "/accept " *> acceptInvitation
    <|> "/chat " *> chatWith
    <|> "@" *> sendMessage
  where
    inviteContact = InviteContact . Contact <$> A.takeByteString
    acceptInvitation = AcceptInvitation <$> contact <* A.space <*> smpQueueInfoP
    chatWith = ChatWith . Contact <$> A.takeByteString
    sendMessage = SendMessage <$> contact <* A.space <*> A.takeByteString
    contact = Contact <$> A.takeTill (== ' ')

data ChatResponse
  = ChatHelpInfo
  | Invitation SMPQueueInfo
  | Connected Contact
  | ReceivedMessage Contact ByteString
  | Disconnected Contact
  | YesYes
  | ErrorInput ByteString
  | ChatError AgentErrorType
  | NoChatResponse

serializeChatResponse :: ChatResponse -> ByteString
serializeChatResponse = \case
  ChatHelpInfo -> chatHelpInfo
  Invitation qInfo -> "ask your contact to enter: /join <your name> " <> serializeSmpQueueInfo qInfo
  Connected (Contact c) -> "@" <> c <> " connected"
  ReceivedMessage (Contact c) t -> "@" <> c <> ": " <> t
  Disconnected (Contact c) -> "disconnected from @" <> c <> " - try \"/talk " <> c <> "\""
  YesYes -> "you got it!"
  ErrorInput t -> "invalid input: " <> t
  ChatError e -> "chat error: " <> bshow e
  NoChatResponse -> ""

chatHelpInfo :: ByteString
chatHelpInfo =
  "Commands:\n\
  \/invite <name> - create invitation to be sent to your contact <name> (any unique string without spaces)\n\
  \/accept <name> <invitation> - accept <invitation> from your contact <name> (a string that starts from smp::)\n\
  \/chat <name> - resume chat with <name>\n\
  \@<name> <message> - send <message> (any string) to contact <name>"

main :: IO ()
main = do
  ChatOpts {dbFileName, smpServer} <- getChatOpts
  putStrLn "simpleX chat prototype (no encryption), \"/help\" for usage information"
  -- setLogLevel LogInfo -- LogError
  -- withGlobalLogging logCfg $
  runReaderT (dogFoodChat smpServer) =<< newSMPAgentEnv cfg {dbFile = dbFileName}

dogFoodChat :: (MonadUnliftIO m, MonadReader Env m) => SMPServer -> m ()
dogFoodChat srv = do
  c <- getSMPAgentClient
  t <- getChatClient
  raceAny_
    [ runSMPAgentClient c,
      sendToAgent srv t c,
      sendToTTY stdout t,
      receiveFromAgent t c,
      receiveFromTTY stdin t
    ]

getChatClient :: (MonadUnliftIO m, MonadReader Env m) => m ChatClient
getChatClient = do
  q <- asks $ tbqSize . config
  atomically $ newChatClient q

newChatClient :: Natural -> STM ChatClient
newChatClient qSize = do
  inQ <- newTBQueue qSize
  outQ <- newTBQueue qSize
  return ChatClient {inQ, outQ}

receiveFromTTY :: MonadUnliftIO m => Handle -> ChatClient -> m ()
receiveFromTTY h ChatClient {inQ, outQ} =
  forever $ liftIO (getLn h) >>= processOrError . A.parseOnly chatCommandP
  where
    processOrError = \case
      Left err -> atomically . writeTBQueue outQ . ErrorInput $ B.pack err
      Right ChatHelp -> atomically . writeTBQueue outQ $ ChatHelpInfo
      Right cmd -> atomically $ writeTBQueue inQ cmd

sendToTTY :: MonadUnliftIO m => Handle -> ChatClient -> m ()
sendToTTY h ChatClient {outQ} = forever $ do
  atomically (readTBQueue outQ) >>= \case
    NoChatResponse -> return ()
    resp -> liftIO . putLn h $ serializeChatResponse resp

sendToAgent :: MonadUnliftIO m => SMPServer -> ChatClient -> AgentClient -> m ()
sendToAgent srv t c =
  forever . atomically $
    readTBQueue (inQ t) >>= mapM_ (writeTBQueue $ rcvQ c) . agentTransmission
  where
    agentTransmission :: ChatCommand -> Maybe (ATransmission 'Client)
    agentTransmission = \case
      ChatHelp -> Nothing
      InviteContact (Contact a) -> Just ("1", a, NEW srv)
      AcceptInvitation (Contact a) qInfo -> Just ("1", a, JOIN qInfo (ReplyVia srv))
      ChatWith (Contact a) -> Just ("1", a, SUB)
      SendMessage (Contact a) msg -> Just ("1", a, SEND msg)

receiveFromAgent :: MonadUnliftIO m => ChatClient -> AgentClient -> m ()
receiveFromAgent t c =
  forever . atomically $ readTBQueue (sndQ c) >>= writeTBQueue (outQ t) . chatResponse
  where
    chatResponse :: ATransmission 'Agent -> ChatResponse
    chatResponse (_, a, resp) = case resp of
      INV qInfo -> Invitation qInfo
      CON -> Connected $ Contact a
      END -> Disconnected $ Contact a
      MSG {m_body} -> ReceivedMessage (Contact a) m_body
      SENT _ -> NoChatResponse
      OK -> YesYes
      ERR e -> ChatError e
