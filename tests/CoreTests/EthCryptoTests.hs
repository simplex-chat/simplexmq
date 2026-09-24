{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module CoreTests.EthCryptoTests (ethCryptoTests) where

import Control.Concurrent.STM (atomically)
import Control.Monad (forM_)
import qualified Data.ByteArray as BA
import qualified Data.ByteArray.Encoding as BAE
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC
import Data.Char (toLower)
import Data.Either (isLeft, isRight)
import Data.List (nub)
import Data.Maybe (fromJust)
import qualified Data.Text as T
import Data.Text.Encoding (decodeLatin1)
import qualified Simplex.Messaging.Crypto as C
import qualified Simplex.Messaging.Crypto.BIP32 as B32
import qualified Simplex.Messaging.Crypto.BIP39 as B39
import Simplex.Messaging.Crypto.BIP39.English (englishWordList)
import qualified Simplex.Messaging.Crypto.Secp256k1 as S
import Simplex.Messaging.Encoding.String (strDecode, strEncode)
import Simplex.Messaging.Eth.Address
import Test.Hspec hiding (fit, it)
import Util

ethCryptoTests :: Spec
ethCryptoTests = do
  describe "Keccak-256" keccakTests
  describe "secp256k1" secp256k1Tests
  describe "BIP-39" bip39Tests
  describe "BIP-32" bip32Tests
  describe "BIP-44 derivation" derivationTests
  describe "EIP-55 addresses" eip55Tests

-- helpers

hx :: BA.ByteArray a => ByteString -> a
hx s = either (const $ error $ "bad hex literal: " <> BC.unpack s) id $ BAE.convertFromBase BAE.Base16 s

toHex :: BA.ByteArrayAccess a => a -> ByteString
toHex = BAE.convertToBase BAE.Base16

right :: Either String a -> a
right = either (error . ("unexpected Left: " <>)) id

keccakTests :: Spec
keccakTests = do
  it "hashes the empty string" $
    toHex (C.keccak256 "") `shouldBe` "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470"
  it "hashes abc" $
    toHex (C.keccak256 "abc") `shouldBe` "4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45"

secp256k1Tests :: Spec
secp256k1Tests = do
  it "derives the known address for a known key" $
    (strEncode <$> (addressFromPrivateKey =<< testKey)) `shouldReturn` "0x2c7536E3605D9C16a7a3D7b1898e529396a65c23"
  it "serializes a public key in both SEC1 forms" $ do
    pk <- S.secp256k1PublicKey =<< testKey
    comp <- S.serializePublicKey S.Compressed pk
    uncomp <- S.serializePublicKey S.Uncompressed pk
    B.length comp `shouldBe` 33
    B.length uncomp `shouldBe` 65
    B.head uncomp `shouldBe` 0x04
    -- both forms contain the same x coordinate, and the compressed prefix encodes the parity of y
    B.take 32 (B.drop 1 uncomp) `shouldBe` B.drop 1 comp
    B.head comp `shouldBe` (if odd (B.last uncomp) then 0x03 else 0x02)
  it "rejects a zero private key" $
    (isLeft <$> S.mkPrivateKey (BA.replicate 32 0)) `shouldReturn` True
  it "rejects a private key at the group order" $
    (isLeft <$> S.mkPrivateKey (hx "fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141")) `shouldReturn` True
  it "rejects a short private key" $
    (isLeft <$> S.mkPrivateKey (BA.replicate 31 1)) `shouldReturn` True
  it "adds a tweak to a private key" $ do
    k <- testKey
    (fmap (toHex . S.unPrivateKey) <$> S.privateKeyTweakAdd k (BA.replicate 31 0 <> BA.singleton 1))
      `shouldReturn` Just "4c0883a69102937d6231471b5dbb6204fe5129617082792ae468d01a3f362319"
  where
    testKey = right <$> S.mkPrivateKey (hx "4c0883a69102937d6231471b5dbb6204fe5129617082792ae468d01a3f362318")

bip39Tests :: Spec
bip39Tests = do
  describe "official English vectors" $
    forM_ (zip [0 :: Int ..] bip39Vectors) $ \(i, (entHex, phrase, seedHex)) ->
      it ("vector " <> show i) $ do
        let m = right $ B39.entropyToMnemonic (hx entHex)
            p = right $ B39.parseMnemonic (decodeLatin1 phrase)
        B39.mnemonicPhrase m `shouldBe` phrase
        toHex (B39.mnemonicToEntropy p) `shouldBe` entHex
        toHex (B39.mnemonicToSeed p "TREZOR") `shouldBe` seedHex
  it "embeds the upstream wordlist, unchanged" $
    -- sha256 of bitcoin/bips/bip-0039/english.txt
    C.sha256Hash (BC.unlines englishWordList)
      `shouldBe` hx "2f5eed53a4727b4bf8880d8f3f199efc90e58503646d9ff8eff3a2ed3b24dbda"
  it "maps strengths to word counts" $
    map B39.strengthWordCount [minBound .. maxBound] `shouldBe` [12, 15, 18, 21, 24]
  it "rejects a bad checksum" $
    B39.parseMnemonic "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon"
      `shouldSatisfy` isLeft
  it "rejects a word outside the list" $
    B39.parseMnemonic "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon simplex"
      `shouldSatisfy` isLeft
  it "rejects an empty phrase, counting the words" $
    B39.parseMnemonic "" `shouldBe` Left "Failed reading: mnemonic: expected 12, 15, 18, 21 or 24 words, got 0"
  it "rejects a word with trailing punctuation, naming it" $
    B39.parseMnemonic "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about."
      `shouldBe` Left "Failed reading: mnemonic: not in wordlist: about."
  it "rejects a wrong word count" $
    B39.parseMnemonic "abandon abandon about" `shouldSatisfy` isLeft
  it "accepts a capitalised phrase and normalises it" $
    (B39.mnemonicPhrase <$> B39.parseMnemonic "Abandon ABANDON abandon abandon abandon abandon abandon abandon abandon abandon abandon About")
      `shouldBe` Right canonicalPhrase
  it "accepts extra whitespace" $
    B39.parseMnemonic "  abandon\tabandon  abandon abandon abandon abandon abandon abandon abandon abandon abandon about "
      `shouldBe` B39.parseMnemonic (decodeLatin1 canonicalPhrase)
  it "accepts Unicode whitespace between words" $ do
    let spaced sep = T.intercalate sep . T.words $ decodeLatin1 canonicalPhrase
    B39.parseMnemonic (spaced "\x00A0") `shouldBe` B39.parseMnemonic (decodeLatin1 canonicalPhrase)
    B39.parseMnemonic (spaced "\x3000") `shouldBe` B39.parseMnemonic (decodeLatin1 canonicalPhrase)
  it "rejects an invalid entropy size" $
    B39.entropyToMnemonic (BA.replicate 17 0) `shouldSatisfy` isLeft
  it "generates mnemonics that parse back" $ do
    g <- C.newRandom
    forM_ [minBound .. maxBound] $ \s -> do
      m <- atomically $ B39.randomMnemonic s g
      length (B39.mnemonicWords m) `shouldBe` B39.strengthWordCount s
      B39.parseMnemonic (decodeLatin1 $ B39.mnemonicPhrase m) `shouldBe` Right m

canonicalPhrase :: ByteString
canonicalPhrase = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

bip32Tests :: Spec
bip32Tests = do
  describe "spec test vector 1" $
    forM_ vector1 $ \(name, path, keyHex, ccHex) ->
      it name $ do
        xk <- right <$> (master1 >>= (`B32.derivePath` path))
        toHex (S.unPrivateKey $ B32.xkKey xk) `shouldBe` keyHex
        toHex (B32.xkChainCode xk) `shouldBe` ccHex
  it "spec test vector 2, chain m" $ do
    xk <- master2
    toHex (S.unPrivateKey $ B32.xkKey xk) `shouldBe` "4b03d6fc340455b363f51020ad3ecca4f0850280cf436c70c727923f6db46c3e"
    toHex (B32.xkChainCode xk) `shouldBe` "60499f801b896d83179a4374aeb7822aaeaceaa0db1f85ee3e904c4defbd9689"
  it "rejects a seed shorter than 16 bytes" $
    (isLeft <$> B32.masterKey (BA.replicate 15 1)) `shouldReturn` True
  it "rejects a seed longer than 64 bytes" $
    (isLeft <$> B32.masterKey (BA.replicate 65 1)) `shouldReturn` True
  describe "path rendering" $ do
    it "renders a path" $
      B32.renderPath [B32.hardened 44, B32.hardened 60, B32.hardened 0, 0, 0] `shouldBe` "m/44'/60'/0'/0/0"
    it "renders an Ethereum path for an account and address" $
      B32.renderPath <$> ethereumPath 7 3 `shouldBe` Just "m/44'/60'/7'/0/3"
    it "rejects an Ethereum account or address index at or above 2^31" $ do
      ethereumPath 0x80000000 0 `shouldBe` Nothing
      ethereumPath 0 0x80000000 `shouldBe` Nothing
  where
    master1 = right <$> B32.masterKey (hx "000102030405060708090a0b0c0d0e0f")
    master2 =
      right <$> B32.masterKey (hx "fffcf9f6f3f0edeae7e4e1dedbd8d5d2cfccc9c6c3c0bdbab7b4b1aeaba8a5a29f9c999693908d8a8784817e7b7875726f6c696663605d5a5754514e4b484542")
    vector1 =
      [ ( "chain m",
          [],
          "e8f32e723decf4051aefac8e2c93c9c5b214313817cdb01a1494b917c8436b35",
          "873dff81c02f525623fd1fe5167eac3a55a049de3d314bb42ee227ffed37d508"
        ),
        ( "chain m/0'",
          [B32.hardened 0],
          "edb2e14f9ee77d26dd93b4ecede8d16ed408ce149b6cd80b0715a2d911a0afea",
          "47fdacbd0f1097043b78c63c20c34ef4ed9a111d980047ad16282c7ae6236141"
        ),
        ( "chain m/0'/1",
          [B32.hardened 0, 1],
          "3c6cb8d0f6a264c91ea8b5030fadaa8e538b020f0a387421a12de9319dc93368",
          "2a7857631386ba23dacac34180dd1983734e444fdbf774041578e9b6adb37c19"
        ),
        ( "chain m/0'/1/2'",
          [B32.hardened 0, 1, B32.hardened 2],
          "cbce0d719ecf7431d88e6a89fa1483e02e35092af60c042b1df2ff59fa424dca",
          "04466b9cc8e161e966409ca52986c584f07e9dc81f735db683c3ff6ec7b1503f"
        ),
        ( "chain m/0'/1/2'/2",
          [B32.hardened 0, 1, B32.hardened 2, 2],
          "0f479245fb19a38a1954c5c7c0ebab2f9bdfd96a17563ef28a6a4b1a2a764ef4",
          "cfb71883f01676f587d023cc53a35bc7f88f724b1f8c2892ac1275ac822a3edd"
        ),
        ( "chain m/0'/1/2'/2/1000000000",
          [B32.hardened 0, 1, B32.hardened 2, 2, 1000000000],
          "471b76e389e528d6de6d816857e012c5455051cad6660850e58372a6c3e6e7c8",
          "c783e67b921d2beb8f6b389cc646d7263b4145701dadd2161548a8b078e65e9e"
        )
      ]

derivationTests :: Spec
derivationTests = do
  it "derives the standard BIP-39 seed" $
    toHex seed
      `shouldBe` "5eb00bbddcf069084889a8ab9155568165f5c453ccb85e70811aaed6f6da5fc19a5ac40b389cd370d086206dec8aa6c43daea6690f20ad3d8d48b2d2ce9e38e4"
  forM_ [(0, "0x9858EfFD232B4033E47d90003D41EC34EcaEda94"), (1, "0x78839F6054d7ed13918bAe0473BA31b1Ca9D7265"), (2, "0x07B5FdfEB4E11826D233403Fe8Db0611CCF4c231")] $ \(i, a) ->
    it ("derives the well-known account " <> show i <> " address") $
      (strEncode <$> addrAt i) `shouldReturn` a
  it "derives distinct addresses for accounts 0 to 4" $
    mapM addrAt [0 .. 4] >>= (`shouldSatisfy` \as -> length as == length (nub as))
  where
    m = right $ B39.parseMnemonic (decodeLatin1 canonicalPhrase)
    seed = B39.mnemonicToSeed m ""
    addrAt i = do
      master <- right <$> B32.masterKey seed
      xk <- right <$> B32.derivePath master (fromJust $ ethereumPath i 0)
      addressFromPrivateKey (B32.xkKey xk)

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
      [ "0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed",
        "0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359",
        "0xdbF03B407c01E7cD3CBea99509d93f8DDDC8C6FB",
        "0xD1220A0cf47c7B9Be7A2E6BA89F429762e7b9aDb"
      ]

bip39Vectors :: [(ByteString, ByteString, ByteString)]
bip39Vectors =
  [ ( "00000000000000000000000000000000",
      "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about",
      "c55257c360c07c72029aebc1b53c05ed0362ada38ead3e3e9efa3708e53495531f09a6987599d18264c1e1c92f2cf141630c7a3c4ab7c81b2f001698e7463b04"
    ),
    ( "7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f",
      "legal winner thank year wave sausage worth useful legal winner thank yellow",
      "2e8905819b8723fe2c1d161860e5ee1830318dbf49a83bd451cfb8440c28bd6fa457fe1296106559a3c80937a1c1069be3a3a5bd381ee6260e8d9739fce1f607"
    ),
    ( "80808080808080808080808080808080",
      "letter advice cage absurd amount doctor acoustic avoid letter advice cage above",
      "d71de856f81a8acc65e6fc851a38d4d7ec216fd0796d0a6827a3ad6ed5511a30fa280f12eb2e47ed2ac03b5c462a0358d18d69fe4f985ec81778c1b370b652a8"
    ),
    ( "ffffffffffffffffffffffffffffffff",
      "zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo wrong",
      "ac27495480225222079d7be181583751e86f571027b0497b5b5d11218e0a8a13332572917f0f8e5a589620c6f15b11c61dee327651a14c34e18231052e48c069"
    ),
    ( "000000000000000000000000000000000000000000000000",
      "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon agent",
      "035895f2f481b1b0f01fcf8c289c794660b289981a78f8106447707fdd9666ca06da5a9a565181599b79f53b844d8a71dd9f439c52a3d7b3e8a79c906ac845fa"
    ),
    ( "7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f",
      "legal winner thank year wave sausage worth useful legal winner thank year wave sausage worth useful legal will",
      "f2b94508732bcbacbcc020faefecfc89feafa6649a5491b8c952cede496c214a0c7b3c392d168748f2d4a612bada0753b52a1c7ac53c1e93abd5c6320b9e95dd"
    ),
    ( "808080808080808080808080808080808080808080808080",
      "letter advice cage absurd amount doctor acoustic avoid letter advice cage absurd amount doctor acoustic avoid letter always",
      "107d7c02a5aa6f38c58083ff74f04c607c2d2c0ecc55501dadd72d025b751bc27fe913ffb796f841c49b1d33b610cf0e91d3aa239027f5e99fe4ce9e5088cd65"
    ),
    ( "ffffffffffffffffffffffffffffffffffffffffffffffff",
      "zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo when",
      "0cd6e5d827bb62eb8fc1e262254223817fd068a74b5b449cc2f667c3f1f985a76379b43348d952e2265b4cd129090758b3e3c2c49103b5051aac2eaeb890a528"
    ),
    ( "0000000000000000000000000000000000000000000000000000000000000000",
      "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon art",
      "bda85446c68413707090a52022edd26a1c9462295029f2e60cd7c4f2bbd3097170af7a4d73245cafa9c3cca8d561a7c3de6f5d4a10be8ed2a5e608d68f92fcc8"
    ),
    ( "7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f",
      "legal winner thank year wave sausage worth useful legal winner thank year wave sausage worth useful legal winner thank year wave sausage worth title",
      "bc09fca1804f7e69da93c2f2028eb238c227f2e9dda30cd63699232578480a4021b146ad717fbb7e451ce9eb835f43620bf5c514db0f8add49f5d121449d3e87"
    ),
    ( "8080808080808080808080808080808080808080808080808080808080808080",
      "letter advice cage absurd amount doctor acoustic avoid letter advice cage absurd amount doctor acoustic avoid letter advice cage absurd amount doctor acoustic bless",
      "c0c519bd0e91a2ed54357d9d1ebef6f5af218a153624cf4f2da911a0ed8f7a09e2ef61af0aca007096df430022f7a2b6fb91661a9589097069720d015e4e982f"
    ),
    ( "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
      "zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo vote",
      "dd48c104698c30cfe2b6142103248622fb7bb0ff692eebb00089b32d22484e1613912f0a5b694407be899ffd31ed3992c456cdf60f5d4564b8ba3f05a69890ad"
    ),
    ( "9e885d952ad362caeb4efe34a8e91bd2",
      "ozone drill grab fiber curtain grace pudding thank cruise elder eight picnic",
      "274ddc525802f7c828d8ef7ddbcdc5304e87ac3535913611fbbfa986d0c9e5476c91689f9c8a54fd55bd38606aa6a8595ad213d4c9c9f9aca3fb217069a41028"
    ),
    ( "6610b25967cdcca9d59875f5cb50b0ea75433311869e930b",
      "gravity machine north sort system female filter attitude volume fold club stay feature office ecology stable narrow fog",
      "628c3827a8823298ee685db84f55caa34b5cc195a778e52d45f59bcf75aba68e4d7590e101dc414bc1bbd5737666fbbef35d1f1903953b66624f910feef245ac"
    ),
    ( "68a79eaca2324873eacc50cb9c6eca8cc68ea5d936f98787c60c7ebc74e6ce7c",
      "hamster diagram private dutch cause delay private meat slide toddler razor book happy fancy gospel tennis maple dilemma loan word shrug inflict delay length",
      "64c87cde7e12ecf6704ab95bb1408bef047c22db4cc7491c4271d170a1b213d20b385bc1588d9c7b38f1b39d415665b8a9030c9ec653d75e65f847d8fc1fc440"
    ),
    ( "c0ba5a8e914111210f2bd131f3d5e08d",
      "scheme spot photo card baby mountain device kick cradle pact join borrow",
      "ea725895aaae8d4c1cf682c1bfd2d358d52ed9f0f0591131b559e2724bb234fca05aa9c02c57407e04ee9dc3b454aa63fbff483a8b11de949624b9f1831a9612"
    ),
    ( "6d9be1ee6ebd27a258115aad99b7317b9c8d28b6d76431c3",
      "horn tenant knee talent sponsor spell gate clip pulse soap slush warm silver nephew swap uncle crack brave",
      "fd579828af3da1d32544ce4db5c73d53fc8acc4ddb1e3b251a31179cdb71e853c56d2fcb11aed39898ce6c34b10b5382772db8796e52837b54468aeb312cfc3d"
    ),
    ( "9f6a2878b2520799a44ef18bc7df394e7061a224d2c33cd015b157d746869863",
      "panda eyebrow bullet gorilla call smoke muffin taste mesh discover soft ostrich alcohol speed nation flash devote level hobby quick inner drive ghost inside",
      "72be8e052fc4919d2adf28d5306b5474b0069df35b02303de8c1729c9538dbb6fc2d731d5f832193cd9fb6aeecbc469594a70e3dd50811b5067f3b88b28c3e8d"
    ),
    ( "23db8160a31d3e0dca3688ed941adbf3",
      "cat swing flag economy stadium alone churn speed unique patch report train",
      "deb5f45449e615feff5640f2e49f933ff51895de3b4381832b3139941c57b59205a42480c52175b6efcffaa58a2503887c1e8b363a707256bdd2b587b46541f5"
    ),
    ( "8197a4a47f0425faeaa69deebc05ca29c0a5b5cc76ceacc0",
      "light rule cinnamon wrap drastic word pride squirrel upgrade then income fatal apart sustain crack supply proud access",
      "4cbdff1ca2db800fd61cae72a57475fdc6bab03e441fd63f96dabd1f183ef5b782925f00105f318309a7e9c3ea6967c7801e46c8a58082674c860a37b93eda02"
    ),
    ( "066dca1a2bb7e8a1db2832148ce9933eea0f3ac9548d793112d9a95c9407efad",
      "all hour make first leader extend hole alien behind guard gospel lava path output census museum junior mass reopen famous sing advance salt reform",
      "26e975ec644423f4a4c4f4215ef09b4bd7ef924e85d1d17c4cf3f136c2863cf6df0a475045652c57eb5fb41513ca2a2d67722b77e954b4b3fc11f7590449191d"
    ),
    ( "f30f8c1da665478f49b001d94c5fc452",
      "vessel ladder alter error federal sibling chat ability sun glass valve picture",
      "2aaa9242daafcee6aa9d7269f17d4efe271e1b9a529178d7dc139cd18747090bf9d60295d0ce74309a78852a9caadf0af48aae1c6253839624076224374bc63f"
    ),
    ( "c10ec20dc3cd9f652c7fac2f1230f7a3c828389a14392f05",
      "scissors invite lock maple supreme raw rapid void congress muscle digital elegant little brisk hair mango congress clump",
      "7b4a10be9d98e6cba265566db7f136718e1398c71cb581e1b2f464cac1ceedf4f3e274dc270003c670ad8d02c4558b2f8e39edea2775c9e232c7cb798b069e88"
    ),
    ( "f585c11aec520db57dd353c69554b21a89b20fb0650966fa0a9d6f74fd989d8f",
      "void come effort suffer camp survey warrior heavy shoot primary clutch crush open amazing screen patrol group space point ten exist slush involve unfold",
      "01f5bced59dec48e362f2c45b5de68b9fd6c92c6634f44d6d40aab69056506f0e35524a518034ddc1192e1dacd32c1ed3eaa3c3b131c88ed8e7e54c49a5d0998"
    )
  ]
