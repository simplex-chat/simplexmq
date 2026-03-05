{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module XFTP.Web
  ( xftpGenerateSite,
    xftpServerInformation,
  ) where

import Data.ByteString (ByteString)
import Data.Int (Int64)
import Data.Maybe (isJust)
import Data.String (fromString)
import Simplex.FileTransfer.Server.Env (XFTPServerConfig (..))
import Simplex.Messaging.Encoding.String (strEncode)
import Simplex.Messaging.Server.Expiration (ExpirationConfig (..))
import Simplex.Messaging.Server.Information (ServerPublicInfo)
import Simplex.Messaging.Server.Main (simplexmqSource)
import qualified Simplex.Messaging.Server.Web as Web
import Simplex.Messaging.Server.Web (render, serverInfoSubsts, timedTTLText)
import Simplex.Messaging.Server.Web.Embedded as E
import Simplex.Messaging.Transport.Client (TransportHost (..))

xftpGenerateSite :: XFTPServerConfig -> Maybe ServerPublicInfo -> Maybe TransportHost -> FilePath -> IO ()
xftpGenerateSite cfg info onionHost path =
  Web.generateSite (xftpServerInformation cfg info onionHost) [] path

xftpServerInformation :: XFTPServerConfig -> Maybe ServerPublicInfo -> Maybe TransportHost -> ByteString
xftpServerInformation XFTPServerConfig {fileExpiration, fileSizeQuota, logStatsInterval, allowNewFiles, newFileBasicAuth} information onionHost = render E.indexHtml substs
  where
    substs = [("smpConfig", Nothing), ("xftpConfig", Just "y")] <> substConfig <> serverInfoSubsts simplexmqSource information <> [("onionHost", strEncode <$> onionHost), ("iniFileName", Just "file-server.ini")]
    substConfig =
      [ ("fileExpiration", Just $ maybe "Never" (fromString . timedTTLText . ttl) fileExpiration),
        ("storageQuota", Just $ maybe "Unlimited" showQuota fileSizeQuota),
        ("statsEnabled", Just . yesNo $ isJust logStatsInterval),
        ("newUploadsAllowed", Just . yesNo $ allowNewFiles),
        ("basicAuthEnabled", Just . yesNo $ isJust newFileBasicAuth)
      ]
    showQuota :: Int64 -> ByteString
    showQuota q
      | q >= tb = showUnit tb "TB"
      | q >= gb = showUnit gb "GB"
      | q >= mb = showUnit mb "MB"
      | q >= kb = showUnit kb "KB"
      | otherwise = fromString (show q) <> " B"
      where
        kb = 1024
        mb = 1024 * kb
        gb = 1024 * mb
        tb = 1024 * gb
        showUnit unit suffix
          | rem_ == 0 = fromString (show whole) <> " " <> suffix
          | otherwise = fromString (show whole <> "." <> show tenths) <> " " <> suffix
          where
            (whole, rem_) = q `divMod` unit
            tenths = (rem_ * 10) `div` unit
    yesNo True = "Yes"
    yesNo False = "No"
