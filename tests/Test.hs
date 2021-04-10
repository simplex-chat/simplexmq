import AgentTests
import MarkdownTests
import ServerTests
import Test.Hspec

main :: IO ()
main = hspec $ do
  describe "SimpleX markdown" markdownTests
  describe "SMP server" serverTests
  describe "SMP client agent" agentTests
