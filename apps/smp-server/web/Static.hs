module Static where

import Static.Embedded as E
import Network.Wai.Handler.Warp as W
import Network.Wai.Application.Static as S
import qualified Data.ByteString as B
import Control.Monad
import System.FilePath
import System.IO.Temp (withTempDirectory)
import System.Directory (createDirectoryIfMissing)

serveSite :: Port -> IO ()
serveSite port =
  withTempDirectory "/tmp" "smp-server-web" $ \sitePath -> do
    generateSite sitePath
    serveStaticFiles port sitePath

serveStaticFiles :: Port -> FilePath -> IO ()
serveStaticFiles port sitePath = W.run port (S.staticApp $ S.defaultFileServerSettings sitePath)

generateSite :: FilePath -> IO ()
generateSite sitePath = do
  createDirectoryIfMissing True $ sitePath
  B.writeFile (sitePath </> "index.html") E.indexHtml -- TODO: generate from server info

  createDirectoryIfMissing True $ sitePath </> "media"
  forM_ E.mediaContent $ \(path, bs) -> B.writeFile (sitePath </> "media" </> path) bs

  createDirectoryIfMissing True $ sitePath </> "contact"
  B.writeFile (sitePath </> "contact" </> "index.html") E.linkHtml

  createDirectoryIfMissing True $ sitePath </> "invitation"
  B.writeFile (sitePath </> "invitation" </> "index.html") E.linkHtml
