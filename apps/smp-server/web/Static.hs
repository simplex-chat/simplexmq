{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module Static where

import Control.Logger.Simple
import Control.Monad
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Char (toUpper)
import Data.IORef (readIORef)
import Data.Maybe (fromMaybe)
import Data.String (fromString)
import Data.Text.Encoding (encodeUtf8)
import Network.Socket (getPeerName)
import Network.Wai (Application, Request (..))
import Network.Wai.Application.Static (StaticSettings (..))
import qualified Network.Wai.Application.Static as S
import qualified Network.Wai.Handler.Warp as W
import qualified Network.Wai.Handler.Warp.Internal as WI
import qualified Network.Wai.Handler.WarpTLS as WT
import Simplex.Messaging.Encoding.String (strEncode)
import Simplex.Messaging.Server (AttachHTTP)
import Simplex.Messaging.Server.Information
import Simplex.Messaging.Server.Main (EmbeddedWebParams (..), WebHttpsParams (..))
import Simplex.Messaging.Transport (simplexMQVersion)
import Simplex.Messaging.Transport.Client (TransportHost (..))
import Simplex.Messaging.Util (tshow)
import Static.Embedded as E
import System.Directory (createDirectoryIfMissing)
import System.FilePath
import UnliftIO.Concurrent (forkFinally)
import UnliftIO.Exception (bracket, finally)
import qualified WaiAppStatic.Types as WAT

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

generateSite :: ServerInformation -> Maybe TransportHost -> FilePath -> IO ()
generateSite si onionHost sitePath = do
  createDirectoryIfMissing True sitePath
  B.writeFile (sitePath </> "index.html") $ serverInformation si onionHost
  copyDir "media" E.mediaContent
  -- `.well-known` path is re-written in changeWellKnownPath,
  -- staticApp does not allow hidden folders.
  copyDir "well-known" E.wellKnown
  createLinkPage "contact"
  createLinkPage "invitation"
  createLinkPage "a"
  createLinkPage "c"
  createLinkPage "g"
  createLinkPage "r"
  createLinkPage "i"
  logInfo $ "Generated static site contents at " <> tshow sitePath
  where
    copyDir dir content = do
      createDirectoryIfMissing True $ sitePath </> dir
      forM_ content $ \(path, s) -> B.writeFile (sitePath </> dir </> path) s
    createLinkPage path = do
      createDirectoryIfMissing True $ sitePath </> path
      B.writeFile (sitePath </> path </> "index.html") E.linkHtml

serverInformation :: ServerInformation -> Maybe TransportHost -> ByteString
serverInformation ServerInformation {config, information} onionHost = render E.indexHtml substs
  where
    substs = substConfig <> maybe [] substInfo information <> [("onionHost", strEncode <$> onionHost)]
    substConfig =
      [ ( "persistence",
          Just $ case persistence config of
            SPMMemoryOnly -> "In-memory only"
            SPMQueues -> "Queues"
            SPMMessages -> "Queues and messages"
        ),
        ("messageExpiration", Just $ maybe "Never" (fromString . timedTTLText) $ messageExpiration config),
        ("statsEnabled", Just . yesNo $ statsEnabled config),
        ("newQueuesAllowed", Just . yesNo $ newQueuesAllowed config),
        ("basicAuthEnabled", Just . yesNo $ basicAuthEnabled config)
      ]
    yesNo True = "Yes"
    yesNo False = "No"
    substInfo spi =
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
          [ ("sourceCode", Just . encodeUtf8 $ sourceCode spi),
            ("version", Just $ B.pack simplexMQVersion),
            ("website", encodeUtf8 <$> website spi)
          ]
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
            ("hostingType",  (\s -> maybe s (\(c, rest) -> toUpper c `B.cons` rest) $ B.uncons s) . strEncode <$> hostingType spi)
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
                Nothing -> before <> next -- collapse section
                Just content -> before <> item_ label content inside <> section_ label content' next
  where
    startMarker = "<x-" <> label <> ">"
    endMarker = "</x-" <> label <> ">"

-- | Replace all occurences of @${label}@ with provided content.
item_ :: ByteString -> ByteString -> ByteString -> ByteString
item_ label content' src =
  case B.breakSubstring marker src of
    (done, "") -> done
    (before, after') -> before <> content' <> item_ label content' (B.drop (B.length marker) after')
  where
    marker = "${" <> label <> "}"
