{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}

module Simplex.Messaging.Server.Web
  ( EmbeddedWebParams (..),
    WebHttpsParams (..),
    EmbeddedContent (..),
    serveStaticFiles,
    attachStaticFiles,
    serveStaticPageH2,
    generateSite,
    serverInfoSubsts,
    render,
    section_,
    item_,
    timedTTLText,
  ) where

import qualified Codec.Compression.GZip as GZip
import Control.Logger.Simple
import Control.Monad
import Data.ByteString (ByteString)
import Data.ByteString.Builder (byteString)
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy as LB
import Data.Char (toUpper)
import Data.IORef (readIORef)
import Data.List (isPrefixOf, isSuffixOf)
import Data.Maybe (fromMaybe)
import qualified Data.Text as T
import Data.Text.Encoding (encodeUtf8)
import Network.HPACK.Token (tokenKey)
import qualified Network.HTTP.Types as N
import qualified Network.HTTP2.Server as H
import Network.Socket (getPeerName)
import Network.Wai (Application, Request (..), responseFile)
import Network.Wai.Application.Static (StaticSettings (..))
import qualified Network.Wai.Application.Static as S
import qualified Network.Wai.Handler.Warp as W
import qualified Network.Wai.Handler.Warp.Internal as WI
import qualified Network.Wai.Handler.WarpTLS as WT
import Simplex.Messaging.Encoding.String (strEncode)
import Simplex.Messaging.Server (AttachHTTP)
import Simplex.Messaging.Server.CLI (simplexmqCommit)
import Simplex.Messaging.Server.Information
import Simplex.Messaging.Transport (simplexMQVersion)
import Simplex.Messaging.Util (tshow)
import System.Directory (canonicalizePath, createDirectoryIfMissing, doesFileExist)
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

data EmbeddedContent = EmbeddedContent
  { indexHtml :: ByteString,
    linkHtml :: ByteString,
    mediaContent :: [(FilePath, ByteString)],
    wellKnown :: [(FilePath, ByteString)]
  }

serveStaticFiles :: EmbeddedWebParams -> IO ()
serveStaticFiles EmbeddedWebParams {webStaticPath, webHttpPort, webHttpsParams} = do
  app <- staticFiles webStaticPath
  forM_ webHttpPort $ \port -> flip forkFinally (\e -> logError $ "HTTP server crashed: " <> tshow e) $ do
    logInfo $ "Serving static site on port " <> tshow port
    W.runSettings (mkSettings port) app
  forM_ webHttpsParams $ \WebHttpsParams {port, cert, key} -> flip forkFinally (\e -> logError $ "HTTPS server crashed: " <> tshow e) $ do
    logInfo $ "Serving static site on port " <> tshow port <> " (TLS)"
    WT.runTLS (WT.tlsSettings cert key) (mkSettings port) app
  where
    mkSettings port = W.setPort port warpSettings

-- | Prepare context and prepare HTTP handler for TLS connections that already passed TLS.handshake and ALPN check.
attachStaticFiles :: FilePath -> (AttachHTTP -> IO ()) -> IO ()
attachStaticFiles path action = do
  app <- staticFiles path
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

staticFiles :: FilePath -> IO Application
staticFiles root = do
  canonRoot <- canonicalizePath root
  pure $ withGzipFiles canonRoot (S.staticApp settings) . changeWellKnownPath
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
            rawPathInfo = rewriteWellKnown (rawPathInfo req)
          }
      _ -> req

-- | WAI middleware that serves pre-compressed .gz files when client accepts gzip.
-- Falls through to the wrapped app for non-compressible files or when gzip is not accepted.
withGzipFiles :: FilePath -> Application -> Application
withGzipFiles canonRoot app req respond
  | acceptsGzipWAI req =
      resolveStaticFile canonRoot (rawPathInfo req) True >>= \case
        Just (file, mime, True) ->
          respond $
            responseFile
              N.ok200
              (staticResponseHeaders mime True)
              file
              Nothing
        _ -> app req respond
  | otherwise = app req respond

