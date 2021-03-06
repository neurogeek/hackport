import Control.Monad (when)

import qualified Distribution.Package as Cabal

import qualified Portage.Overlay as Portage
import qualified Portage.Resolve as Portage
import qualified Portage.PackageId as Portage
import qualified Portage.Host as Portage

import System.Exit (exitFailure)
import Test.HUnit

tests = TestList [ TestLabel "resolve cabal" (test_resolveCategory "dev-haskell" "cabal")
                 , TestLabel "resolve ghc" (test_resolveCategory "dev-lang" "ghc")
                 ]

test_resolveCategory :: String -> String -> Test
test_resolveCategory cat pkg = TestCase $ do
  portage_dir <- Portage.portage_dir `fmap` Portage.getInfo
  portage <- Portage.loadLazy portage_dir
  let cabal = Cabal.PackageName pkg
      hits = Portage.resolveFullPortageName portage cabal
      expected = Just (Portage.PackageName (Portage.Category cat) cabal)
  assertEqual ("expecting to find package " ++ pkg) hits expected 

something_broke :: Counts -> Bool
something_broke stats = errors stats + failures stats > 0

main =
    do stats <- runTestTT tests
       when (something_broke stats) exitFailure
