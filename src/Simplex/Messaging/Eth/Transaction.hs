{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | EIP-1559 (type 2) transactions with an empty access list, signed for @eth_sendRawTransaction@.
module Simplex.Messaging.Eth.Transaction
  ( Eip1559Tx (..),
    signEip1559Tx,
    eip1559SigningHash,
    decodeEip1559Tx,
  )
where

import Control.Concurrent.STM (TVar)
import Control.Monad (when)
import Crypto.Number.Serialize (os2ip)
import Crypto.Random (ChaChaDRG)
import qualified Data.Attoparsec.ByteString as A
import Data.Bits (shiftR)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Data.WideWord.Word128 (Word128 (..))
import Data.WideWord.Word256 (Word256 (..))
import Data.Word (Word32, Word64, Word8)
import Simplex.Messaging.Crypto (keccak256)
import Simplex.Messaging.Crypto.Secp256k1 (RecoverableSignature (..), Secp256k1PrivateKey, signRecoverable)
import Simplex.Messaging.Encoding (smpEncode)
import Simplex.Messaging.Eth.Address (Address, addressFromBytes, unAddress)
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
  deriving (Eq, Show)

-- | @0x02 || rlp([chainId, nonce, maxPriorityFeePerGas, maxFeePerGas, gasLimit, to, value, data, accessList, yParity, r, s])@, signing @keccak256@ of the same without the last three.
signEip1559Tx :: TVar ChaChaDRG -> Secp256k1PrivateKey -> Eip1559Tx -> IO (Either String ByteString)
signEip1559Tx g sk tx =
  signed <$$> signRecoverable g sk (eip1559SigningHash tx)
  where
    signed RecoverableSignature {rsR, rsS, rsRecId} = typed $ txFields tx <> [scalarItem (B.singleton rsRecId), scalarItem rsR, scalarItem rsS]

eip1559SigningHash :: Eip1559Tx -> ByteString
eip1559SigningHash = keccak256 . typed . txFields

decodeEip1559Tx :: ByteString -> Either String (Eip1559Tx, RecoverableSignature)
decodeEip1559Tx raw = case B.uncons raw of
  Just (txType, encoded) | txType == eip1559Type -> A.parseOnly (rlpP <* A.endOfInput) encoded >>= signedTx
  _ -> Left "transaction: not an EIP-1559 transaction"
  where
    signedTx = \case
      RLPList [chainId, nonce, tip, maxFee, gas, RLPBytes to, value, RLPBytes txData, RLPList [], yParity, r, s] -> do
        txChainId <- word chainId
        txNonce <- word nonce
        txMaxPriorityFeePerGas <- word tip
        txMaxFeePerGas <- word maxFee
        txGasLimit <- word gas
        txTo <- addressFromBytes to
        txValue <- word value
        rsRecId <- word yParity
        when (rsRecId > 1) $ Left "transaction: yParity above 1"
        rsR <- scalarBytes r
        rsS <- scalarBytes s
        pure (Eip1559Tx {txChainId, txNonce, txMaxPriorityFeePerGas, txMaxFeePerGas, txGasLimit, txTo, txValue, txData}, RecoverableSignature {rsR, rsS, rsRecId})
      _ -> Left "transaction: not a signed EIP-1559 transaction"
    word :: forall a. (Integral a, Bounded a) => RLPItem -> Either String a
    word item = scalar item >>= \b -> if os2ip b <= toInteger (maxBound :: a) then Right (fromInteger $ os2ip b) else Left "transaction: a scalar over its width"
    scalarBytes item = scalar item >>= \b -> if B.length b <= signatureScalarSize then Right (B.replicate (signatureScalarSize - B.length b) 0 <> b) else Left "transaction: a signature scalar over 32 bytes"
    scalar = \case
      RLPBytes b | B.take 1 b /= B.singleton 0 -> Right b
      _ -> Left "transaction: not a scalar"

txFields :: Eip1559Tx -> [RLPItem]
txFields Eip1559Tx {txChainId, txNonce, txMaxPriorityFeePerGas, txMaxFeePerGas, txGasLimit, txTo, txValue, txData} =
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
  where
    w64 = scalarItem . be64
    w128 (Word128 hi lo) = scalarItem $ be64 hi <> be64 lo
    w256 (Word256 a3 a2 a1 a0) = scalarItem $ be64 a3 <> be64 a2 <> be64 a1 <> be64 a0
    be64 n = smpEncode (fromIntegral (n `shiftR` 32) :: Word32) <> smpEncode (fromIntegral n :: Word32)

typed :: [RLPItem] -> ByteString
typed items = B.cons eip1559Type $ rlpEncode $ RLPList items

eip1559Type :: Word8
eip1559Type = 0x02

signatureScalarSize :: Int
signatureScalarSize = 32
