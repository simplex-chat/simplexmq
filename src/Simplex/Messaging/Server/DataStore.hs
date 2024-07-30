{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module Simplex.Messaging.Server.DataStore where

import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Protocol

data DataRec = DataRec
  { dataId :: BlobId,
    dataKey :: DataPublicAuthKey,
    dataBlob :: DataBlob
  }

instance StrEncoding DataRec where
  strEncode DataRec {dataId, dataKey, dataBlob} = strEncode (Str "v1", dataId, dataKey, dataBlob)
  strP = do
    (dataId, dataKey, dataBlob) <- "v1 " *> strP
    pure DataRec {dataId, dataKey, dataBlob}
