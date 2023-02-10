{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NamedFieldPuns #-}
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

fileDesc :: FileDescription
fileDesc =
  FileDescription
    { name = "file.ext",
      size = 33200000,
      digest = FileDigest "abc",
      encKey = C.Key "def",
      iv = C.IV "ghi",
      chunks =
        [ FileChunk
            { chunkNo = 1,
              digest = chunkDigest,
              chunkSize = 8 * 1024 * 1024,
              replicas =
                [ FileChunkReplica {server = "xftp://abc=@example1.com", rcvId, rcvKey},
                  FileChunkReplica {server = "xftp://abc=@example3.com", rcvId, rcvKey}
                ]
            },
          FileChunk
            { chunkNo = 2,
              digest = chunkDigest,
              chunkSize = 8 * 1024 * 1024,
              replicas =
                [ FileChunkReplica {server = "xftp://abc=@example2.com", rcvId, rcvKey},
                  FileChunkReplica {server = "xftp://abc=@example4.com", rcvId, rcvKey}
                ]
            },
          FileChunk
            { chunkNo = 3,
              digest = chunkDigest,
              chunkSize = 8 * 1024 * 1024,
              replicas =
                [ FileChunkReplica {server = "xftp://abc=@example1.com", rcvId, rcvKey},
                  FileChunkReplica {server = "xftp://abc=@example4.com", rcvId, rcvKey}
                ]
            },
          FileChunk
            { chunkNo = 4,
              digest = chunkDigest,
              chunkSize = 2 * 1024 * 1024,
              replicas =
                [ FileChunkReplica {server = "xftp://abc=@example2.com", rcvId, rcvKey},
                  FileChunkReplica {server = "xftp://abc=@example3.com", rcvId, rcvKey}
                ]
            }
        ]
    }
  where
    rcvId = FileChunkRcvId "abc"
    -- rcvKey :: C.PrivateKey 'C.Ed25519
    -- rcvKey = "def"
    rcvKey = C.Key "def"
    chunkDigest = FileDigest "ghi"

yamlFileDesc :: YAMLFileDescription
yamlFileDesc =
  YAMLFileDescription
    { name = "file.ext",
      size = 33200000,
      chunkSize = "8mb",
      digest = FileDigest "abc",
      encKey = C.Key "def",
      iv = C.IV "ghi",
      parts =
        [ YAMLFilePart
            { server = "xftp://abc=@example1.com",
              chunks = ["1:YWJj:ZGVm:Z2hp", "3:YWJj:ZGVm:Z2hp"]
            },
          YAMLFilePart
            { server = "xftp://abc=@example2.com",
              chunks = ["2:YWJj:ZGVm:Z2hp", "4:YWJj:ZGVm:Z2hp:2mb"]
            },
          YAMLFilePart
            { server = "xftp://abc=@example3.com",
              chunks = ["1:YWJj:ZGVm", "4:YWJj:ZGVm"]
            },
          YAMLFilePart
            { server = "xftp://abc=@example4.com",
              chunks = ["2:YWJj:ZGVm", "3:YWJj:ZGVm"]
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
  yfd <- Y.decodeFileThrow fileDescPath
  yfd `shouldBe` yamlFileDesc

testSerializeFileDescription :: IO ()
testSerializeFileDescription = do
  Y.encodeFile tmpFileDescPath yamlFileDesc
  fdSer <- B.readFile tmpFileDescPath
  fdExp <- B.readFile fileDescPath
  fdSer `shouldBe` fdExp

testProcessFileDescription :: IO ()
testProcessFileDescription = do
  -- fdStr <- B.readFile fileDescPath
  -- fd <- processFileDescription fdStr
  -- fd `shouldBe` fileDesc
  pure ()
