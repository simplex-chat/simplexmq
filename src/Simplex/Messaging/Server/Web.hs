{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}

module Simplex.Messaging.Server.Web
  ( EmbeddedWebParams (..),
    WebHttpsParams (..),
    serveStaticFiles,
    attachStaticFiles,
    generateSite,
    render,
    section_,
    item_,
    timedTTLText,
  ) where

import Control.Logger.Simple
import Control.Monad
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.IORef (readIORef)
import Network.Socket (getPeerName)
import Network.Wai (Application, Request (..))
import Network.Wai.Application.Static (StaticSettings (..))
import qualified Network.Wai.Application.Static as S
import qualified Network.Wai.Handler.Warp as W
import qualified Network.Wai.Handler.Warp.Internal as WI
import qualified Network.Wai.Handler.WarpTLS as WT
import Simplex.Messaging.Server (AttachHTTP)
import Simplex.Messaging.Server.Web.Embedded as E
import Simplex.Messaging.Util (tshow)
import System.Directory (createDirectoryIfMissing)
import System.FilePath
import UnliftIO.Concurrent (forkFinally)
import UnliftIO.Exception (bracket, finally)
import qualified WaiAppStatic.Types as WAT

data EmbeddedWebParams = EmbeddedWebParams
  { webStaticPath :: FilePath,
    webHttpPort :: Maybe Int,
    webHttpsParams :: Maybe WebHttpsParams
  }

data WebHttpsParams = WebHttpsParams
  { port :: Int,
    cert :: FilePath,
    key :: FilePath
  }

serveStaticFiles :: EmbeddedWebParams -> IO ()
serveStaticFiles EmbeddedWebParams {webStaticPath, webHttpPort, webHttpsParams} = do
  forM_ webHttpPort $ \port -> flip forkFinally (\e -> logError $ "HTTP server crashed: " <> tshow e) $ do
    logInfo $ "Serving static site on port " <> tshow port
    W.runSettings (mkSettings port) app
  forM_ webHttpsParams $ \WebHttpsParams {port, cert, key} -> flip forkFinally (\e -> logError $ "HTTPS server crashed: " <> tshow e) $ do
    logInfo $ "Serving static site on port " <> tshow port <> " (TLS)"
    WT.runTLS (WT.tlsSettings cert key) (mkSettings port) app
  where
    app = staticFiles webStaticPath
    mkSettings port = W.setPort port warpSettings

-- | Prepare context and prepare HTTP handler for TLS connections that already passed TLS.handshake and ALPN check.
attachStaticFiles :: FilePath -> (AttachHTTP -> IO ()) -> IO ()
attachStaticFiles path action =
  -- Initialize global internal state for http server.
  WI.withII warpSettings $ \ii -> do
    action $ \socket cxt -> do
      -- Initialize internal per-connection resources.
      addr <- getPeerName socket
      withConnection addr cxt $ \(conn, transport) ->
        withTimeout ii conn $ \th ->
          -- Run Warp connection handler to process HTTP requests for static files.
          WI.serveConnection conn ii th addr transport warpSettings app
  where
    app = staticFiles path
    -- from warp-tls
    withConnection socket cxt = bracket (WT.attachConn socket cxt) (terminate . fst)
    -- from warp
    withTimeout ii conn =
      bracket
        (WI.registerKillThread (WI.timeoutManager ii) (WI.connClose conn))
        WI.cancel
    -- shared clean up
    terminate conn = WI.connClose conn `finally` (readIORef (WI.connWriteBuffer conn) >>= WI.bufFree)

warpSettings :: W.Settings
warpSettings = W.setGracefulShutdownTimeout (Just 1) W.defaultSettings

