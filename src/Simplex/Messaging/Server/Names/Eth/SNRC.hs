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
    decodeUtf8Text,
    decodeStringArray,
    isZeroOwner,
  )
where

import Crypto.Hash (Digest, Keccak_256, hash)
import Data.Bifunctor (first)
import qualified Data.ByteArray as BA
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Int (Int64)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (decodeUtf8')
import Simplex.Messaging.Protocol (NameOwner, NameRecord (..), mkNameOwner, unNameOwner)

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

-- | Read a uint256 at byte offset, fail if it doesn't fit in *signed* Int64.
-- Rejects both (a) any non-zero byte in the high 24 bytes and (b) the high
-- bit of the low 8 bytes being set — the latter is essential because Int64
-- would otherwise sign-flip a uint64 value into a negative integer, silently
-- corrupting downstream length math.
decodeWord256Int64 :: Int -> ByteString -> Either AbiError Int64
decodeWord256Int64 off buf
  | off + 32 > B.length buf = Left AbiTruncated
  | B.any (/= '\NUL') (B.take 24 (B.drop off buf)) = Left AbiNonZeroHighBytes
  | B.index buf (off + 24) >= '\x80' = Left AbiNonZeroHighBytes
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
  | otherwise = first AbiInvariantViolated $ mkNameOwner (B.take 20 (B.drop (off + 12) buf))

-- | Decode a Solidity `string` whose data starts at byte offset `off`.
-- Returns raw bytes; UTF-8 validity is the caller's choice (use
-- `decodeUtf8Text` if a Text is required).
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

-- | Decode a Solidity `string` as Text, failing with AbiBadUtf8 on
-- invalid UTF-8. This is what NameRecord decoder composition will use.
decodeUtf8Text :: Int -> Int -> Int -> ByteString -> Either AbiError Text
decodeUtf8Text headEnd off cap buf = do
  raw <- decodeString headEnd off cap buf
  either (const (Left AbiBadUtf8)) Right (decodeUtf8' raw)

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
--
-- Assumed Solidity signature:
--
--   function getRecord(bytes32 node) external view returns (
--     string name, string nickname, string website, string location,
--     string simplexContact, string simplexChannel,
--     string ETH, string BTC, string XMR, string DOT,
--     address owner, uint256 expiry
--   )
--
-- Tuple layout: 12 head slots (32 bytes each) followed by length-prefixed
-- string data in declaration order. Slots 0-9 are string tail offsets
-- (from the start of the buffer, which equals the start of the tuple for
-- a top-level eth_call return), slot 10 is the owner address, slot 11 is
-- the uint256 expiry.
--
-- Zero-owner (0x000...000) is reported as Right Nothing so the caller maps it
-- to NotFound (ENS-style sentinel). Records whose on-chain expiry is in the
-- past are also reported as Right Nothing — clients trust the server's filter
-- and the wire NameRecord carries no expiry field.
--
-- `nowSec` is the current Unix time the caller wants the expiry compared
-- against. Pass `0` to disable the expiry check (test scenarios); on-chain
-- `expiry = 0` means "never expires" (reserved names) and is always accepted.
--
-- `resolver` is the SNRC contract address that produced the record (i.e. the
-- address the server's eth_call was sent to), populated into `nrResolver`
-- since the ABI return doesn't carry it.
decodeGetRecord :: NameOwner -> Int64 -> ByteString -> Either AbiError (Maybe NameRecord)
decodeGetRecord resolver nowSec buf
  | B.length buf < headEnd = Left AbiTruncated
  | otherwise = do
      nameOff <- decodeWord256Int64 (slot 0) buf
      nicknameOff <- decodeWord256Int64 (slot 1) buf
      websiteOff <- decodeWord256Int64 (slot 2) buf
      locationOff <- decodeWord256Int64 (slot 3) buf
      simplexContactOff <- decodeWord256Int64 (slot 4) buf
      simplexChannelOff <- decodeWord256Int64 (slot 5) buf
      ethOff <- decodeWord256Int64 (slot 6) buf
      btcOff <- decodeWord256Int64 (slot 7) buf
      xmrOff <- decodeWord256Int64 (slot 8) buf
      dotOff <- decodeWord256Int64 (slot 9) buf
      owner <- decodeAddress (slot 10) buf
      expiry <- decodeWord256Int64 (slot 11) buf
      if isZeroOwner owner || isExpired nowSec expiry
        then pure Nothing
        else do
          nrName <- decodeStr 255 nameOff
          nrNickname <- decodeOptStr 255 nicknameOff
          nrWebsite <- decodeOptStr 255 websiteOff
          nrLocation <- decodeOptStr 255 locationOff
          nrSimplexContact <- decodeOptStr 1024 simplexContactOff
          nrSimplexChannel <- decodeOptStr 1024 simplexChannelOff
          nrEth <- decodeOptStr 255 ethOff
          nrBtc <- decodeOptStr 255 btcOff
          nrXmr <- decodeOptStr 255 xmrOff
          nrDot <- decodeOptStr 255 dotOff
          pure $
            Just
              NameRecord
                { nrName,
                  nrNickname,
                  nrWebsite,
                  nrLocation,
                  nrSimplexContact,
                  nrSimplexChannel,
                  nrEth,
                  nrBtc,
                  nrXmr,
                  nrDot,
                  nrOwner = owner,
                  nrResolver = resolver
                }
  where
    headSlots = 12 :: Int
    slotSize = 32 :: Int
    headEnd = headSlots * slotSize
    slot n = n * slotSize
    -- on-chain expiry == 0 means "never expires"; nowSec == 0 disables the check.
    isExpired now expiry = now /= 0 && expiry /= 0 && expiry < now
    decodeStr cap off = decodeUtf8Text headEnd (fromIntegral off) cap buf
    decodeOptStr cap off = nullToNothing <$> decodeStr cap off
    nullToNothing t = if T.null t then Nothing else Just t

isZeroOwner :: NameOwner -> Bool
isZeroOwner = (== B.replicate 20 '\NUL') . unNameOwner
