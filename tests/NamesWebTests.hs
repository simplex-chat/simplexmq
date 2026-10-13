{-# LANGUAGE OverloadedStrings #-}

-- | Tests for the names-web TypeScript code: each test runs it via node and compares its output with the Haskell functions it must match.
--
-- Prerequisites: cd names-web && npm install && npm run build
module NamesWebTests (namesWebTests) where

import Control.Concurrent.STM (TVar, atomically)
import Control.Monad (forM_, replicateM, replicateM_)
import Crypto.Random (ChaChaDRG)
import qualified Data.ByteArray as BA
import qualified Data.ByteArray.Encoding as BAE
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC
import Data.Char (toLower)
import Data.List (intercalate)
import Data.Word (Word64)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Crypto.BIP32 (masterKey, xkKey)
import Simplex.Messaging.Crypto.BIP39 (EntropyStrength (..), WalletEntropy, entropySeed, randomEntropy, unEntropy)
import Simplex.Messaging.Crypto.BIP44 (CoinType (..), bip44Path, mkAccountIndex)
import qualified Simplex.Messaging.Crypto.Secp256k1 as S
import Simplex.Messaging.Encoding.String (strDecode)
import Simplex.Messaging.Eth.Address (Address, deriveAddress, unAddress)
import Simplex.Messaging.Eth.EIP712
import System.Directory (doesDirectoryExist)
import System.Random (randomIO)
import System.Process (CreateProcess (..), proc, readCreateProcess)
import Test.Hspec hiding (fit, it)
import Util

namesWebDir :: FilePath
namesWebDir = "names-web"

namesWebTests :: Spec
namesWebTests = do
  distExists <- runIO $ doesDirectoryExist (namesWebDir <> "/dist")
  if distExists
    then do
      g <- runIO C.newRandom
      it "derives the wallet address from the entropy as Haskell does" $ testWalletAddress g
      it "signs a digest as Haskell does" $ testSignature g
      it "hashes the RegisterName intent as Haskell does" testIntentDigest
      it "formats and parses the simplex-chat name codes" testNameCodes
      it "encodes the simplex-chat registration vectors" testChatVectors
    else
      it "skipped (run 'cd names-web && npm install && npm run build' first)" $
        pendingWith "TS project not compiled"

testWalletAddress :: TVar ChaChaDRG -> IO ()
testWalletAddress g =
  replicateM_ 5 $ do
    entropy <- atomically $ randomEntropy ES128 g
    (_, addr) <- wallet g entropy
    callNode ("walletFromEntropy(" <> jsUint8 (BA.convert $ unEntropy entropy) <> ").address") `shouldReturn` hex (unAddress addr)

testSignature :: TVar ChaChaDRG -> IO ()
testSignature g =
  replicateM_ 5 $ do
    entropy <- atomically $ randomEntropy ES128 g
    (key, _) <- wallet g entropy
    digest <- atomically $ C.randomBytes 32 g
    signature <- either error id <$> S.signRecoverable g key digest
    callNode ("signDigest(walletFromEntropy(" <> jsUint8 (BA.convert $ unEntropy entropy) <> ").privateKey, " <> jsUint8 digest <> ")")
      `shouldReturn` hex (serializeSignature signature)

testIntentDigest :: IO ()
testIntentDigest =
  replicateM_ 5 $ do
    [owner, resolver, sponsor] <- replicateM 3 $ B.pack <$> replicateM 20 randomIO
    chainId <- randomIO :: IO Word64
    nonce <- randomIO :: IO Word64
    deadline <- randomIO :: IO Word64
    let domain = Eip712Domain {edName = "SimplexSponsor", edVersion = "1", edChainId = chainId, edVerifyingContract = address sponsor}
        registration =
          "{label: 'bakery1', tld: 'simplex', owner: " <> jsUint8 owner <> ", duration: 0n, secret: new Uint8Array(32), resolver: "
            <> jsUint8 resolver <> ", contactLinks: [], channelLinks: []}"
    callNode ("registerIntentDigest(" <> show chainId <> "n, " <> jsUint8 sponsor <> ", " <> registration <> ", " <> show nonce <> "n, " <> show deadline <> "n)")
      `shouldReturn` hex
        ( hashTypedData
            domain
            "RegisterName(string label,address owner,address resolver,bytes[] data,uint256 nonce,uint256 deadline)"
            [VBytes "bakery1", VAddress $ address owner, VAddress $ address resolver, VArray [], VUint $ fromIntegral nonce, VUint $ fromIntegral deadline]
        )

testNameCodes :: IO ()
testNameCodes =
  forM_
    [ ("00000000000000000000000000000000", "SN-00000-00000-00000-00000-00000-0VME2"),
      ("ffffffffffffffffffffffffffffffff", "SN-ZZZZZ-ZZZZZ-ZZZZZ-ZZZZZ-ZZZZZ-XDCD9"),
      ("9e885d952ad362caeb4efe34a8e91bd2", "SN-KT45V-59ATD-HCNTT-EZRTA-HT8VT-8A0BT")
    ]
    $ \(entropy, code) -> do
      callNode ("formatNameCode(" <> jsHex entropy <> ")") `shouldReturn` BC.pack code
      callNode ("parseNameCode('" <> map toLower code <> "')") `shouldReturn` BC.pack entropy

testChatVectors :: IO ()
testChatVectors = do
  callNode ("makeCommitment(" <> knownRegistration <> ")") `shouldReturn` "43aeb4617085160f4dc7ad495d1119f39bca441276b1990123fd3ecb8a40a360"
  callNode ("signDigest(walletFromEntropy(new Uint8Array(16)).privateKey, registerIntentDigest(31337n, " <> jsHex "9a676e781a523b5d0c0e43731313a708cb607508" <> ", " <> knownRegistration <> ", 0n, 4102444800n))")
    `shouldReturn` "74af637cf246cd336c3713f95fd9ed19862971598fcab5f4fb5d044ed033a3854c2ce30ffd36c25ed5f9a8ef691d004b3662f3553113403416f658d9c604732b1b"
  where
    knownRegistration =
      "{label: 'bakery1', tld: 'simplex', owner: walletFromEntropy(new Uint8Array(16)).address, duration: 63072000n, secret: new Uint8Array(32).fill(0x11), resolver: "
        <> jsHex "2279b7a0a67db372996a5fab50d91eaa73d2ebe6"
        <> ", contactLinks: ['https://smp.simplex.im/a#contact'], channelLinks: ['https://smp1.simplex.im/c#one', 'https://smp2.simplex.im/c#two']}"

wallet :: TVar ChaChaDRG -> WalletEntropy -> IO (S.Secp256k1PrivateKey, Address)
wallet g entropy = first xkKey . either error id <$> deriveAddress g master (bip44Path Ethereum $ either error id $ mkAccountIndex 0)
  where
    master = either error id $ masterKey $ entropySeed entropy ""

callNode :: String -> IO ByteString
callNode expr =
  BC.pack
    <$> readCreateProcess
      (proc "node" ["--input-type=module", "-e", imports <> "const v = " <> expr <> "; process.stdout.write(typeof v === 'string' ? v : Buffer.from(v).toString('hex'));"]) {cwd = Just namesWebDir}
      ""
  where
    imports =
      "import {formatNameCode, parseNameCode} from './dist/code.js';"
        <> "import {makeCommitment, registerIntentDigest} from './dist/registration.js';"
        <> "import {signDigest, walletFromEntropy} from './dist/wallet.js';"

jsUint8 :: ByteString -> String
jsUint8 bs = "new Uint8Array([" <> intercalate "," (map show $ B.unpack bs) <> "])"

jsHex :: String -> String
jsHex = jsUint8 . either error id . BAE.convertFromBase BAE.Base16 . BC.pack

address :: ByteString -> Address
address = either error id . strDecode . hex

hex :: ByteString -> ByteString
hex = BAE.convertToBase BAE.Base16
