{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeApplications #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module CoreTests.ProtocolErrorTests where

import qualified Data.ByteString.Char8 as B
import qualified Data.Text as T
import Data.Text.Encoding (encodeUtf8)
import GHC.Generics (Generic)
import Generic.Random (genericArbitraryU)
import Simplex.FileTransfer.Protocol (XFTPErrorType (..))
import Simplex.Messaging.Agent.Protocol
import Simplex.Messaging.Encoding
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Protocol (CommandError (..), ErrorType (..))
import Simplex.Messaging.Transport (HandshakeError (..), TransportError (..))
import Simplex.RemoteControl.Types (RCErrorType (..))
import Test.Hspec
import Test.Hspec.QuickCheck (modifyMaxSuccess)
import Test.QuickCheck

protocolErrorTests :: Spec
protocolErrorTests = modifyMaxSuccess (const 1000) $ do
  describe "errors parsing / serializing" $ do
    it "should parse SMP protocol errors" . property $ \(err :: ErrorType) ->
      smpDecode (smpEncode err) == Right err
    it "should parse SMP agent errors" . property $ \(err :: AgentErrorType) ->
      errHasSpaces err
        || strDecode (strEncode err) == Right err
  where
    errHasSpaces = \case
      BROKER srv (RESPONSE e) -> hasSpaces srv || hasSpaces e
      BROKER srv _ -> hasSpaces srv
      _ -> False
    hasSpaces s = ' ' `B.elem` encodeUtf8 (T.pack s)

deriving instance Generic AgentErrorType

deriving instance Generic CommandErrorType

deriving instance Generic ConnectionErrorType

deriving instance Generic BrokerErrorType

deriving instance Generic SMPAgentError

deriving instance Generic AgentCryptoError

deriving instance Generic ErrorType

deriving instance Generic CommandError

deriving instance Generic TransportError

deriving instance Generic HandshakeError

deriving instance Generic XFTPErrorType

deriving instance Generic RCErrorType

instance Arbitrary AgentErrorType where arbitrary = genericArbitraryU

instance Arbitrary CommandErrorType where arbitrary = genericArbitraryU

instance Arbitrary ConnectionErrorType where arbitrary = genericArbitraryU

instance Arbitrary BrokerErrorType where arbitrary = genericArbitraryU

instance Arbitrary SMPAgentError where arbitrary = genericArbitraryU

instance Arbitrary AgentCryptoError where arbitrary = genericArbitraryU

instance Arbitrary ErrorType where arbitrary = genericArbitraryU

instance Arbitrary CommandError where arbitrary = genericArbitraryU

instance Arbitrary TransportError where arbitrary = genericArbitraryU

instance Arbitrary HandshakeError where arbitrary = genericArbitraryU

instance Arbitrary XFTPErrorType where arbitrary = genericArbitraryU

instance Arbitrary RCErrorType where arbitrary = genericArbitraryU
