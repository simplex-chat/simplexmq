{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE OverloadedStrings #-}

module Simplex.FileTransfer.Client.Presets where

import Data.List.NonEmpty (NonEmpty)
import Simplex.Messaging.Protocol (XFTPServerWithAuth)

defaultXFTPServers :: NonEmpty XFTPServerWithAuth
defaultXFTPServers =
  [ "xftp://da1aH3nOT-9G8lV7bWamhxpDYdJ1xmW7j3JpGaDR5Ug=@xftp1.simplex.im",
    "xftp://5vog2Imy1ExJB_7zDZrkV1KDWi96jYFyy9CL6fndBVw=@xftp2.simplex.im",
    "xftp://PYa32DdYNFWi0uZZOprWQoQpIk5qyjRJ3EF7bVpbsn8=@xftp3.simplex.im",
    "xftp://k_GgQl40UZVV0Y4BX9ZTyMVqX5ZewcLW0waQIl7AYDE=@xftp4.simplex.im",
    "xftp://-bIo6o8wuVc4wpZkZD3tH-rCeYaeER_0lz1ffQcSJDs=@xftp5.simplex.im",
    "xftp://6nSvtY9pJn6PXWTAIMNl95E1Kk1vD7FM2TeOA64CFLg=@xftp6.simplex.im"
  ]
