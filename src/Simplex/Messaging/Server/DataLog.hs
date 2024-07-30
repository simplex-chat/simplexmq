{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

module Simplex.Messaging.Server.DataLog where

import Control.Applicative ((<|>))
import Control.Monad (foldM)
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy.Char8 as LB
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Simplex.Messaging.Protocol (BlobId)
import Simplex.Messaging.Server.DataStore
import Simplex.Messaging.Server.StoreLog
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Transport.Buffer (trimCR)
import Simplex.Messaging.Util (ifM)
import System.Directory (doesFileExist)
import System.IO

data DataLogRecord = CreateBlob DataRec | DeleteBlob BlobId

instance StrEncoding DataLogRecord where
  strEncode = \case
    CreateBlob d -> strEncode (Str "CREATE", d)
    DeleteBlob dId -> strEncode (Str "DELETE", dId)
  strP =
    "CREATE " *> (CreateBlob <$> strP)
      <|> "DELETE " *> (DeleteBlob <$> strP)

logCreateBlob :: StoreLog 'WriteMode -> DataRec -> IO ()
logCreateBlob s = writeStoreLogRecord s . CreateBlob

logDeleteBlob :: StoreLog 'WriteMode -> BlobId -> IO ()
logDeleteBlob s = writeStoreLogRecord s . DeleteBlob

readWriteDataLog :: FilePath -> IO (Map BlobId DataRec, StoreLog 'WriteMode)
readWriteDataLog f = do
  ds <- ifM (doesFileExist f) (readDataBlobs f) (pure M.empty)
  s <- openWriteStoreLog f
  writeDataBlobs s ds
  pure (ds, s)

writeDataBlobs :: StoreLog 'WriteMode -> Map BlobId DataRec -> IO ()
writeDataBlobs = mapM_ . logCreateBlob

readDataBlobs :: FilePath -> IO (Map BlobId DataRec)
readDataBlobs f = foldM processLine M.empty . LB.lines =<< LB.readFile f
  where
    processLine :: Map BlobId DataRec -> LB.ByteString -> IO (Map BlobId DataRec)
    processLine m s' = case strDecode $ trimCR s of
      Right r -> pure $ procLogRecord r
      Left e -> m <$ printError e
      where
        s = LB.toStrict s'
        procLogRecord :: DataLogRecord -> Map BlobId DataRec
        procLogRecord = \case
          CreateBlob d -> M.insert (dataId d) d m
          DeleteBlob dId -> M.delete dId m
        printError :: String -> IO ()
        printError e = B.putStrLn $ "Error parsing log: " <> B.pack e <> " - " <> s
