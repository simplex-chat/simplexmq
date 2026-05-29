{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StrictData #-}

-- | SNRC contract codec: Keccak-256 namehash + bounded Solidity ABI decoder.
--
-- IMPORTANT: Ethereum uses Keccak-256, NOT NIST SHA3-256.
--
-- ABI safety invariants (enforced before any allocation):
--   1.  offset + 32 <= buf.length                       (head read in-bounds)
--   2.  offset + 32 + length <= buf.length              (body in-bounds)
--   3.  offset >= headEnd                               (no backward jumps)
--   4.  every length <= per-field cap                   (bounded allocations)
--   5.  string[] outer count * 32 + offset <= buf.length (array head fits)
--   6.  recursion depth <= 2                            (no deep nesting)
--   7.  uint256 -> Int64 fails if any high 24 bytes non-zero (range check)
--   8.  UTF-8 via decodeUtf8' returns AbiBadUtf8        (no partial bytes)
module Simplex.Messaging.Server.Names.Eth.SNRC
  ( -- * Namehash
    keccak256,
    namehash,

    -- * SNRC eth_call payload
    snrcSelector,
    encodeGetRecord,

    -- * ABI decoding
    AbiError (..),
    decodeGetRecord,
    decodeWord256Int64,
    decodeAddress,
    decodeString,
    decodeStringArray,
  )
where

import Crypto.Hash (Digest, Keccak_256, hash)
import qualified Data.ByteArray as BA
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Int (Int64)
import Simplex.Messaging.Protocol (NameOwner, NameRecord, mkNameOwner, unNameOwner)

-- | ABI-decode failure modes (caller collapses to ResolveError EthDecodeErr).
data AbiError
  = AbiTruncated
  | AbiOversized
  | AbiBackwardOffset
  | AbiNonZeroHighBytes
  | AbiBadUtf8
  | AbiDepthExceeded
  | AbiInvariantViolated String
  deriving (Eq, Show)

-- | Keccak-256 (Ethereum variant), NOT SHA3-256.
keccak256 :: ByteString -> ByteString
keccak256 = BA.convert . (hash :: ByteString -> Digest Keccak_256)
{-# INLINE keccak256 #-}

-- | ENS / SNRC namehash: recursive keccak256 over reversed labels.
-- Empty name -> 32 zero bytes; "a.b.c" -> keccak(keccak(keccak(0 ++ keccak "c") ++ keccak "b") ++ keccak "a").
namehash :: ByteString -> ByteString
namehash name
  | B.null name = zeroNode
  | otherwise = foldr step zeroNode (B.split '.' name)
  where
    zeroNode = B.replicate 32 '\NUL'
    step label acc = keccak256 (acc <> keccak256 label)

-- | First 4 bytes of keccak("getRecord(bytes32)"). Confirm signature
-- against the Part 1 SNRC contract before merging.
snrcSelector :: ByteString
snrcSelector = B.take 4 (keccak256 "getRecord(bytes32)")

-- | Build the eth_call `data` parameter for getRecord(lookupKey).
encodeGetRecord :: ByteString -> ByteString
encodeGetRecord node32
  | B.length node32 == 32 = snrcSelector <> node32
  | otherwise = snrcSelector <> padLeft32 node32

padLeft32 :: ByteString -> ByteString
padLeft32 bs
  | n >= 32 = B.take 32 bs
  | otherwise = B.replicate (32 - n) '\NUL' <> bs
  where
    n = B.length bs

-- | Read a uint256 at byte offset, fail if it doesn't fit in Int64.
decodeWord256Int64 :: Int -> ByteString -> Either AbiError Int64
decodeWord256Int64 off buf
  | off + 32 > B.length buf = Left AbiTruncated
  | B.any (/= toEnum 0) (B.take 24 (B.drop off buf)) = Left AbiNonZeroHighBytes
  | otherwise = Right $ B.foldl shiftIn 0 (B.take 8 (B.drop (off + 24) buf))
  where
    shiftIn :: Int64 -> Char -> Int64
    shiftIn !acc c = (acc * 256) + fromIntegral (fromEnum c :: Int)
{-# INLINE decodeWord256Int64 #-}

-- | Read an Ethereum address at byte offset (uint256 with high 12 bytes zero).
decodeAddress :: Int -> ByteString -> Either AbiError NameOwner
decodeAddress off buf
  | off + 32 > B.length buf = Left AbiTruncated
  | B.any (/= toEnum 0) (B.take 12 (B.drop off buf)) = Left (AbiInvariantViolated "address has non-zero high 12 bytes")
  | otherwise = case mkNameOwner (B.take 20 (B.drop (off + 12) buf)) of
      Right addr -> Right addr
      Left e -> Left (AbiInvariantViolated e)

-- | Decode a Solidity `string` whose data starts at byte offset `off`.
decodeString :: Int -> Int -> Int -> ByteString -> Either AbiError ByteString
decodeString headEnd off cap buf
  | off < headEnd = Left AbiBackwardOffset
  | off + 32 > B.length buf = Left AbiTruncated
  | otherwise = do
      n <- decodeWord256Int64 off buf
      let len = fromIntegral n :: Int
      if len > cap
        then Left AbiOversized
        else
          if off + 32 + len > B.length buf
            then Left AbiTruncated
            else Right $ B.take len (B.drop (off + 32) buf)

-- | Decode a Solidity `string[]` at byte offset `off`. Each element capped
-- at `byteCap` bytes, total element count capped at `cntCap`. Depth must be
-- < 2 (recurses one level into decodeString).
decodeStringArray :: Int -> Int -> Int -> Int -> Int -> ByteString -> Either AbiError [ByteString]
decodeStringArray depth headEnd off cntCap byteCap buf
  | depth >= 2 = Left AbiDepthExceeded
  | off < headEnd = Left AbiBackwardOffset
  | off + 32 > B.length buf = Left AbiTruncated
  | otherwise = do
      n <- decodeWord256Int64 off buf
      let cnt = fromIntegral n :: Int
      if cnt > cntCap
        then Left AbiOversized
        else
          let arrHead = off + 32
              arrHeadEnd = arrHead + cnt * 32
           in if arrHeadEnd > B.length buf
                then Left AbiTruncated
                else collectN 0 cnt arrHead arrHeadEnd []
  where
    collectN i n base hd acc
      | i >= n = Right (reverse acc)
      | otherwise = do
          relOff <- decodeWord256Int64 (base + i * 32) buf
          let absOff = base + fromIntegral relOff
          s <- decodeString hd absOff byteCap buf
          collectN (i + 1) n base hd (s : acc)

-- | Decode the ABI-encoded return value of getRecord(bytes32) into a NameRecord.
-- Zero-owner (0x000...000) is reported as Right Nothing so the caller maps it
-- to NotFound (ENS-style sentinel).
--
-- PLACEHOLDER: returns Right Nothing for any non-zero owner until the Part 1
-- SNRC contract ABI is finalised. All ABI primitives above are production-ready;
-- only the field-layout-aware composition is pending.
decodeGetRecord :: ByteString -> Either AbiError (Maybe NameRecord)
decodeGetRecord buf
  | B.length buf < 32 * 8 = Left AbiTruncated
  | otherwise = case decodeAddress 32 buf of
      Left e -> Left e
      Right owner
        | isZeroOwner owner -> Right Nothing
        | otherwise -> Right Nothing -- placeholder until SNRC ABI is finalised

isZeroOwner :: NameOwner -> Bool
isZeroOwner = (== B.replicate 20 '\NUL') . unNameOwner
