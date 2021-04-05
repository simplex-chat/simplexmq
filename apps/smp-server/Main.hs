{-# LANGUAGE OverloadedStrings #-}

module Main where

import Data.Attoparsec.ByteString.Char8 (Parser)
import qualified Data.ByteString.Char8 as B
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Parsers (parseAll)
import Simplex.Messaging.Server (runSMPServer)
import Simplex.Messaging.Server.Env.STM
import System.Directory (getAppUserDataDirectory)
import System.FilePath (combine)

cfg :: ServerConfig
cfg =
  ServerConfig
    { tcpPort = "5223",
      tbqSize = 16,
      queueIdBytes = 12,
      msgIdBytes = 6,
      -- keys are loaded from files server_key.pub and server_key in ~/.simplex directory
      serverKeyPair = undefined
    }

main :: IO ()
main = do
  (k, pk) <- loadCreateKeys
  B.putStrLn $ "SMP transport key hash: " <> publicKeyHash k
  putStrLn $ "Listening on port " <> tcpPort cfg
  runSMPServer cfg {serverKeyPair = (k, pk)}

loadCreateKeys :: IO C.KeyPair
loadCreateKeys = do
  dir <- getAppUserDataDirectory "simplex"
  k <- getKey dir "server_key.pub" C.pubKeyP
  pk <- getKey dir "server_key" C.privKeyP
  pure (k, pk)

getKey :: FilePath -> FilePath -> Parser a -> IO a
getKey dir path parser =
  B.readFile file >>= either parseError pure . parseAll parser . head . B.lines
  where
    file = combine dir path
    parseError = fail . ((file <> ": ") <>)

publicKeyHash :: C.PublicKey -> B.ByteString
publicKeyHash = C.serializeKeyHash . C.getKeyHash . C.serializePubKey
