module Simplex.Messaging.Agent.Types.MsgTypes where

-- data CommonMsg = CommonMsg {
--   shared_fields :: Int,
--   another :: String
-- }

-- data MsgType = MRcv | MSnd deriving (Eq, Show)

-- data SMsgType :: MsgType -> Type where
--   SRcvMsg :: SMsgType RcvMsg
--   SSndMsg :: SMsgType SndMsg

-- data Msg (t :: MsgType) where
--   RcvMsg :: {
--     common :: CommonMsg,
--     m_broker :: Int,
--     m_sender :: Int,
--     m_status :: Int,
--     m_body :: Int
--   } -> Msg RcvMsg
--   SndMsg :: {
--     common :: CommonMsg,
--     s_sfdg :: Int
--   } -> Msg SndMsg

-- f :: Msg t -> IO ()

-- data SomeMsg = forall t. SomeMsg (SMsgType t) (Msg t)

-- data DeliveryStatus
--   = MDTransmitted -- SMP: SEND sent / MSG received
--   | MDConfirmed -- SMP: OK received / ACK sent
--   | MDAcknowledged AckStatus -- SAMP: RCVD sent to agent client / ACK received from agent client and sent to the server
