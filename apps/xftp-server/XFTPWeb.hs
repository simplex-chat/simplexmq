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
import Data.FileEmbed (embedDir, embedFile)
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
xftpWebContent = $(embedDir "apps/xftp-server/static/xftp-web-bundle/")

xftpMediaContent :: [(FilePath, ByteString)]
xftpMediaContent = $(embedDir "apps/xftp-server/static/media/")

xftpFilePageHtml :: ByteString
xftpFilePageHtml = $(embedFile "apps/xftp-server/static/file.html")

xftpGenerateSite :: XFTPServerConfig -> Maybe ServerPublicInfo -> Maybe TransportHost -> FilePath -> IO ()
xftpGenerateSite cfg info onionHost path = do
  let substs = xftpSubsts cfg info onionHost
  Web.generateSite embeddedContent (render (Web.indexHtml embeddedContent) substs) [] path
  let xftpDir = path </> "xftp-web-bundle"
      mediaDir = path </> "media"
      fileDir = path </> "file"
  filePage xftpDir
  filePage mediaDir
  createDirectoryIfMissing True fileDir
  B.writeFile (fileDir </> "index.html") $ render xftpFilePageHtml substs
  where
    filePage dir = do
      createDirectoryIfMissing True dir
      forM_ xftpWebContent $ \(fp, content) -> B.writeFile (dir </> fp) content

xftpServerInformation :: XFTPServerConfig -> Maybe ServerPublicInfo -> Maybe TransportHost -> ByteString
xftpServerInformation cfg info onionHost = render (Web.indexHtml embeddedContent) (xftpSubsts cfg info onionHost)

xftpSubsts :: XFTPServerConfig -> Maybe ServerPublicInfo -> Maybe TransportHost -> [(ByteString, Maybe ByteString)]
xftpSubsts XFTPServerConfig {fileExpiration, logStatsInterval, allowNewFiles, newFileBasicAuth} information onionHost =
  [("smpConfig", Nothing), ("xftpConfig", Just "y")] <> substConfig <> serverInfoSubsts simplexmqSource information <> [("onionHost", strEncode <$> onionHost), ("iniFileName", Just "file-server.ini")]
  where
    substConfig =
      [ ("fileExpiration", Just $ maybe "Never" (fromString . timedTTLText . ttl) fileExpiration),
        ("statsEnabled", Just . yesNo $ isJust logStatsInterval),
        ("newUploadsAllowed", Just . yesNo $ allowNewFiles),
        ("basicAuthEnabled", Just . yesNo $ isJust newFileBasicAuth)
      ]
    yesNo True = "Yes"
    yesNo False = "No"
