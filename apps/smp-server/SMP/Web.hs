{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module SMP.Web
  ( smpGenerateSite,
    serverInformation,
  ) where

import Data.ByteString (ByteString)
import Data.String (fromString)
import Simplex.Messaging.Encoding.String (strEncode)
import Simplex.Messaging.Server.Information
import Simplex.Messaging.Server.Main (simplexmqSource)
import qualified Simplex.Messaging.Server.Web as Web
import Simplex.Messaging.Server.Web (render, serverInfoSubsts, timedTTLText)
import Simplex.Messaging.Server.Web.Embedded as E
import Simplex.Messaging.Transport.Client (TransportHost (..))

smpGenerateSite :: ServerInformation -> Maybe TransportHost -> FilePath -> IO ()
smpGenerateSite si onionHost path =
  Web.generateSite (serverInformation si onionHost) smpLinkPages path

smpLinkPages :: [String]
smpLinkPages = ["contact", "invitation", "a", "c", "g", "r", "i"]

serverInformation :: ServerInformation -> Maybe TransportHost -> ByteString
serverInformation ServerInformation {config, information} onionHost = render E.indexHtml substs
  where
    substs = [("smpConfig", Just "y"), ("xftpConfig", Nothing)] <> substConfig <> serverInfoSubsts simplexmqSource information <> [("onionHost", strEncode <$> onionHost), ("iniFileName", Just "smp-server.ini")]
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
