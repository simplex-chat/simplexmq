{-# LANGUAGE OverloadedStrings #-}

module ServerOptions (getServerOpts, ServerOpts (..)) where

import Options.Applicative
import System.FilePath (combine)

data ServerOpts = ServerOpts
  { enableStoreLog :: Bool,
    storeLogFile :: FilePath
  }

serverOpts :: FilePath -> Parser ServerOpts
serverOpts appDir =
  ServerOpts
    <$> switch
      ( long "enable-log"
          <> short 'l'
          <> help "enable store log"
      )
    <*> strOption
      ( long "log-file"
          <> short 'f'
          <> metavar "LOG_FILE"
          <> help ("store log file path (" <> defaultStoreLogFilePath <> ")")
          <> value defaultStoreLogFilePath
      )
  where
    defaultStoreLogFilePath = combine appDir "smp-server-store.log"

getServerOpts :: FilePath -> IO ServerOpts
getServerOpts appDir = execParser opts
  where
    opts =
      info
        (serverOpts appDir <**> helper)
        ( fullDesc
            <> header "Simplex Messaging Protocol (SMP) Server with in-memory persistence"
            <> progDesc "Start server with -l option to log created queues and restore them on start-up"
        )
