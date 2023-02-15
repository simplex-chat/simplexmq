module Simplex.FileTransfer.Supervisor where -- Agent? Driver?

import Control.Concurrent.STM
import Simplex.FileTransfer.Description
import Simplex.Messaging.Protocol
import Simplex.Messaging.TMap (TMap)
import UnliftIO

-- add temporary folder to save files to agent environment

-- can be part of agent
-- Maybe XFTPServer - Nothing is for worker dedicated to file decryption
data XFTPSupervisor = NtfSupervisor
  { xftpWorkers :: TMap (Maybe XFTPServer) (TMVar (), Async ())
  }

-- TODO monad
-- ? operate on files?
receiveFile :: FileDescription -> IO ()
receiveFile fd = do
  -- same as cli:
  --   - read and parse file description (if operating on files)
  --   - validate file description
  -- createRcvFile
  -- for each chunk create worker task to download and save chunk
  -- worker that successfully receives last chunk should create task to decrypt file
  undefined
