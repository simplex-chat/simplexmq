{-# LANGUAGE TemplateHaskell #-}

module Web.Embedded where

import Data.FileEmbed (embedDir, embedFile)
import Simplex.Messaging.Server.Web (EmbeddedContent (..))

embeddedContent :: EmbeddedContent
embeddedContent =
  EmbeddedContent
    { indexHtml = $(embedFile "apps/common/Web/static/index.html"),
      linkHtml = $(embedFile "apps/common/Web/static/link.html"),
      mediaContent = $(embedDir "apps/common/Web/static/media/"),
      wellKnown = $(embedDir "apps/common/Web/static/.well-known/")
    }
