{-# LANGUAGE OverloadedStrings #-}

module Simplex.Messaging.Notifications.Server.Push.APNS.Internal where

import qualified Data.Aeson as J
import qualified Data.CaseInsensitive as CI
import Network.HTTP.Types (HeaderName)
import Simplex.Messaging.Parsers (defaultJSON)

hApnsTopic :: HeaderName
hApnsTopic = CI.mk "apns-topic"

hApnsPushType :: HeaderName
hApnsPushType = CI.mk "apns-push-type"

hApnsPriority :: HeaderName
hApnsPriority = CI.mk "apns-priority"

apnsJSONOptions :: J.Options
apnsJSONOptions = defaultJSON {J.sumEncoding = J.UntaggedValue, J.fieldLabelModifier = J.camelTo2 '-'}
