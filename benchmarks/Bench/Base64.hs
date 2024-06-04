{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PackageImports #-}
{-# LANGUAGE TypeApplications #-}

module Bench.Base64 where

import qualified Data.Attoparsec.ByteString.Char8 as A
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Char (isAlphaNum)
import Test.Tasty.Bench
import qualified "base64" Data.Base64.Types as New
import qualified "base64" Data.ByteString.Base64 as New
import qualified "base64" Data.ByteString.Base64.URL as NewUrl
import qualified "base64-bytestring" Data.ByteString.Base64 as Old
import qualified "base64-bytestring" Data.ByteString.Base64.URL as OldUrl

benchBase64 :: [Benchmark]
benchBase64 =
  [ bgroup
      "encode"
      [ bench "e-old" $ nf Old.encode decoded,
        bcompare "e-old" . bench "e-new" $ nf New.encodeBase64' decoded
      ],
    bgroup
      "decode"
      [ bench "d-old" $ nf Old.decode encoded,
        bcompare "d-old" . bench "d-new" $ nf New.decodeBase64Untyped encoded,
        bcompare "d-old" . bench "d-typed" $ nf (New.decodeBase64 . New.assertBase64 @New.StdPadded) encoded
      ],
    bgroup
      "encode url"
      [ bench "eu-old" $ nf OldUrl.encode decoded,
        bcompare "eu-old" . bench "eu-new" $ nf NewUrl.encodeBase64' decoded
      ],
    bgroup
      "decode url"
      [ bench "du-old" $ nf OldUrl.decode encodedUrl,
        bcompare "du-old" . bench "du-new" $ nf NewUrl.decodeBase64Untyped encodedUrl,
        bcompare "du-old" . bench "du-typed" $ nf (NewUrl.decodeBase64 . New.assertBase64 @New.UrlPadded) encodedUrl
      ],
    bgroup
      "parsing"
      [ bench "predicates" $ nf parsePredicates encoded,
        bcompare "predicates" . bench "alphabet" $ nf parseAlphabet encoded
      ]
  ]

parsePredicates :: ByteString -> Either String ByteString
parsePredicates = A.parseOnly $ do
  str <- A.takeWhile1 (\c -> isAlphaNum c || c == '+' || c == '/')
  pad <- A.takeWhile (== '=')
  either fail pure $ Old.decode (str <> pad)

parseAlphabet :: ByteString -> Either String ByteString
parseAlphabet = A.parseOnly $ do
  str <- A.takeWhile1 (`B.elem` base64Alphabet)
  pad <- A.takeWhile (== '=')
  either fail pure $ Old.decode (str <> pad)
  where
    base64Alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

encoded :: ByteString
encoded = "e8JK+8V3fq6kOLqco/SaKlpNaQ7i1gfOrXoqekEl42u4mF8Bgu14T5j0189CGcUhJHw2RwCMvON+qbvQ9ecJAA=="

encodedUrl :: ByteString
encodedUrl = "e8JK-8V3fq6kOLqco_SaKlpNaQ7i1gfOrXoqekEl42u4mF8Bgu14T5j0189CGcUhJHw2RwCMvON-qbvQ9ecJAA=="

decoded :: ByteString
decoded = "{\194J\251\197w~\174\164\&8\186\156\163\244\154*ZMi\SO\226\214\a\206\173z*zA%\227k\184\152_\SOH\130\237xO\152\244\215\207B\EM\197!$|6G\NUL\140\188\227~\169\187\208\245\231\t\NUL"
