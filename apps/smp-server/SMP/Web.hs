{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module SMP.Web
  ( smpGenerateSite,
    serverInformation,
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Char (toUpper)
import Data.Maybe (fromMaybe)
import Data.String (fromString)
import qualified Data.Text as T
import Data.Text.Encoding (encodeUtf8)
import Simplex.Messaging.Encoding.String (strEncode)
import Simplex.Messaging.Server.CLI (simplexmqCommit)
import Simplex.Messaging.Server.Information
import Simplex.Messaging.Server.Main (simplexmqSource)
import qualified Simplex.Messaging.Server.Web as Web
import Simplex.Messaging.Server.Web (render, timedTTLText)
import Simplex.Messaging.Server.Web.Embedded as E
import Simplex.Messaging.Transport (simplexMQVersion)
import Simplex.Messaging.Transport.Client (TransportHost (..))

smpGenerateSite :: ServerInformation -> Maybe TransportHost -> FilePath -> IO ()
smpGenerateSite si onionHost path =
  Web.generateSite (serverInformation si onionHost) smpLinkPages path

smpLinkPages :: [String]
smpLinkPages = ["contact", "invitation", "a", "c", "g", "r", "i"]

serverInformation :: ServerInformation -> Maybe TransportHost -> ByteString
serverInformation ServerInformation {config, information} onionHost = render E.indexHtml substs
  where
    substs = substConfig <> substInfo <> [("onionHost", strEncode <$> onionHost)]
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
    substInfo =
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
            ("hostingType",  (\s -> maybe s (\(c, rest) -> toUpper c `B.cons` rest) $ B.uncons s) . strEncode <$> hostingType spi)
          ]
