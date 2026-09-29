{-# LANGUAGE NamedFieldPuns #-}

-- | EIP-1559 (type 2) transactions with an empty access list, signed for @eth_sendRawTransaction@.
module Simplex.Messaging.Eth.Transaction
  ( Eip1559Tx (..),
    signEip1559Tx,
  )
where

import Control.Concurrent.STM (TVar)
import Crypto.Number.Serialize (os2ip)
import Crypto.Random (ChaChaDRG)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Numeric.Natural (Natural)
import Simplex.Messaging.Crypto (keccak256)
import Simplex.Messaging.Crypto.Secp256k1 (RecoverableSignature (..), Secp256k1PrivateKey, signRecoverable)
import Simplex.Messaging.Eth.Address (Address, unAddress)
import Simplex.Messaging.Eth.RLP

data Eip1559Tx = Eip1559Tx
  { txChainId :: Natural,
    txNonce :: Natural,
    txMaxPriorityFeePerGas :: Natural,
    txMaxFeePerGas :: Natural,
    txGasLimit :: Natural,
    txTo :: Address,
    txValue :: Natural,
    txData :: ByteString
  }

-- | @0x02 || rlp([chainId, nonce, maxPriorityFeePerGas, maxFeePerGas, gasLimit, to, value, data, accessList, yParity, r, s])@, signing @keccak256@ of the same without the last three.
signEip1559Tx :: TVar ChaChaDRG -> Secp256k1PrivateKey -> Eip1559Tx -> IO ByteString
signEip1559Tx g sk Eip1559Tx {txChainId, txNonce, txMaxPriorityFeePerGas, txMaxFeePerGas, txGasLimit, txTo, txValue, txData} = do
  RecoverableSignature {rsCompact, rsRecId} <- signRecoverable g sk $ keccak256 $ typed fields
  let (r, s) = B.splitAt 32 rsCompact
  pure $ typed $ fields <> [rlpNatural (fromIntegral rsRecId), scalar r, scalar s]
  where
    fields =
      [ rlpNatural txChainId,
        rlpNatural txNonce,
        rlpNatural txMaxPriorityFeePerGas,
        rlpNatural txMaxFeePerGas,
        rlpNatural txGasLimit,
        RLPBytes $ unAddress txTo,
        rlpNatural txValue,
        RLPBytes txData,
        RLPList []
      ]
    typed items = B.cons 0x02 $ rlpEncode $ RLPList items
    scalar = rlpNatural . fromInteger . os2ip
