{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}

module CoreTests.EthCryptoTests (ethCryptoTests) where

import Control.Concurrent.STM (TVar, atomically)
import Control.Monad (forM_)
import Crypto.Number.Serialize (i2osp)
import Crypto.Random (ChaChaDRG)
import qualified Data.Aeson as J
import qualified Data.ByteArray as BA
import qualified Data.ByteArray.Encoding as BAE
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC
import Data.Char (toLower)
import Data.Either (isLeft, isRight)
import Data.FileEmbed (embedFile)
import Data.List (elemIndex, foldl', nub)
import qualified Data.Map.Strict as M
import Data.Maybe (fromJust, isJust, isNothing, listToMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (decodeLatin1, encodeUtf8)
import Data.Word (Word32)
import qualified Simplex.Messaging.Crypto as C
import qualified Simplex.Messaging.Crypto.BIP32 as B32
import qualified Simplex.Messaging.Crypto.BIP39 as B39
import Simplex.Messaging.Crypto.BIP39.English (englishWordList)
import Simplex.Messaging.Crypto.BIP44
import qualified Simplex.Messaging.Crypto.Secp256k1 as S
import Simplex.Messaging.Encoding.String (strDecode, strEncode)
import Simplex.Messaging.Eth.Address
import Test.Hspec hiding (fit, it)
import Util

ethCryptoTests :: Spec
ethCryptoTests = do
  g <- runIO C.newRandom
  describe "Keccak-256" keccakTests
  describe "secp256k1" $ secp256k1Tests g
  describe "BIP-39" $ bip39Tests g
  describe "BIP-32" $ bip32Tests g
  describe "BIP-44 derivation" $ derivationTests g
  describe "EIP-55 addresses" eip55Tests

-- helpers

hx :: BA.ByteArray a => ByteString -> a
hx s = either (const $ error $ "bad hex literal: " <> BC.unpack s) id $ BAE.convertFromBase BAE.Base16 s

toHex :: BA.ByteArrayAccess a => a -> ByteString
toHex = BAE.convertToBase BAE.Base16

right :: Either String a -> a
right = either (error . ("unexpected Left: " <>)) id

xkHex :: B32.ExtendedKey -> (ByteString, ByteString)
xkHex xk = (toHex . S.unPrivateKey $ B32.xkKey xk, toHex $ B32.xkChainCode xk)

-- | Key and chain code of a base58check @xprv@: 4 version, 1 depth, 4 fingerprint, 4 child, 32 chain code, 0x00 and 32 key bytes, 4 checksum.
xprvHex :: ByteString -> (ByteString, ByteString)
xprvHex s
  | B.length payload /= 78 || B.index payload 45 /= 0 || checksum /= B.take 4 (C.sha256Hash $ C.sha256Hash payload) = error $ "bad xprv: " <> BC.unpack s
  | otherwise = (toHex $ B.drop 46 payload, toHex $ B.take 32 $ B.drop 13 payload)
  where
    (payload, checksum) = B.splitAt 78 $ base58Decode s

base58Decode :: ByteString -> ByteString
base58Decode s = B.replicate (B.length zeros) 0 <> i2osp n
  where
    (zeros, digits) = BC.span (== '1') s
    n = foldl' (\acc c -> acc * 58 + fromIntegral (digit c)) (0 :: Integer) (BC.unpack digits)
    digit c = fromJust $ elemIndex c "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"

-- fixtures

-- https://github.com/trezor/python-mnemonic/blob/master/vectors.json
bip39VectorsFile :: ByteString
bip39VectorsFile = $(embedFile "tests/fixtures/bip39-vectors.json")

-- https://github.com/bitcoin/bips/blob/master/bip-0032.mediawiki
bip32SpecFile :: ByteString
bip32SpecFile = $(embedFile "tests/fixtures/bip-0032.mediawiki")

-- | Entropy, phrase, seed with the passphrase @TREZOR@, and master @xprv@ for each English vector.
bip39Vectors :: [(ByteString, ByteString, ByteString, ByteString)]
bip39Vectors = map row $ (right (J.eitherDecodeStrict bip39VectorsFile) :: M.Map Text [[Text]]) M.! "english"
  where
    row [ent, phrase, seed, xprv] = (encodeUtf8 ent, encodeUtf8 phrase, encodeUtf8 seed, encodeUtf8 xprv)
    row r = error $ "unexpected vector: " <> show r

bip32Sections :: [(ByteString, [ByteString])]
bip32Sections = go $ dropWhile (not . isVector) (BC.lines bip32SpecFile)
  where
    isVector = B.isPrefixOf "===Test vector"
    go (h : rest) | isVector h = let (body, rest') = break (B.isPrefixOf "==") rest in (h, body) : go rest'
    go _ = []

-- | Vectors 1 to 4: name, seed, and the chains with their @xprv@. Vector 5 has no seed.
bip32Vectors :: [(String, ByteString, [(String, [Word32], ByteString)])]
bip32Vectors = [(BC.unpack $ BC.filter (/= '=') h, seed, chains body) | (h, body) <- bip32Sections, Just seed <- [listToMaybe $ prefixed "Seed (hex): " body]]
  where
    chains (l : ls) | Just c <- B.stripPrefix "* Chain " l, Just prv <- listToMaybe $ prefixed "** ext prv: " (take 2 ls) = (T.unpack $ chain c, path $ chain c, prv) : chains ls
    chains (_ : ls) = chains ls
    chains [] = []
    chain = T.replace "<sub>H</sub>" "'" . decodeLatin1
    path = map component . drop 1 . T.splitOn "/"
    component s = maybe (index s) (B32.hardened . index) $ T.stripSuffix "'" s
    index = read . T.unpack

-- | The vector 5 keys outside @[1, n-1]@; its other entries are malformed serializations, which this library does not parse.
bip32InvalidKeys :: [(String, ByteString)]
bip32InvalidKeys =
  [ (BC.unpack reason, xprv)
    | (h, body) <- bip32Sections,
      h == "===Test vector 5===",
      e <- prefixed "* " body,
      let (xprv, rest) = BC.break (== ' ') e
          reason = BC.takeWhile (/= ')') $ B.drop 2 rest,
      "private key" `B.isPrefixOf` reason
  ]

prefixed :: ByteString -> [ByteString] -> [ByteString]
prefixed p = foldr (\l acc -> maybe acc (: acc) $ B.stripPrefix p l) []

keccakTests :: Spec
keccakTests = do
  it "hashes the empty string" $
    toHex (C.keccak256 "") `shouldBe` "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470"
  it "hashes abc" $
    toHex (C.keccak256 "abc") `shouldBe` "4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45"

secp256k1Tests :: TVar ChaChaDRG -> Spec
secp256k1Tests g = do
  it "derives the known address for a known key" $
    (strEncode <$> addressFromPrivateKey g testKey) `shouldReturn` "0x2c7536E3605D9C16a7a3D7b1898e529396a65c23"
  it "serializes a public key in both SEC1 forms" $ do
    pk <- S.secp256k1PublicKey g testKey
    comp <- S.serializePublicKey g S.Compressed pk
    uncomp <- S.serializePublicKey g S.Uncompressed pk
    B.length comp `shouldBe` 33
    B.length uncomp `shouldBe` 65
    B.head uncomp `shouldBe` 0x04
    -- both forms contain the same x coordinate, and the compressed prefix encodes the parity of y
    B.take 32 (B.drop 1 uncomp) `shouldBe` B.drop 1 comp
    B.head comp `shouldBe` (if odd (B.last uncomp) then 0x03 else 0x02)
  forM_ bip32InvalidKeys $ \(reason, xprv) ->
    it ("rejects the BIP-32 vector 5 " <> reason) $
      isLeft (S.mkPrivateKey (hx . fst $ xprvHex xprv)) `shouldBe` True
  it "rejects a short private key" $
    isLeft (S.mkPrivateKey (BA.replicate 31 1)) `shouldBe` True
  it "adds a tweak to a private key" $
    (fmap (toHex . S.unPrivateKey) <$> S.privateKeyTweakAdd g testKey (BA.replicate 31 0 <> BA.singleton 1))
      `shouldReturn` Just "4c0883a69102937d6231471b5dbb6204fe5129617082792ae468d01a3f362319"
  it "returns Nothing for a tweak that makes the key zero" $
    (isNothing <$> S.privateKeyTweakAdd g testKey (hx "b3f77c596efd6c829dceb8e4a2449df9bc5db3853ec62710db698e7291001e29"))
      `shouldReturn` True
  it "returns Nothing for a tweak that is not 32 bytes" $
    (isNothing <$> S.privateKeyTweakAdd g testKey (BA.replicate 31 1)) `shouldReturn` True
  where
    testKey = right $ S.mkPrivateKey (hx "4c0883a69102937d6231471b5dbb6204fe5129617082792ae468d01a3f362318")

bip39Tests :: TVar ChaChaDRG -> Spec
bip39Tests g = do
  describe "official English vectors" $
    forM_ (zip [0 :: Int ..] bip39Vectors) $ \(i, (entHex, phrase, seedHex, xprv)) ->
      it ("vector " <> show i) $ do
        let ent = right $ B39.mkEntropy (hx entHex)
            seed = B39.entropySeed ent "TREZOR"
        B39.entropyPhrase ent `shouldBe` phrase
        B39.parsePhrase (decodeLatin1 phrase) `shouldBe` Right ent
        toHex seed `shouldBe` seedHex
        xkHex (right $ B32.masterKey seed) `shouldBe` xprvHex xprv
  it "embeds the upstream wordlist, unchanged" $
    -- sha256 of bitcoin/bips/bip-0039/english.txt
    C.sha256Hash (BC.unlines englishWordList)
      `shouldBe` hx "2f5eed53a4727b4bf8880d8f3f199efc90e58503646d9ff8eff3a2ed3b24dbda"
  it "embeds the upstream test vectors, unchanged" $ do
    C.sha256Hash bip39VectorsFile `shouldBe` hx "fa3b937b7cff9c9b8ecd3aa011faeb8d6dd67993174b72326e83f4de8fdb30f8"
    length bip39Vectors `shouldBe` 24
  it "rejects a bad checksum" $
    B39.parsePhrase "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon"
      `shouldSatisfy` isLeft
  it "rejects a word outside the list" $
    B39.parsePhrase "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon simplex"
      `shouldSatisfy` isLeft
  it "rejects an empty phrase, counting the words" $
    B39.parsePhrase "" `shouldBe` Left "Failed reading: mnemonic: expected 12, 15, 18, 21 or 24 words, got 0"
  it "rejects a word with trailing punctuation, naming it" $
    B39.parsePhrase "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about."
      `shouldBe` Left "Failed reading: mnemonic: not in wordlist: about."
  it "rejects a wrong word count" $
    B39.parsePhrase "abandon abandon about" `shouldSatisfy` isLeft
  it "accepts a capitalised phrase and normalises it" $
    (B39.entropyPhrase <$> B39.parsePhrase "Abandon ABANDON abandon abandon abandon abandon abandon abandon abandon abandon abandon About")
      `shouldBe` Right canonicalPhrase
  it "accepts extra whitespace" $
    B39.parsePhrase "  abandon\tabandon  abandon abandon abandon abandon abandon abandon abandon abandon abandon about "
      `shouldBe` Right canonicalEntropy
  it "accepts Unicode whitespace between words" $ do
    let spaced sep = T.intercalate sep . T.words $ decodeLatin1 canonicalPhrase
    B39.parsePhrase (spaced "\x00A0") `shouldBe` Right canonicalEntropy
    B39.parsePhrase (spaced "\x3000") `shouldBe` Right canonicalEntropy
  it "rejects an invalid entropy size" $
    B39.mkEntropy (BA.replicate 17 0) `shouldSatisfy` isLeft
  it "generates entropy whose phrase parses back" $
    forM_ (zip [minBound .. maxBound] [12, 15, 18, 21, 24]) $ \(s, n) -> do
      ent <- atomically $ B39.randomEntropy s g
      B39.entropyWordCount ent `shouldBe` n
      B39.parsePhrase (decodeLatin1 $ B39.entropyPhrase ent) `shouldBe` Right ent

canonicalPhrase :: ByteString
canonicalPhrase = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

canonicalEntropy :: B39.WalletEntropy
canonicalEntropy = right $ B39.parsePhrase (decodeLatin1 canonicalPhrase)

bip32Tests :: TVar ChaChaDRG -> Spec
bip32Tests g = do
  it "embeds the upstream specification, unchanged" $ do
    C.sha256Hash bip32SpecFile `shouldBe` hx "e5e00a8289db2f681052cf24a745320afc225e66b25d1e489a7c884d2fc7f11f"
    map (\(name, _, chains) -> (name, length chains)) bip32Vectors `shouldBe` [("Test vector 1", 6), ("Test vector 2", 6), ("Test vector 3", 2), ("Test vector 4", 3)]
    map fst bip32InvalidKeys `shouldBe` ["private key 0 not in 1..n-1", "private key n not in 1..n-1"]
  forM_ bip32Vectors $ \(name, seedHex, chains) ->
    describe name $
      forM_ chains $ \(chain, path, xprv) ->
        it chain $ do
          xk <- B32.derivePath g (right $ B32.masterKey (hx seedHex)) path
          xkHex xk `shouldBe` xprvHex xprv
  it "rejects a seed shorter than 16 bytes" $
    isLeft (B32.masterKey (BA.replicate 15 1)) `shouldBe` True
  it "rejects a seed longer than 64 bytes" $
    isLeft (B32.masterKey (BA.replicate 65 1)) `shouldBe` True
  it "renders a path" $
    B32.renderPath [B32.hardened 44, B32.hardened 60, B32.hardened 0, 0, 0] `shouldBe` "m/44'/60'/0'/0/0"
  it "parses a wallet master back from its storage form" $
    (xkHex . B32.walletMasterKey <$> B32.parseWalletMaster (B39.unEntropy canonicalEntropy) (B32.masterBytes canonicalMaster))
      `shouldBe` Right (xkHex $ B32.walletMasterKey canonicalMaster)
  it "rejects a stored master the entropy does not derive" $ do
    let stored = B32.masterBytes canonicalMaster
    isLeft (B32.parseWalletMaster (B39.unEntropy canonicalEntropy) (BA.xor stored (BA.replicate 64 1 :: BA.ScrubbedBytes))) `shouldBe` True
    isLeft (B32.parseWalletMaster (B39.unEntropy canonicalEntropy) (BA.take 63 stored)) `shouldBe` True
    isLeft (B32.parseWalletMaster (BA.replicate 17 0) stored) `shouldBe` True

canonicalMaster :: B32.WalletMaster
canonicalMaster = B32.mkWalletMaster canonicalEntropy ""

derivationTests :: TVar ChaChaDRG -> Spec
derivationTests g = do
  it "derives the standard BIP-39 seed" $
    toHex seed
      `shouldBe` "5eb00bbddcf069084889a8ab9155568165f5c453ccb85e70811aaed6f6da5fc19a5ac40b389cd370d086206dec8aa6c43daea6690f20ad3d8d48b2d2ce9e38e4"
  forM_ [(0, "0x9858EfFD232B4033E47d90003D41EC34EcaEda94"), (1, "0x78839F6054d7ed13918bAe0473BA31b1Ca9D7265"), (2, "0x07B5FdfEB4E11826D233403Fe8Db0611CCF4c231")] $ \(i, a) ->
    it ("derives the account " <> show i <> " address") $
      (strEncode <$> addrAt i) `shouldReturn` a
  it "derives distinct addresses for accounts 0 to 4" $
    mapM addrAt [0 .. 4] >>= (`shouldSatisfy` \as -> length as == length (nub as))
  it "renders the Ethereum path of an account" $
    B32.renderPath (bip44Path Ethereum $ account 7) `shouldBe` "m/44'/60'/7'/0/0"
  it "rejects an account index at or above 2^31" $ do
    mkAccountIndex 0x7fffffff `shouldSatisfy` isJust
    mkAccountIndex 0x80000000 `shouldBe` Nothing
  where
    seed = B39.entropySeed canonicalEntropy ""
    account = fromJust . mkAccountIndex
    addrAt i = do
      xk <- B32.derivePath g (B32.walletMasterKey canonicalMaster) (bip44Path Ethereum $ account i)
      addressFromPrivateKey g (B32.xkKey xk)

eip55Tests :: Spec
eip55Tests = do
  describe "spec vectors round-trip" $
    forM_ specAddresses $ \a ->
      it (BC.unpack a) $
        strEncode (right $ strDecode @Address a) `shouldBe` a
  it "accepts an all-lowercase address" $
    strDecode @Address "0x5aaeb6053f3e94c9b9a09f33669435e7ef1beaed" `shouldSatisfy` isRight
  it "accepts an all-uppercase address" $
    strDecode @Address "0x5AAEB6053F3E94C9B9A09F33669435E7EF1BEAED" `shouldSatisfy` isRight
  it "accepts an address without the 0x prefix" $
    strDecode @Address "5aaeb6053f3e94c9b9a09f33669435e7ef1beaed" `shouldSatisfy` isRight
  it "rejects a bad EIP-55 checksum" $
    strDecode @Address "0x5aAeb6053f3E94C9b9A09f33669435E7Ef1BeAed" `shouldSatisfy` isLeft
  it "rejects the wrong length" $
    strDecode @Address "0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAe" `shouldSatisfy` isLeft
  it "rejects non-hex characters" $
    strDecode @Address "0xZaAeb6053F3E94C9b9A09f33669435E7Ef1BeAed"
      `shouldBe` Left "Failed reading: address: expected 40 hex digits, got 0"
  it "round-trips every byte value through the checksummed form" $
    forM_ everyByteAddresses $ \a ->
      strDecode (strEncode a) `shouldBe` Right a
  it "round-trips every byte value through the lowercase form" $
    forM_ everyByteAddresses $ \a ->
      strDecode (BC.map toLower (strEncode a)) `shouldBe` Right a
  where
    -- 13 x 20 = 260 bytes, so every value 0x00..0xff appears at least once
    everyByteAddresses =
      [ right . strDecode @Address . ("0x" <>) . toHex . B.pack $
          [fromIntegral ((i * 20 + j) `mod` 256) | j <- [0 .. 19 :: Int]]
        | i <- [0 .. 12 :: Int]
      ]
    specAddresses =
      [ "0x52908400098527886E0F7030069857D2E4169EE7",
        "0x8617E340B3D01FA5F11F306F4090FD50E238070D",
        "0xde709f2102306220921060314715629080e2fb77",
        "0x27b1fdb04752bbc536007a920d24acb045561c26",
        "0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed",
        "0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359",
        "0xdbF03B407c01E7cD3CBea99509d93f8DDDC8C6FB",
        "0xD1220A0cf47c7B9Be7A2E6BA89F429762e7b9aDb"
      ]
