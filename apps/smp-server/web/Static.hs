{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module Static where

import Control.Logger.Simple
import Control.Monad
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Data.Maybe (fromMaybe)
import Network.Wai.Application.Static as S
import Network.Wai.Handler.Warp as W
import qualified Network.Wai.Handler.WarpTLS as W
import Simplex.Messaging.Server.Information
import Simplex.Messaging.Server.Main (EmbeddedWebParams (..))
import Simplex.Messaging.Util (bshow, tshow)
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
      [ ("persistence", Just . bshow $ persistence config),
        ("messageExpiration", Just . bshow $ messageExpiration config),
        ("statsEnabled", Just . bshow $ statsEnabled config),
        ("newQueuesAllowed", Just . bshow $ newQueuesAllowed config),
        ("basicAuthEnabled", Just . bshow $ basicAuthEnabled config)
      ]
    substInfo spi = basic <> maybe [] admin (adminContacts spi) <> maybe [] complaints (complaintsContacts spi) <> maybe [] entity (hosting spi) <> server
      where
        basic =
          [ ("sourceCode", Just . bshow $ sourceCode spi),
            ("usageConditions", Just . bshow $ usageConditions spi),
            ("operator", Just . bshow $ operator spi),
            ("website", Just . bshow $ website spi),
            ("sourceCode", Just . bshow $ sourceCode spi)
          ]
        admin ServerContactAddress {simplex, email, pgp} =
          [ ("adminSimplex", bshow <$> simplex),
            ("adminEmail", bshow <$> email),
            ("adminSimplex", bshow <$> pgp)
          ]
        complaints ServerContactAddress {simplex, email, pgp} =
          [ ("complaintsSimplex", bshow <$> simplex),
            ("complaintsEmail", bshow <$> email),
            ("complaintsSimplex", bshow <$> pgp)
          ]
        entity Entity {name, country} =
          [ ("hostingEntity", Just $ bshow name),
            ("hostingCountry", bshow <$> country)
          ]
        server =
          [ ("serverCountry", bshow . serverCountry <$> information)
          ]

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

-- si_ :: ServerInformation
-- si_ =
--   ServerInformation
--     { config =
--         ServerPublicConfig
--           { persistence = SPMMessages,
--             messageExpiration = Just 1814400,
--             statsEnabled = True,
--             newQueuesAllowed = True,
--             basicAuthEnabled = True
--           },
--       information =
--         Just
--           ( ServerPublicInfo
--               { sourceCode = "https://github.com/simplex-chat/simplexmq",
--                 usageConditions = Nothing,
--                 operator = Just (Entity {name = "We are", country = Just "WE"}),
--                 website = Just "https://im.the.opera.tor",
--                 adminContacts =
--                   Just
--                     ( ServerContactAddress
--                         { simplex = Just "contactUri",
--                           email = Just "donotreply@google.com",
--                           pgp = Just "43752980430"
--                         }
--                     ),
--                 complaintsContacts =
--                   Just
--                     ( ServerContactAddress
--                         { simplex =
--                             Just "contactUri",
--                           email = Just "nocomplaints@here.com",
--                           pgp = Just "45678392790"
--                         }
--                     ),
--                 hosting =
--                   Just
--                     (Entity {name = "NSACloud", country = Just "US"}),
--                 serverCountry = Just "US"
--               }
--           )
--     }
