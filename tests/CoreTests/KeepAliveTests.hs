{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE NumericUnderscores #-}

module CoreTests.KeepAliveTests where

import Control.Exception (bracket, handle)
import Control.Monad (forever)
import qualified Data.ByteString.Char8 as B
import Data.Time.Clock (diffUTCTime, getCurrentTime)
import Foreign.C (CInt)
import Foreign.C.Error (Errno (..), eTIMEDOUT)
import GHC.IO.Exception (IOException (..))
import Network.Socket
import Network.Socket.ByteString (sendAll)
import Simplex.Messaging.Transport.KeepAlive
import System.Info (os)
import System.Timeout (timeout)
import Test.Hspec hiding (fit, it)
import Util

keepAliveTests :: Spec
keepAliveTests = linuxOnly $ it "should fail connection with data not accepted by peer only with unackedDataTimeout" testUnackedDataTimeout
  where
    linuxOnly t = if os == "linux" then t else skip "Linux only" t

testUnackedDataTimeout :: IO ()
testUnackedDataTimeout = do
  start <- getCurrentTime
  sendToPeerNotReading (Just True) `shouldReturn` Just (Just timedOut)
  (`diffUTCTime` start) <$> getCurrentTime >>= (`shouldSatisfy` (>= 2))
  sendToPeerNotReading Nothing `shouldReturn` Nothing
  where
    Errno timedOut = eTIMEDOUT

sendToPeerNotReading :: Maybe Bool -> IO (Maybe (Maybe CInt))
sendToPeerNotReading unackedDataTimeout =
  bracket (socket AF_INET Stream defaultProtocol) close $ \srv -> do
    bind srv $ SockAddrInet 0 $ tupleToHostAddress (127, 0, 0, 1)
    listen srv 1
    addr <- getSocketName srv
    bracket (socket AF_INET Stream defaultProtocol) close $ \c -> do
      setSocketKeepAlive c KeepAliveOpts {keepIdle = 1, keepIntvl = 1, keepCnt = 1, unackedDataTimeout}
      connect c addr
      bracket (fst <$> accept srv) close $ \_ ->
        timeout 8_000000 $ handle (pure . ioe_errno) $ forever $ sendAll c $ B.replicate 65536 'x'
