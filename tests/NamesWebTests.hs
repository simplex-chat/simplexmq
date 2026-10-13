{-# LANGUAGE OverloadedStrings #-}

-- | Tests for the names-web TypeScript code: each test runs it via node and compares its output with the Haskell functions it must match.
--
-- Prerequisites: cd names-web && npm install && npm run build
module NamesWebTests (namesWebTests) where

import Control.Concurrent.STM (TVar, atomically)
import Control.Monad (forM_, replicateM_)
import Crypto.Random (ChaChaDRG)
import qualified Data.ByteArray as BA
import qualified Data.ByteArray.Encoding as BAE
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC
import Data.Char (toLower)
import Data.List (intercalate)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Crypto.BIP32 (masterKey, xkKey)
import Simplex.Messaging.Crypto.BIP39 (EntropyStrength (..), entropySeed, randomEntropy, unEntropy)
import Simplex.Messaging.Crypto.BIP44 (CoinType (..), bip44Path, mkAccountIndex)
import qualified Simplex.Messaging.Crypto.Secp256k1 as S
import Simplex.Messaging.Eth.Address (deriveAddress, unAddress)
import Simplex.Messaging.Eth.EIP712
import System.Directory (doesDirectoryExist)
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
      it "derives the wallet and signs a digest as Haskell does" $ testWallet g
      it "formats and parses the simplex-chat name codes" testNameCodes
      it "encodes the simplex-chat registration vectors" testChatVectors
    else
      it "skipped (run 'cd names-web && npm install && npm run build' first)" $
        pendingWith "TS project not compiled"

testWallet :: TVar ChaChaDRG -> IO ()
testWallet g =
  replicateM_ 5 $ do
    entropy <- atomically $ randomEntropy ES128 g
    let master = either error id $ masterKey $ entropySeed entropy ""
    (xk, addr) <- either error id <$> deriveAddress g master (bip44Path Ethereum $ either error id $ mkAccountIndex 0)
    digest <- atomically $ C.randomBytes 32 g
    signature <- either error id <$> S.signRecoverable g (xkKey xk) digest
    let jsWallet = "walletFromEntropy(" <> jsUint8 (BA.convert $ unEntropy entropy) <> ")"
    callNode (jsWallet <> ".address") `shouldReturn` hex (unAddress addr)
    callNode ("signDigest(" <> jsWallet <> ".privateKey, " <> jsUint8 digest <> ")") `shouldReturn` hex (serializeSignature signature)

testNameCodes :: IO ()
testNameCodes = do
  forM_
    [ ("00000000000000000000000000000000", "SN-00000-00000-00000-00000-00000-0VME2"),
      ("ffffffffffffffffffffffffffffffff", "SN-ZZZZZ-ZZZZZ-ZZZZZ-ZZZZZ-ZZZZZ-XDCD9"),
      ("9e885d952ad362caeb4efe34a8e91bd2", "SN-KT45V-59ATD-HCNTT-EZRTA-HT8VT-8A0BT")
    ]
    $ \(entropy, code) -> do
      callNode ("formatNameCode(" <> jsHex entropy <> ")") `shouldReturn` BC.pack code
      callNode ("parseNameCode('" <> map toLower code <> "')") `shouldReturn` BC.pack entropy
  callNode "parseNameCode('SN-OOOOO-OOOOO-OOOOO-OOOOO-OOOOO-OVME2')" `shouldReturn` "00000000000000000000000000000000"
  callNode "String(parseNameCode('SN-KT45V-59ATD-HCNTT-EZRTA-HT8VT-8A0BV'))" `shouldReturn` "null"

testChatVectors :: IO ()
testChatVectors = do
  callNode ("makeCommitment(" <> knownRegistration <> ")") `shouldReturn` "43aeb4617085160f4dc7ad495d1119f39bca441276b1990123fd3ecb8a40a360"
  callNode (knownSignature knownRegistration)
    `shouldReturn` "74af637cf246cd336c3713f95fd9ed19862971598fcab5f4fb5d044ed033a3854c2ce30ffd36c25ed5f9a8ef691d004b3662f3553113403416f658d9c604732b1b"
  callNode (knownSignature $ "{..." <> knownRegistration <> ", contactLinks: [], channelLinks: []}")
    `shouldReturn` "caac218bca1ac887c6438f41f9f55f4ad026b61f16951b420785cc8d98b990f2306eaa67f18adb7b537225fff38dcd6012e53492e2d07745b565d9b09bd0d9221b"
  where
    knownSignature r = "signDigest(walletFromEntropy(new Uint8Array(16)).privateKey, registerIntentDigest(31337n, " <> jsHex "9a676e781a523b5d0c0e43731313a708cb607508" <> ", " <> r <> ", 0n, 4102444800n))"
    knownRegistration =
      "{label: 'bakery1', tld: 'simplex', owner: "
        <> jsHex "9858effd232b4033e47d90003d41ec34ecaeda94"
        <> ", duration: 63072000n, secret: new Uint8Array(32).fill(0x11), resolver: "
        <> jsHex "2279b7a0a67db372996a5fab50d91eaa73d2ebe6"
        <> ", contactLinks: ['https://smp.simplex.im/a#contact'], channelLinks: ['https://smp1.simplex.im/c#one', 'https://smp2.simplex.im/c#two']}"

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

hex :: ByteString -> ByteString
hex = BAE.convertToBase BAE.Base16
