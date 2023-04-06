{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE OverloadedStrings #-}

module Simplex.FileTransfer.Client.Presets where

import Data.List.NonEmpty (NonEmpty)
import Simplex.Messaging.Protocol (XFTPServerWithAuth)

defaultXFTPServers :: NonEmpty XFTPServerWithAuth
defaultXFTPServers =
  [ "xftp://da1aH3nOT-9G8lV7bWamhxpDYdJ1xmW7j3JpGaDR5Ug=@xftp1.simplex.im,blisztokwh6alt5oem45f2eksm2xdowxszmhjesntcyolmhutoon7sid.onion",
    "xftp://5vog2Imy1ExJB_7zDZrkV1KDWi96jYFyy9CL6fndBVw=@xftp2.simplex.im,jk6jybnel5hin2am5omd7g3hyvb4tfkyl7ea4vx5ldi7gpvz5ogqtcqd.onion",
    "xftp://PYa32DdYNFWi0uZZOprWQoQpIk5qyjRJ3EF7bVpbsn8=@xftp3.simplex.im,pqhchr4bpkzef5wra4hnmzvppn5j5mjrpzkh5ixx6mhylnxxd6lmwnad.onion",
    "xftp://k_GgQl40UZVV0Y4BX9ZTyMVqX5ZewcLW0waQIl7AYDE=@xftp4.simplex.im,q2lrjgiyo2efyweksavwxh3dlsrxetaxjztde2x5nateugrtrwzvmdid.onion",
    "xftp://-bIo6o8wuVc4wpZkZD3tH-rCeYaeER_0lz1ffQcSJDs=@xftp5.simplex.im,2kikdbdhlrluburwt6q6rnoxvezcm2ifx2hj463jlunkeftlzm7hf3qd.onion",
    "xftp://6nSvtY9pJn6PXWTAIMNl95E1Kk1vD7FM2TeOA64CFLg=@xftp6.simplex.im,tg3fmu6houq7vfqlsipm2qqzhtpgxesnuydqozx3khojxydhs53sbbyd.onion"
  ]
