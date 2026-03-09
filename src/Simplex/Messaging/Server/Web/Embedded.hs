{-# LANGUAGE TemplateHaskell #-}

module Simplex.Messaging.Server.Web.Embedded where

import Data.ByteString (ByteString)
import Data.FileEmbed (embedDir, embedFile)

indexHtml :: ByteString
indexHtml = $(embedFile "src/Simplex/Messaging/Server/Web/index.html")

linkHtml :: ByteString
linkHtml = $(embedFile "src/Simplex/Messaging/Server/Web/link.html")

mediaContent :: [(FilePath, ByteString)]
mediaContent = $(embedDir "src/Simplex/Messaging/Server/Web/media/")

wellKnown :: [(FilePath, ByteString)]
wellKnown = $(embedDir "src/Simplex/Messaging/Server/Web/.well-known/")
