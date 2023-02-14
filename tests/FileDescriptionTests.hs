{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module FileDescriptionTests where

import Control.Exception (bracket_)
import qualified Data.ByteString.Char8 as B
import qualified Data.Yaml as Y
import Simplex.FileTransfer.Description
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding.String (StrEncoding (..))
import System.Directory (removeFile)
import Test.Hspec

fileDescriptionTests :: Spec
fileDescriptionTests =
  fdescribe "file description parsing / serializing" $ do
    it "parse YAML file description" testParseYAMLFileDescription
    it "serialize YAML file description" testSerializeYAMLFileDescription
    it "parse file description" testParseFileDescription
    it "serialize file description" testSerializeFileDescription

fileDescPath :: FilePath
fileDescPath = "tests/fixtures/file_description.yaml"

tmpFileDescPath :: FilePath
tmpFileDescPath = "tests/tmp/file_description.yaml"

mb :: Num a => a
mb = 1024 * 1024

fileDesc :: FileDescription
fileDesc =
  FileDescription
    { size = FileSize $ 26 * mb,
      digest = FileDigest "abc",
      key = C.Key "def",
      iv = C.IV "ghi",
      chunkSize = defaultChunkSize,
      chunks =
        [ FileChunk
            { chunkNo = 1,
              digest = chunkDigest,
              chunkSize = defaultChunkSize,
              replicas =
                [ FileChunkReplica {server = "xftp://abc=@example1.com", rcvId, rcvKey},
                  FileChunkReplica {server = "xftp://abc=@example3.com", rcvId, rcvKey}
                ]
            },
          FileChunk
            { chunkNo = 2,
              digest = chunkDigest,
              chunkSize = defaultChunkSize,
              replicas =
                [ FileChunkReplica {server = "xftp://abc=@example2.com", rcvId, rcvKey},
                  FileChunkReplica {server = "xftp://abc=@example4.com", rcvId, rcvKey}
                ]
            },
          FileChunk
            { chunkNo = 3,
              digest = chunkDigest,
              chunkSize = defaultChunkSize,
              replicas =
                [ FileChunkReplica {server = "xftp://abc=@example1.com", rcvId, rcvKey},
                  FileChunkReplica {server = "xftp://abc=@example4.com", rcvId, rcvKey}
                ]
            },
          FileChunk
            { chunkNo = 4,
              digest = chunkDigest,
              chunkSize = FileSize $ 2 * mb,
              replicas =
                [ FileChunkReplica {server = "xftp://abc=@example2.com", rcvId, rcvKey},
                  FileChunkReplica {server = "xftp://abc=@example3.com", rcvId, rcvKey}
                ]
            }
        ]
    }
  where
    defaultChunkSize = FileSize $ 8 * mb
    rcvId = ChunkReplicaId "abc"
    rcvKey = C.APrivateSignKey C.SEd25519 "MC4CAQAwBQYDK2VwBCIEIDfEfevydXXfKajz3sRkcQ7RPvfWUPoq6pu1TYHV1DEe"
    chunkDigest = FileDigest "ghi"

yamlFileDesc :: YAMLFileDescription
yamlFileDesc =
  YAMLFileDescription
    { size = "26mb",
      chunkSize = "8mb",
      digest = FileDigest "abc",
      key = C.Key "def",
      iv = C.IV "ghi",
      replicas =
        [ YAMLServerReplicas
            { server = "xftp://abc=@example1.com",
              chunks =
                [ "1:YWJj:MC4CAQAwBQYDK2VwBCIEIDfEfevydXXfKajz3sRkcQ7RPvfWUPoq6pu1TYHV1DEe:Z2hp",
                  "3:YWJj:MC4CAQAwBQYDK2VwBCIEIDfEfevydXXfKajz3sRkcQ7RPvfWUPoq6pu1TYHV1DEe:Z2hp"
                ]
            },
          YAMLServerReplicas
            { server = "xftp://abc=@example2.com",
              chunks =
                [ "2:YWJj:MC4CAQAwBQYDK2VwBCIEIDfEfevydXXfKajz3sRkcQ7RPvfWUPoq6pu1TYHV1DEe:Z2hp",
                  "4:YWJj:MC4CAQAwBQYDK2VwBCIEIDfEfevydXXfKajz3sRkcQ7RPvfWUPoq6pu1TYHV1DEe:Z2hp:2mb"
                ]
            },
          YAMLServerReplicas
            { server = "xftp://abc=@example3.com",
              chunks =
                [ "1:YWJj:MC4CAQAwBQYDK2VwBCIEIDfEfevydXXfKajz3sRkcQ7RPvfWUPoq6pu1TYHV1DEe",
                  "4:YWJj:MC4CAQAwBQYDK2VwBCIEIDfEfevydXXfKajz3sRkcQ7RPvfWUPoq6pu1TYHV1DEe"
                ]
            },
          YAMLServerReplicas
            { server = "xftp://abc=@example4.com",
              chunks =
                [ "2:YWJj:MC4CAQAwBQYDK2VwBCIEIDfEfevydXXfKajz3sRkcQ7RPvfWUPoq6pu1TYHV1DEe",
                  "3:YWJj:MC4CAQAwBQYDK2VwBCIEIDfEfevydXXfKajz3sRkcQ7RPvfWUPoq6pu1TYHV1DEe"
                ]
            }
        ]
    }

testParseYAMLFileDescription :: IO ()
testParseYAMLFileDescription = do
  yfd <- Y.decodeFileThrow fileDescPath
  yfd `shouldBe` yamlFileDesc

testSerializeYAMLFileDescription :: IO ()
testSerializeYAMLFileDescription = withRemoveTmpFile $ do
  Y.encodeFile tmpFileDescPath yamlFileDesc
  fdSer <- B.readFile tmpFileDescPath
  fdExp <- B.readFile fileDescPath
  fdSer `shouldBe` fdExp

testParseFileDescription :: IO ()
testParseFileDescription = do
  r <- strDecode <$> B.readFile fileDescPath
  case r of
    Left e -> expectationFailure $ show e
    Right fd -> fd `shouldBe` fileDesc

testSerializeFileDescription :: IO ()
testSerializeFileDescription = withRemoveTmpFile $ do
  B.writeFile tmpFileDescPath $ strEncode fileDesc
  fdSer <- B.readFile tmpFileDescPath
  fdExp <- B.readFile fileDescPath
  fdSer `shouldBe` fdExp

withRemoveTmpFile :: IO () -> IO ()
withRemoveTmpFile =
  bracket_
    (pure ())
    (removeFile tmpFileDescPath)
