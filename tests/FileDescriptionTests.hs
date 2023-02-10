{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module FileDescriptionTests where

import qualified Data.ByteString.Char8 as B
import qualified Data.Yaml as Y
import Simplex.FileTransfer.Description
import qualified Simplex.Messaging.Crypto as C
import Test.Hspec

fileDescPath :: FilePath
fileDescPath = "tests/fixtures/file_description.yaml"

tmpFileDescPath :: FilePath
tmpFileDescPath = "tests/tmp/file_description.yaml"

yamlFileDesc :: YAMLFileDescription
yamlFileDesc =
  YAMLFileDescription
    { name = "file.ext",
      size = 33200000,
      chunkSize = "8mb",
      digest = FileDigest "i\183",
      encKey = C.Key "i\183",
      iv = C.IV "i\183",
      parts =
        [ YAMLFilePart
            { server = "xftp://abc=@example1.com",
              chunks = ["1:abc=:def=:ghi=", "3:abc=:def=:ghi="]
            },
          YAMLFilePart
            { server = "xftp://abc=@example2.com",
              chunks = ["2:abc=:def=:ghi=", "4:abc=:def=:ghi=:2mb"]
            },
          YAMLFilePart
            { server = "xftp://abc=@example3.com",
              chunks = ["1:abc=:def=", "4:abc=:def="]
            },
          YAMLFilePart
            { server = "xftp://abc=@example4.com",
              chunks = ["2:abc=:def=", "3:abc=:def="]
            }
        ]
    }

fileDescriptionTests :: Spec
fileDescriptionTests =
  fdescribe "file description parsing / serializing" $ do
    it "parse file description" testParseFileDescription
    it "serialize file description" testSerializeFileDescription
    it "process file description" testProcessFileDescription

testParseFileDescription :: IO ()
testParseFileDescription = do
  fd <- Y.decodeFileThrow fileDescPath
  fd `shouldBe` yamlFileDesc

testSerializeFileDescription :: IO ()
testSerializeFileDescription = do
  Y.encodeFile tmpFileDescPath yamlFileDesc
  fdSerialized <- B.readFile tmpFileDescPath
  fdExpected <- B.readFile fileDescPath
  fdSerialized `shouldBe` fdExpected

testProcessFileDescription :: IO ()
testProcessFileDescription = do
  pure ()
