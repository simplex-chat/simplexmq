module Simplex.FileTransfer.Client.Agent where
import Simplex.Messaging.Protocol (XFTPServer, ErrorType)
import Control.Concurrent.STM
import Simplex.FileTransfer.Client
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM

type XFTPClientVar msg = TMVar (Either ErrorType XFTPClient)

data XFTPClientAgent = XFTPClientAgent {
    xftpClients :: TMap XFTPServer XFTPClientVar
  }

newXFTPAgent ::  STM XFTPClientAgent
newXFTPAgent = do
  xftpClients <- TM.empty
  pure XFTPClientAgent {xftpClients}

getXFTPServerClient :: SMPClientAgent -> XFTPServer -> ExceptT ProtocolClientError IO XFTPClient
getXFTPServerClient ca@XFTPClientAgent {xftpClients} srv = undefined
