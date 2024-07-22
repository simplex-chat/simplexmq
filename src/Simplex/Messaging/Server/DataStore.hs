{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module Simplex.Messaging.Server.DataStore where

import Data.ByteString.Char8
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Protocol

data DataRec = DataRec
  { blobId :: BlobId,
    blobKey :: DataPublicAuthKey,
    blobData :: ByteString
  }

instance StrEncoding DataRec where
  strEncode DataRec {blobId, blobKey, blobData} = strEncode (Str "v1", blobId, blobKey, blobData)
  strP = do
    (blobId, blobKey, blobData) <- "v1 " *> strP
    pure DataRec {blobId, blobKey, blobData}
