{-# LANGUAGE TemplateHaskell #-}

module Static.Embedded where

import Data.FileEmbed (embedDir, embedFile)
import Data.ByteString (ByteString)

indexHtml :: ByteString
indexHtml = $(embedFile "apps/smp-server/static/index.html")

linkHtml :: ByteString
linkHtml = $(embedFile "apps/smp-server/static/link.html")

mediaContent :: [(FilePath, ByteString)]
mediaContent = $(embedDir "apps/smp-server/static/media/")

wellKnown :: [(FilePath, ByteString)]
wellKnown = $(embedDir "apps/smp-server/static/.well-known/")
