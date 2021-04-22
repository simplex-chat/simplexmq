{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

module Main where

import Control.Monad (when)
import qualified Crypto.Store.PKCS8 as S
import qualified Data.ByteString.Char8 as B
import Data.Char (toLower)
import Data.X509 (PrivKey (PrivKeyRSA))
import qualified Simplex.Messaging.Crypto as C
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
      -- key is loaded from the file server_key in /etc/opt/simplex directory
      serverPrivateKey = undefined
    }

newKeySize :: Int
newKeySize = 2048 `div` 8

cfgDir :: FilePath
cfgDir = "/etc/opt/simplex"

main :: IO ()
main = do
  pk <- readCreateKey
  B.putStrLn $ "SMP transport key hash: " <> publicKeyHash (C.publicKey pk)
  putStrLn $ "Listening on port " <> tcpPort cfg
  runSMPServer cfg {serverPrivateKey = pk}

readCreateKey :: IO C.FullPrivateKey
readCreateKey = do
  createDirectoryIfMissing True cfgDir
  let path = combine cfgDir "server_key"
  hasKey <- doesFileExist path
  (if hasKey then readKey else createKey) path
  where
    createKey :: FilePath -> IO C.FullPrivateKey
    createKey path = do
      confirm
      (_, pk) <- C.generateKeyPair newKeySize
      S.writeKeyFile S.TraditionalFormat path [PrivKeyRSA $ C.rsaPrivateKey pk]
      pure pk
    confirm :: IO ()
    confirm = do
      putStr "Generate new server key pair (y/N): "
      hFlush stdout
      ok <- getLine
      when (map toLower ok /= "y") exitFailure
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

publicKeyHash :: C.PublicKey -> B.ByteString
publicKeyHash = C.serializeKeyHash . C.getKeyHash . C.binaryEncodePubKey
