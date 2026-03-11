{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}

module XFTPWeb
  ( xftpGenerateSite,
    xftpServerInformation,
  ) where

import Control.Monad (forM_)
import qualified Data.ByteString.Char8 as B
import Data.ByteString (ByteString)
import Data.FileEmbed (embedDir)
import Data.Maybe (isJust)
import Data.String (fromString)
import Web.Embedded (embeddedContent)
import Simplex.FileTransfer.Server.Env (XFTPServerConfig (..))
import Simplex.Messaging.Encoding.String (strEncode)
import Simplex.Messaging.Server.Expiration (ExpirationConfig (..))
import Simplex.Messaging.Server.Information (ServerPublicInfo)
import Simplex.Messaging.Server.Main (simplexmqSource)
import qualified Simplex.Messaging.Server.Web as Web
import Simplex.Messaging.Server.Web (render, serverInfoSubsts, timedTTLText)
import Simplex.Messaging.Transport.Client (TransportHost (..))
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))

xftpWebContent :: [(FilePath, ByteString)]
xftpWebContent = $(embedDir "apps/xftp-server/static/xftp/")

xftpMediaContent :: [(FilePath, ByteString)]
xftpMediaContent = $(embedDir "apps/xftp-server/static/media/")

xftpGenerateSite :: XFTPServerConfig -> Maybe ServerPublicInfo -> Maybe TransportHost -> FilePath -> IO ()
xftpGenerateSite cfg info onionHost path = do
  Web.generateSite embeddedContent (xftpServerInformation cfg info onionHost) [] path
  let xftpDir = path </> "xftp"
      mediaDir = path </> "media"
  createDirectoryIfMissing True xftpDir
  forM_ xftpWebContent $ \(fp, content) -> B.writeFile (xftpDir </> fp) content
  forM_ xftpMediaContent $ \(fp, content) -> B.writeFile (mediaDir </> fp) content

xftpServerInformation :: XFTPServerConfig -> Maybe ServerPublicInfo -> Maybe TransportHost -> ByteString
xftpServerInformation XFTPServerConfig {fileExpiration, logStatsInterval, allowNewFiles, newFileBasicAuth} information onionHost = render (Web.indexHtml embeddedContent) substs
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
