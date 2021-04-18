import AgentTests
import MarkdownTests
import ProtocolErrorTests
import ServerTests
import System.Directory (createDirectoryIfMissing, removeDirectoryRecursive)
import Test.Hspec

main :: IO ()
main = do
  createDirectoryIfMissing False "tests/tmp"
  hspec $ do
    describe "SimpleX markdown" markdownTests
    describe "Protocol errors" protocolErrorTests
    describe "SMP server" serverTests
    describe "SMP client agent" agentTests
  removeDirectoryRecursive "tests/tmp"
