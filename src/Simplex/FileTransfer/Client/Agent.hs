{-# LANGUAGE NamedFieldPuns #-}

module Simplex.FileTransfer.Client.Agent where

import Control.Concurrent.STM
import Control.Monad.Except (ExceptT)
import Simplex.FileTransfer.Client
import Simplex.Messaging.Client (ProtocolClientError)
import Simplex.Messaging.Protocol (ErrorType, XFTPServer)
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM

type XFTPClientVar = TMVar (Either ErrorType XFTPClient)

data XFTPClientAgent = XFTPClientAgent
  { xftpClients :: TMap XFTPServer XFTPClientVar
  }

newXFTPAgent :: STM XFTPClientAgent
newXFTPAgent = do
  xftpClients <- TM.empty
  pure XFTPClientAgent {xftpClients}

getXFTPServerClient :: XFTPClientAgent -> XFTPServer -> ExceptT ProtocolClientError IO XFTPClient
getXFTPServerClient ca@XFTPClientAgent {xftpClients} srv = undefined
