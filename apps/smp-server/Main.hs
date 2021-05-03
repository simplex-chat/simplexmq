{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module Main where

import Control.Monad (unless, when)
import qualified Crypto.Store.PKCS8 as S
import Data.ByteString.Base64 (encode)
import qualified Data.ByteString.Char8 as B
import Data.Char (toLower)
import Data.Functor (($>))
import Data.Ini (lookupValue, readIniFile)
import qualified Data.Text as T
import Data.X509 (PrivKey (PrivKeyRSA))
import Options.Applicative
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Server (runSMPServer)
import Simplex.Messaging.Server.Env.STM
import Simplex.Messaging.Server.StoreLog (StoreLog, openReadStoreLog)
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.Exit (exitFailure)
import System.FilePath (combine)
import System.IO (IOMode (..), hFlush, stdout)

cfg :: ServerConfig
cfg =
  ServerConfig
    { tcpPort = "5223",
      tbqSize = 16,
      queueIdBytes = 12,
      msgIdBytes = 6,
      storeLog = Nothing,
      -- key is loaded from the file server_key in /etc/opt/simplex directory
      serverPrivateKey = undefined
    }

newKeySize :: Int
newKeySize = 2048 `div` 8

cfgDir :: FilePath
cfgDir = "/etc/opt/simplex"

logDir :: FilePath
logDir = "/var/opt/simplex"

defaultStoreLogFile :: FilePath
defaultStoreLogFile = combine logDir "smp-server-store.log"

main :: IO ()
main = do
  opts <- getServerOpts
  putStrLn "SMP Server (-h for help)"
  ini <- readCreateIni opts
  storeLog <- openStoreLog ini
  pk <- readCreateKey
  B.putStrLn $ "transport key hash: " <> serverKeyHash pk
  putStrLn $ "listening on port " <> tcpPort cfg
  runSMPServer cfg {serverPrivateKey = pk, storeLog}

data IniOpts = IniOpts
  { enableStoreLog :: Bool,
    storeLogFile :: FilePath
  }

readCreateIni :: ServerOpts -> IO IniOpts
readCreateIni ServerOpts {configFile} = do
  createDirectoryIfMissing True cfgDir
  doesFileExist configFile >>= (`unless` createIni)
  readIni
  where
    readIni :: IO IniOpts
    readIni = do
      ini <- either exitError pure =<< readIniFile configFile
      let enableStoreLog = (== Right "on") $ lookupValue "STORE_LOG" "enable" ini
          storeLogFile = either (const defaultStoreLogFile) T.unpack $ lookupValue "STORE_LOG" "file" ini
      pure IniOpts {enableStoreLog, storeLogFile}
    exitError e = do
      putStrLn $ "error reading config file " <> configFile <> ": " <> e
      exitFailure
    createIni :: IO ()
    createIni = do
      confirm $ "Save default ini file to " <> configFile
      writeFile
        configFile
        "[STORE_LOG]\n\
        \# The server uses STM memory to store SMP queues and messages,\n\
        \# that will be lost on restart (e.g., as with redis).\n\
        \# This option enables saving SMP queues to append only log,\n\
        \# and restoring them when the server is started.\n\
        \# Log is compacted on start (deleted queues are removed).\n\
        \# The messages in the queues are not logged.\n\
        \\n\
        \# enable: on\n\
        \# file: /var/opt/simplex/smp-server-store.log\n"

readCreateKey :: IO C.FullPrivateKey
readCreateKey = do
  createDirectoryIfMissing True cfgDir
  let path = combine cfgDir "server_key"
  hasKey <- doesFileExist path
  (if hasKey then readKey else createKey) path
  where
    createKey :: FilePath -> IO C.FullPrivateKey
    createKey path = do
      confirm "Generate new server key pair"
      (_, pk) <- C.generateKeyPair newKeySize
      S.writeKeyFile S.TraditionalFormat path [PrivKeyRSA $ C.rsaPrivateKey pk]
      pure pk
    readKey :: FilePath -> IO C.FullPrivateKey
    readKey path = do
      S.readKeyFile path >>= \case
        [S.Unprotected (PrivKeyRSA pk)] -> pure $ C.FullPrivateKey pk
        [_] -> errorExit "not RSA key"
        [] -> errorExit "invalid key file format"
        _ -> errorExit "more than one key"
      where
        errorExit :: String -> IO b
        errorExit e = putStrLn (e <> ": " <> path) >> exitFailure

confirm :: String -> IO ()
confirm msg = do
  putStr $ msg <> " (y/N): "
  hFlush stdout
  ok <- getLine
  when (map toLower ok /= "y") exitFailure

serverKeyHash :: C.FullPrivateKey -> B.ByteString
serverKeyHash = encode . C.unKeyHash . C.publicKeyHash . C.publicKey

openStoreLog :: IniOpts -> IO (Maybe (StoreLog 'ReadMode))
openStoreLog IniOpts {enableStoreLog, storeLogFile = f}
  | enableStoreLog = do
    createDirectoryIfMissing True logDir
    putStrLn ("store log: " <> f)
    Just <$> openReadStoreLog f
  | otherwise = putStrLn "store log disabled" $> Nothing

newtype ServerOpts = ServerOpts
  { configFile :: FilePath
  }

serverOpts :: Parser ServerOpts
serverOpts =
  ServerOpts
    <$> strOption
      ( long "config"
          <> short 'c'
          <> metavar "INI_FILE"
          <> help ("config file (" <> defaultIniFile <> ")")
          <> value defaultIniFile
      )
  where
    defaultIniFile = combine cfgDir "smp-server.ini"

getServerOpts :: IO ServerOpts
getServerOpts = execParser opts
  where
    opts =
      info
        (serverOpts <**> helper)
        ( fullDesc
            <> header "Simplex Messaging Protocol (SMP) Server"
            <> progDesc "Start server with INI_FILE (created on first run)"
        )
