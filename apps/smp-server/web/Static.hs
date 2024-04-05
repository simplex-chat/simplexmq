{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module Static where

import Control.Monad
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy.Char8 as LB
import Network.Wai.Application.Static as S
import Network.Wai.Handler.Warp as W
import Simplex.Messaging.Server.Information (ServerInformation (..))
import Simplex.Messaging.Server.Main (EmbeddedWebParams (..))
import Simplex.Messaging.Util (bshow)
import Static.Embedded as E
import System.Directory (createDirectoryIfMissing)
import System.FilePath

serveStaticFiles :: EmbeddedWebParams -> IO ()
serveStaticFiles EmbeddedWebParams {staticPath, http, https} = do
  forM_ http $ \port -> W.run port (S.staticApp $ S.defaultFileServerSettings staticPath)
  forM_ https $ \(cert, key, port) -> W.run port (S.staticApp $ S.defaultFileServerSettings staticPath)

generateSite :: ServerInformation -> FilePath -> IO ()
generateSite si sitePath = do
  createDirectoryIfMissing True sitePath
  LB.writeFile (sitePath </> "index.html") $ serverInformation si

  createDirectoryIfMissing True $ sitePath </> "media"
  forM_ E.mediaContent $ \(path, bs) -> B.writeFile (sitePath </> "media" </> path) bs

  createDirectoryIfMissing True $ sitePath </> "contact"
  B.writeFile (sitePath </> "contact" </> "index.html") E.linkHtml

  createDirectoryIfMissing True $ sitePath </> "invitation"
  B.writeFile (sitePath </> "invitation" </> "index.html") E.linkHtml

serverInformation :: ServerInformation -> LB.ByteString
serverInformation si@ServerInformation {} =
  case B.breakSubstring marker template of
    (_, "") -> LB.fromStrict template
    (header, footer') -> LB.fromChunks [header, info, B.drop (B.length marker) footer']
  where
    template = E.indexHtml
    marker = "${serverInformation}"
    info = bshow si
