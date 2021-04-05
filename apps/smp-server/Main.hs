{-# LANGUAGE OverloadedStrings #-}

module Main where

import Control.Monad (when)
import Data.Attoparsec.ByteString.Char8 (Parser)
import qualified Data.ByteString.Char8 as B
import Data.Char (toLower)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Parsers (parseAll)
import Simplex.Messaging.Server (runSMPServer)
import Simplex.Messaging.Server.Env.STM
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.Exit (exitFailure)
import System.FilePath (combine)
import System.IO (hFlush, stdout)

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

newKeySize :: Int
newKeySize = 2048 `div` 8

cfgDir :: FilePath
cfgDir = "/etc/opt/simplex"

main :: IO ()
main = do
  (k, pk) <- readCreateKeys
  B.putStrLn $ "SMP transport key hash: " <> publicKeyHash k
  putStrLn $ "Listening on port " <> tcpPort cfg
  runSMPServer cfg {serverKeyPair = (k, pk)}

readCreateKeys :: IO C.KeyPair
readCreateKeys = do
  createDirectoryIfMissing True cfgDir
  let kPath = combine cfgDir "server_key.pub"
      pkPath = combine cfgDir "server_key"
  -- `||` is here to avoid creating keys and crash if one of two files exists
  hasKeys <- (||) <$> doesFileExist kPath <*> doesFileExist pkPath
  (if hasKeys then readKeys else createKeys) kPath pkPath
  where
    createKeys :: FilePath -> FilePath -> IO C.KeyPair
    createKeys kPath pkPath = do
      confirm
      (k, pk) <- C.generateKeyPair newKeySize
      B.writeFile kPath $ C.serializePubKey k
      B.writeFile pkPath $ C.serializePrivKey pk
      pure (k, pk)
    confirm :: IO ()
    confirm = do
      putStr "Generate new server key pair (y/N): "
      hFlush stdout
      ok <- getLine
      when (map toLower ok /= "y") exitFailure
    readKeys :: FilePath -> FilePath -> IO C.KeyPair
    readKeys kPath pkPath = do
      ks <- (,) <$> readKey kPath C.pubKeyP <*> readKey pkPath C.privKeyP
      if C.validKeyPair ks then pure ks else putStrLn "invalid key pair" >> exitFailure
    readKey :: FilePath -> Parser a -> IO a
    readKey path parser =
      let parseError = fail . ((path <> ": ") <>)
       in B.readFile path >>= either parseError pure . parseAll parser . head . B.lines

publicKeyHash :: C.PublicKey -> B.ByteString
publicKeyHash = C.serializeKeyHash . C.getKeyHash . C.serializePubKey
