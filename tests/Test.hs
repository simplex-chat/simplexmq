import AgentTests
import MarkdownTests
import ServerTests
import System.Directory (createDirectoryIfMissing, removeDirectoryRecursive)
import Test.Hspec

main :: IO ()
main = do
  createDirectoryIfMissing False "tests/tmp"
  hspec $ do
    describe "SimpleX markdown" markdownTests
    describe "SMP server" serverTests
    describe "SMP client agent" agentTests
  removeDirectoryRecursive "tests/tmp"