generateSite :: EmbeddedContent -> ByteString -> [String] -> FilePath -> IO ()
generateSite embedded indexContent linkPages sitePath = do
  createDirectoryIfMissing True sitePath
  writeWithGz (sitePath </> "index.html") indexContent
  copyDir "media" $ mediaContent embedded
  -- `.well-known` path is re-written in changeWellKnownPath,
  -- staticApp does not allow hidden folders.
  copyDir "well-known" $ wellKnown embedded
  forM_ linkPages createLinkPage
  logInfo $ "Generated static site contents at " <> tshow sitePath
  where
    copyDir dir content = do
      createDirectoryIfMissing True $ sitePath </> dir
      forM_ content $ \(path, s) -> writeWithGz (sitePath </> dir </> path) s
    createLinkPage path = do
      createDirectoryIfMissing True $ sitePath </> path
      writeWithGz (sitePath </> path </> "index.html") $ linkHtml embedded
    writeWithGz path content = do
      B.writeFile path content
      when (isCompressible path) $
        LB.writeFile (path <> ".gz") $ GZip.compress $ LB.fromStrict content

-- | Serve static files via HTTP/2 directly (without WAI).
-- Path traversal protection: resolved path must stay under canonicalRoot.
-- canonicalRoot must be pre-computed via 'canonicalizePath'.
serveStaticPageH2 :: FilePath -> H.Request -> (H.Response -> IO ()) -> IO Bool
serveStaticPageH2 canonRoot req sendResponse = do
  let rawPath = rewriteWellKnown $ fromMaybe "/" $ H.requestPath req
      gzip = acceptsGzipH2 req
  resolveStaticFile canonRoot rawPath gzip >>= \case
    Just (file, mime, gz) -> do
      content <- B.readFile file
      sendResponse $ H.responseBuilder N.ok200 (staticResponseHeaders mime gz) (byteString content)
      pure True
    Nothing -> pure False

-- | Resolve a static file request to a file path.
-- Handles index.html fallback, path traversal protection,
-- and gzip pre-compressed file selection.
-- canonRoot must be pre-computed via 'canonicalizePath'.
resolveStaticFile :: FilePath -> ByteString -> Bool -> IO (Maybe (FilePath, ByteString, Bool))
resolveStaticFile canonRoot path gzip = do
  let relPath = B.unpack $ B.dropWhile (== '/') path
      requestedPath
        | null relPath = canonRoot </> "index.html"
        | otherwise = canonRoot </> relPath
  tryResolve requestedPath
    >>= maybe (tryResolve (requestedPath </> "index.html")) (pure . Just)
  where
    tryResolve filePath = do
      exists <- doesFileExist filePath
      if exists
        then do
          canonFile <- canonicalizePath filePath
          if (canonRoot <> "/") `isPrefixOf` canonFile || canonRoot == canonFile
            then do
              let mime = staticMimeType canonFile
                  gzFile = canonFile <> ".gz"
              useGz <- if gzip && isCompressible canonFile then doesFileExist gzFile else pure False
              pure $ Just (if useGz then gzFile else canonFile, mime, useGz)
            else pure Nothing -- path traversal attempt
        else pure Nothing

rewriteWellKnown :: ByteString -> ByteString
rewriteWellKnown p
  | "/.well-known/" `B.isPrefixOf` p = "/well-known/" <> B.drop (B.length "/.well-known/") p
  | p == "/.well-known" = "/well-known"
  | otherwise = p

acceptsGzipH2 :: H.Request -> Bool
acceptsGzipH2 req = any (\(t, v) -> tokenKey t == "accept-encoding" && "gzip" `B.isInfixOf` v) (fst $ H.requestHeaders req)

acceptsGzipWAI :: Request -> Bool
acceptsGzipWAI req = maybe False ("gzip" `B.isInfixOf`) $ lookup "Accept-Encoding" (requestHeaders req)

isCompressible :: FilePath -> Bool
isCompressible fp =
  any (`isSuffixOf` fp) [".html", ".css", ".js", ".svg", ".json"]
    || "apple-app-site-association" `isSuffixOf` fp

staticResponseHeaders :: ByteString -> Bool -> [N.Header]
staticResponseHeaders mime gz
  | gz = [("Content-Type", mime), ("Content-Encoding", "gzip"), ("Vary", "Accept-Encoding")]
  | otherwise = [("Content-Type", mime)]

