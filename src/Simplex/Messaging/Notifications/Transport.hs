module Simplex.Messaging.Notifications.Transport where

import Control.Monad.Except
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Transport
import Simplex.Messaging.Version

ntfBlockSize :: Int
ntfBlockSize = 512

supportedNTFServerVRange :: VersionRange
supportedNTFServerVRange = mkVersionRange 1 1

-- | Notifcations server transport handshake.
ntfServerHandshake :: Transport c => c -> C.KeyHash -> VersionRange -> ExceptT TransportError IO (THandle c)
ntfServerHandshake c _ _ = pure $ ntfTHandle c

-- | Notifcations server client transport handshake.
ntfClientHandshake :: Transport c => c -> C.KeyHash -> VersionRange -> ExceptT TransportError IO (THandle c)
ntfClientHandshake c _ _ = pure $ ntfTHandle c

ntfTHandle :: Transport c => c -> THandle c
ntfTHandle c = THandle {connection = c, sessionId = tlsUnique c, blockSize = ntfBlockSize, thVersion = 0}
