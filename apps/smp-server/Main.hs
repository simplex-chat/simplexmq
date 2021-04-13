{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

module Main where

import Control.Monad (when)
import Crypto.Store.PKCS8
import Crypto.Store.X509
import qualified Data.ByteString.Char8 as B
import Data.Char (toLower)
import Data.X509
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

readCreateKeys :: IO C.FullKeyPair
readCreateKeys = do
  createDirectoryIfMissing True cfgDir
  let kPath = combine cfgDir "server_key.pub"
      pkPath = combine cfgDir "server_key"
  -- `||` is here to avoid creating keys and crash if one of two files exists
  hasKeys <- (||) <$> doesFileExist kPath <*> doesFileExist pkPath
  (if hasKeys then readKeys else createKeys) kPath pkPath
  where
    createKeys :: FilePath -> FilePath -> IO C.FullKeyPair
    createKeys kPath pkPath = do
      confirm
      (k, pk) <- C.generateKeyPair newKeySize
      writePubKeyFile kPath [PubKeyRSA $ C.rsaPublicKey k]
      writeKeyFile TraditionalFormat pkPath [PrivKeyRSA $ C.rsaPrivateKey pk]
      pure (k, pk)
    confirm :: IO ()
    confirm = do
      putStr "Generate new server key pair (y/N): "
      hFlush stdout
      ok <- getLine
      when (map toLower ok /= "y") exitFailure
    readKeys :: FilePath -> FilePath -> IO C.FullKeyPair
    readKeys kPath pkPath = do
      ks <- (,) <$> readPubKey kPath <*> readPrivKey pkPath
      if C.validKeyPair ks then pure ks else errorExit "private and public keys do not match"
    readPubKey :: FilePath -> IO C.PublicKey
    readPubKey path =
      readPubKeyFile path >>= \case
        [PubKeyRSA k] -> pure $ C.PublicKey k
        res -> readKeyError path res
    readPrivKey :: FilePath -> IO C.FullPrivateKey
    readPrivKey path =
      readKeyFile path >>= \case
        [Unprotected (PrivKeyRSA pk)] -> pure $ C.FullPrivateKey pk
        res -> readKeyError path res
    readKeyError :: String -> [a] -> IO b
    readKeyError path = \case
      [] -> errorExit $ "invalid key file format: " <> path
      [_] -> errorExit $ "not RSA key: " <> path
      _ -> errorExit $ "more than one key: " <> path
    errorExit :: String -> IO b
    errorExit e = putStrLn e >> exitFailure

publicKeyHash :: C.PublicKey -> B.ByteString
publicKeyHash = C.serializeKeyHash . C.getKeyHash . C.serializePubKey
