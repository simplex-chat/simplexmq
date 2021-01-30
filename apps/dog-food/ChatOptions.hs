module ChatOptions (getChatOpts, ChatOpts (..)) where

import qualified Data.Attoparsec.ByteString.Char8 as A
import qualified Data.ByteString.Char8 as B
import Options.Applicative
import Simplex.Messaging.Agent.Transmission (SMPServer (..), smpServerP)

data ChatOpts = ChatOpts
  { dbFileName :: String,
    smpServer :: SMPServer
  }

chatOpts :: Parser ChatOpts
chatOpts =
  ChatOpts
    <$> strOption
      ( long "database"
          <> short 'd'
          <> metavar "DB_FILE"
          <> help "sqlite database filename (smp-chat.db)"
          <> value "smp-chat.db"
      )
    <*> option
      parseSMPServer
      ( long "server"
          <> short 's'
          <> metavar "SERVER"
          <> help "SMP server to use (localhost:5223)"
          <> value (SMPServer "localhost" (Just "5223") Nothing)
      )

parseSMPServer :: ReadM SMPServer
parseSMPServer = eitherReader $ A.parseOnly smpServerP . B.pack

getChatOpts :: IO ChatOpts
getChatOpts = execParser opts
  where
    opts =
      info
        (chatOpts <**> helper)
        ( fullDesc
            <> header "Chat prototype using Simplex Messaging Protocol (SMP)"
            <> progDesc "Start chat with DB_FILE file and use SERVER as SMP server"
        )
