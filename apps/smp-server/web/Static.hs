{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module Static where

import Control.Logger.Simple
import Control.Monad
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Data.Maybe (fromMaybe)
import Data.String (fromString)
import Data.Text.Encoding (encodeUtf8)
import Network.Wai.Application.Static as S
import Network.Wai.Handler.Warp as W
import qualified Network.Wai.Handler.WarpTLS as W
import Simplex.Messaging.Encoding.String (strEncode)
import Simplex.Messaging.Server.Information
import Simplex.Messaging.Server.Main (EmbeddedWebParams (..))
import Simplex.Messaging.Util (tshow)
import Static.Embedded as E
import System.Directory (createDirectoryIfMissing)
import System.FilePath
import UnliftIO.Concurrent (forkFinally)

serveStaticFiles :: EmbeddedWebParams -> IO ()
serveStaticFiles EmbeddedWebParams {staticPath, http, https} = do
  forM_ http $ \port -> flip forkFinally (\e -> logError $ "HTTP server crashed: " <> tshow e) $ do
    logInfo $ "Serving static site on port " <> tshow port
    W.runSettings (mkSettings port) (S.staticApp $ S.defaultFileServerSettings staticPath)
  forM_ https $ \(cert, key, port) -> flip forkFinally (\e -> logError $ "HTTPS server crashed: " <> tshow e) $ do
    logInfo $ "Serving static site on port " <> tshow port <> " (TLS)"
    W.runTLS (W.tlsSettings cert key) (mkSettings port) (S.staticApp $ S.defaultFileServerSettings staticPath)
  where
    mkSettings port = setPort port defaultSettings

generateSite :: ServerInformation -> FilePath -> IO ()
generateSite si sitePath = do
  createDirectoryIfMissing True sitePath
  B.writeFile (sitePath </> "index.html") $ serverInformation si
  createDirectoryIfMissing True $ sitePath </> "media"
  forM_ E.mediaContent $ \(path, bs) -> B.writeFile (sitePath </> "media" </> path) bs
  createDirectoryIfMissing True $ sitePath </> "contact"
  B.writeFile (sitePath </> "contact" </> "index.html") E.linkHtml
  createDirectoryIfMissing True $ sitePath </> "invitation"
  B.writeFile (sitePath </> "invitation" </> "index.html") E.linkHtml
  logInfo $ "Generated static site contents at " <> tshow sitePath

serverInformation :: ServerInformation -> ByteString
serverInformation ServerInformation {config, information} = render E.indexHtml substs
  where
    substs = substConfig <> maybe [] substInfo information
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
            ("adminPGP", encodeUtf8 <$> pgp)
          ]
        complaints ServerContactAddress {simplex, email, pgp} =
          [ ("complaints", Just ""),
            ("complaintsSimplex", strEncode <$> simplex),
            ("complaintsEmail", encodeUtf8 <$> email),
            ("complaintsPGP", encodeUtf8 <$> pgp)
          ]
        hostingE Entity {name, country} =
          [ ("hosting", Just ""),
            ("hostingEntity", Just $ encodeUtf8 name),
            ("hostingCountry", encodeUtf8 <$> country)
          ]
        server =
          [ ("serverCountry", fmap encodeUtf8 $ serverCountry =<< information)
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
