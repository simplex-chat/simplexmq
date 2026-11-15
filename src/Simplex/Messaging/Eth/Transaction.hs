{-# LANGUAGE NamedFieldPuns #-}

-- | EIP-1559 (type 2) transactions with an empty access list, signed for @eth_sendRawTransaction@.
module Simplex.Messaging.Eth.Transaction
  ( Eip1559Tx (..),
    signEip1559Tx,
  )
where

import Control.Concurrent.STM (TVar)
import Crypto.Random (ChaChaDRG)
import Data.Bits (shiftR)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Data.WideWord.Word128 (Word128 (..))
import Data.WideWord.Word256 (Word256 (..))
import Data.Word (Word32, Word64)
import Simplex.Messaging.Crypto (keccak256)
import Simplex.Messaging.Crypto.Secp256k1 (RecoverableSignature (..), Secp256k1PrivateKey, signRecoverable)
import Simplex.Messaging.Encoding (smpEncode)
import Simplex.Messaging.Eth.Address (Address, unAddress)
import Simplex.Messaging.Eth.RLP
import Simplex.Messaging.Util ((<$$>))

-- | Each width is the narrowest that both geth and reth accept.
data Eip1559Tx = Eip1559Tx
  { txChainId :: Word64,
    txNonce :: Word64,
    txMaxPriorityFeePerGas :: Word128,
    txMaxFeePerGas :: Word128,
    txGasLimit :: Word64,
    txTo :: Address,
    txValue :: Word256,
    txData :: ByteString
  }

-- | @0x02 || rlp([chainId, nonce, maxPriorityFeePerGas, maxFeePerGas, gasLimit, to, value, data, accessList, yParity, r, s])@, signing @keccak256@ of the same without the last three.
signEip1559Tx :: TVar ChaChaDRG -> Secp256k1PrivateKey -> Eip1559Tx -> IO (Either String ByteString)
signEip1559Tx g sk Eip1559Tx {txChainId, txNonce, txMaxPriorityFeePerGas, txMaxFeePerGas, txGasLimit, txTo, txValue, txData} =
  signed <$$> signRecoverable g sk (keccak256 $ typed fields)
  where
    signed RecoverableSignature {rsR, rsS, rsRecId} = typed $ fields <> [scalarItem (B.singleton rsRecId), scalarItem rsR, scalarItem rsS]
    fields =
      [ w64 txChainId,
        w64 txNonce,
        w128 txMaxPriorityFeePerGas,
        w128 txMaxFeePerGas,
        w64 txGasLimit,
        RLPBytes $ unAddress txTo,
        w256 txValue,
        RLPBytes txData,
        RLPList []
      ]
    w64 = scalarItem . be64
    w128 (Word128 hi lo) = scalarItem $ be64 hi <> be64 lo
    w256 (Word256 a3 a2 a1 a0) = scalarItem $ be64 a3 <> be64 a2 <> be64 a1 <> be64 a0
    be64 n = smpEncode (fromIntegral (n `shiftR` 32) :: Word32) <> smpEncode (fromIntegral n :: Word32)
    typed items = B.cons 0x02 $ rlpEncode $ RLPList items