staticFiles :: FilePath -> Application
staticFiles root = S.staticApp settings . changeWellKnownPath
  where
    settings = defSettings {ssListing = Nothing, ssGetMimeType = getMimeType}
    defSettings = S.defaultFileServerSettings root
    getMimeType f
      | WAT.fromPiece (WAT.fileName f) == "apple-app-site-association" = pure "application/json"
      | otherwise = (ssGetMimeType defSettings) f
    changeWellKnownPath req = case pathInfo req of
      ".well-known" : rest ->
        req
          { pathInfo = "well-known" : rest,
            rawPathInfo = "/well-known/" <> B.drop pfxLen (rawPathInfo req)
          }
      _ -> req
    pfxLen = B.length "/.well-known/"

generateSite :: ByteString -> [String] -> FilePath -> IO ()
generateSite indexContent linkPages sitePath = do
  createDirectoryIfMissing True sitePath
  B.writeFile (sitePath </> "index.html") indexContent
  copyDir "media" E.mediaContent
  -- `.well-known` path is re-written in changeWellKnownPath,
  -- staticApp does not allow hidden folders.
  copyDir "well-known" E.wellKnown
  forM_ linkPages createLinkPage
  logInfo $ "Generated static site contents at " <> tshow sitePath
  where
    copyDir dir content = do
      createDirectoryIfMissing True $ sitePath </> dir
      forM_ content $ \(path, s) -> B.writeFile (sitePath </> dir </> path) s
    createLinkPage path = do
      createDirectoryIfMissing True $ sitePath </> path
      B.writeFile (sitePath </> path </> "index.html") E.linkHtml

-- | Rewrite source with provided substitutions
render :: ByteString -> [(ByteString, Maybe ByteString)] -> ByteString
render src = \case
  [] -> src
  (label, content') : rest -> render (section_ label content' src) rest

-- | Rewrite section content inside @<x-label>...</x-label>@ markers.
-- Markers are always removed when found. Closing marker is mandatory.
-- If content is absent, whole section is removed.
-- Section content is delegated to `item_`. If no sections found, the whole source is delegated.
section_ :: ByteString -> Maybe ByteString -> ByteString -> ByteString
section_ label content' src =
  case B.breakSubstring startMarker src of
    (_, "") -> item_ label (fromMaybe "" content') src -- no section, just replace items
    (before, afterStart') ->
      -- found section start, search for end too
      case B.breakSubstring endMarker $ B.drop (B.length startMarker) afterStart' of
        (_, "") -> error $ "missing section end: " <> show endMarker
        (inside, next') ->
          let next = B.drop (B.length endMarker) next'
           in case content' of
                Just content | not (B.null content) -> before <> item_ label content inside <> section_ label content' next
                _ -> before <> next -- collapse section
  where
    startMarker = "<x-" <> label <> ">"
    endMarker = "</x-" <> label <> ">"
    fromMaybe d = \case
      Just x | not (B.null x) -> x
      _ -> d

-- | Replace all occurences of @${label}@ with provided content.
item_ :: ByteString -> ByteString -> ByteString -> ByteString
item_ label content' src =
  case B.breakSubstring marker src of
    (done, "") -> done
    (before, after') -> before <> content' <> item_ label content' (B.drop (B.length marker) after')
  where
    marker = "${" <> label <> "}"

-- Copy-pasted from simplex-chat Simplex.Chat.Types.Preferences
{-# INLINE timedTTLText #-}
timedTTLText :: (Integral i, Show i) => i -> String
timedTTLText 0 = "0 sec"
timedTTLText ttl = do
  let (m', s) = ttl `quotRem` 60
      (h', m) = m' `quotRem` 60
      (d', h) = h' `quotRem` 24
      (mm, d) = d' `quotRem` 30
  unwords $
    [mms mm | mm /= 0]
      <> [ds d | d /= 0]
      <> [hs h | h /= 0]
      <> [ms m | m /= 0]
      <> [ss s | s /= 0]
  where
    ss s = show s <> " sec"
    ms m = show m <> " min"
    hs 1 = "1 hour"
    hs h = show h <> " hours"
    ds 1 = "1 day"
    ds 7 = "1 week"
    ds 14 = "2 weeks"
    ds d = show d <> " days"
    mms 1 = "1 month"
    mms mm = show mm <> " months"
