{-# LANGUAGE TemplateHaskell #-}

module Embedded where

import Data.ByteString (ByteString)
import Data.FileEmbed (embedDir, embedFile)
import Simplex.Messaging.Server.Web (EmbeddedContent (..))

embeddedContent :: EmbeddedContent
embeddedContent =
  EmbeddedContent
    { indexHtml = $(embedFile "apps/common/static/index.html"),
      linkHtml = $(embedFile "apps/common/static/link.html"),
      mediaContent = $(embedDir "apps/common/static/media/"),
      wellKnown = $(embedDir "apps/common/static/.well-known/")
    }
