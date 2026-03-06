{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module XFTPWeb
  ( xftpGenerateSite,
    xftpServerInformation,
  ) where

import Data.ByteString (ByteString)
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
xftpServerInformation XFTPServerConfig {fileExpiration, logStatsInterval, allowNewFiles, newFileBasicAuth} information onionHost = render E.indexHtml substs
  where
    substs = [("smpConfig", Nothing), ("xftpConfig", Just "y")] <> substConfig <> serverInfoSubsts simplexmqSource information <> [("onionHost", strEncode <$> onionHost), ("iniFileName", Just "file-server.ini")]
    substConfig =
      [ ("fileExpiration", Just $ maybe "Never" (fromString . timedTTLText . ttl) fileExpiration),
        ("statsEnabled", Just . yesNo $ isJust logStatsInterval),
        ("newUploadsAllowed", Just . yesNo $ allowNewFiles),
        ("basicAuthEnabled", Just . yesNo $ isJust newFileBasicAuth)
      ]
    yesNo True = "Yes"
    yesNo False = "No"
