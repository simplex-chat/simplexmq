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
      digest = FileDigest "i\183",
      encKey = C.Key "i\183",
      iv = C.IV "i\183",
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
    rcvId = FileChunkRcvId "i\183"
    -- rcvKey :: C.PrivateKey 'C.Ed25519
    -- rcvKey = "i\183"
    rcvKey = C.Key "i\183"
    chunkDigest = FileDigest "i\183"

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
              chunks =
                [ YAMLFilePartChunk {c = 1, r, k, d = Just d, s = Nothing},
                  YAMLFilePartChunk {c = 3, r, k, d = Just d, s = Nothing}
                ]
            },
          YAMLFilePart
            { server = "xftp://abc=@example2.com",
              chunks =
                [ YAMLFilePartChunk {c = 2, r, k, d = Just d, s = Nothing},
                  YAMLFilePartChunk {c = 4, r, k, d = Just d, s = Just "2mb"}
                ]
            },
          YAMLFilePart
            { server = "xftp://abc=@example3.com",
              chunks =
                [ YAMLFilePartChunk {c = 1, r, k, d = Nothing, s = Nothing},
                  YAMLFilePartChunk {c = 4, r, k, d = Nothing, s = Nothing}
                ]
            },
          YAMLFilePart
            { server = "xftp://abc=@example4.com",
              chunks =
                [ YAMLFilePartChunk {c = 2, r, k, d = Nothing, s = Nothing},
                  YAMLFilePartChunk {c = 3, r, k, d = Nothing, s = Nothing}
                ]
            }
        ]
    }
  where
    r = FileChunkRcvId "i\183"
    -- rk :: C.PrivateKey 'C.Ed25519
    -- rk = "i\183"
    k = C.Key "i\183"
    d = FileDigest "i\183"

fileDescriptionTests :: Spec
fileDescriptionTests =
  describe "file description parsing / serializing" $ do
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
  fdStr <- B.readFile fileDescPath
  fd <- processFileDescription fdStr
  fd `shouldBe` fileDesc