staticMimeType :: FilePath -> ByteString
staticMimeType fp
  | ".html" `isSuffixOf` fp = "text/html"
  | ".css" `isSuffixOf` fp = "text/css"
  | ".js" `isSuffixOf` fp = "application/javascript"
  | ".svg" `isSuffixOf` fp = "image/svg+xml"
  | ".png" `isSuffixOf` fp = "image/png"
  | ".ico" `isSuffixOf` fp = "image/x-icon"
  | ".json" `isSuffixOf` fp = "application/json"
  | "apple-app-site-association" `isSuffixOf` fp = "application/json"
  | ".woff" `isSuffixOf` fp = "font/woff"
  | ".woff2" `isSuffixOf` fp = "font/woff2"
  | ".ttf" `isSuffixOf` fp = "font/ttf"
  | otherwise = "application/octet-stream"

-- | Substitutions for server information fields shared between SMP and XFTP pages.
serverInfoSubsts :: String -> Maybe ServerPublicInfo -> [(ByteString, Maybe ByteString)]
serverInfoSubsts simplexmqSource information =
  concat
    [ basic,
      maybe [("usageConditions", Nothing), ("usageAmendments", Nothing)] conds (usageConditions spi),
      maybe [("operator", Nothing)] operatorE (operator spi),
      maybe [("admin", Nothing)] admin (adminContacts spi),
      maybe [("complaints", Nothing)] complaints (complaintsContacts spi),
      maybe [("hosting", Nothing)] hostingE (hosting spi),
      server
    ]
  where
    basic =
      [ ("sourceCode", if T.null sc then Nothing else Just (encodeUtf8 sc)),
        ("noSourceCode", if T.null sc then Just "none" else Nothing),
        ("version", Just $ B.pack simplexMQVersion),
        ("commitSourceCode", Just $ encodeUtf8 $ maybe (T.pack simplexmqSource) sourceCode information),
        ("shortCommit", Just $ B.pack $ take 7 simplexmqCommit),
        ("commit", Just $ B.pack simplexmqCommit),
        ("website", encodeUtf8 <$> website spi)
      ]
    spi = fromMaybe (emptyServerInfo "") information
    sc = sourceCode spi
    conds ServerConditions {conditions, amendments} =
      [ ("usageConditions", Just $ encodeUtf8 conditions),
        ("usageAmendments", encodeUtf8 <$> amendments)
      ]
    operatorE Entity {name, country} =
      [ ("operator", Just ""),
        ("operatorEntity", Just $ encodeUtf8 name),
        ("operatorCountry", encodeUtf8 <$> country)
      ]
    admin ServerContactAddress {simplex, email, pgp} =
      [ ("admin", Just ""),
        ("adminSimplex", strEncode <$> simplex),
        ("adminEmail", encodeUtf8 <$> email),
        ("adminPGP", encodeUtf8 . pkURI <$> pgp),
        ("adminPGPFingerprint", encodeUtf8 . pkFingerprint <$> pgp)
      ]
    complaints ServerContactAddress {simplex, email, pgp} =
      [ ("complaints", Just ""),
        ("complaintsSimplex", strEncode <$> simplex),
        ("complaintsEmail", encodeUtf8 <$> email),
        ("complaintsPGP", encodeUtf8 . pkURI <$> pgp),
        ("complaintsPGPFingerprint", encodeUtf8 . pkFingerprint <$> pgp)
      ]
    hostingE Entity {name, country} =
      [ ("hosting", Just ""),
        ("hostingEntity", Just $ encodeUtf8 name),
        ("hostingCountry", encodeUtf8 <$> country)
      ]
    server =
      [ ("serverCountry", encodeUtf8 <$> serverCountry spi),
        ("hostingType", (\s -> maybe s (\(c, rest) -> toUpper c `B.cons` rest) $ B.uncons s) . strEncode <$> hostingType spi)
      ]

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
                Just content -> before <> item_ label content inside <> section_ label content' next
                Nothing -> before <> section_ label Nothing next -- collapse section
  where
    startMarker = "<x-" <> label <> ">"
    endMarker = "</x-" <> label <> ">"

-- | Replace all occurrences of @${label}@ with provided content.
item_ :: ByteString -> ByteString -> ByteString -> ByteString
item_ label content' src =
  case B.breakSubstring marker src of
    (done, "") -> done
    (before, after') -> before <> content' <> item_ label content' (B.drop (B.length marker) after')
  where
    marker = "${" <> label <> "}"
