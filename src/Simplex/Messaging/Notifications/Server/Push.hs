module Simplex.Messaging.Notifications.Server.Push where

import Control.Concurrent.STM
import Data.ByteString.Char8 (ByteString)
import Simplex.Messaging.Protocol (NotifierId, SMPServer)

data NtfPushPayload = NPVerification ByteString | NPNotification SMPServer NotifierId | NPPing

class PushProvider p where
  newPushProvider :: STM p
  requestBody :: p -> NtfPushPayload -> ByteString -- ?
