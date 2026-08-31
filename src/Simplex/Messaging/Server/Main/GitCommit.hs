{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TemplateHaskell #-}

module Simplex.Messaging.Server.Main.GitCommit
  ( gitCommit,
  ) where

import Language.Haskell.TH
import Language.Haskell.TH.Syntax (addDependentFile)
import System.Process
import Control.Exception
import Control.Monad (filterM)
import System.Directory (doesFileExist)
import System.Exit
import System.FilePath ((</>))

gitCommit :: Q Exp
gitCommit =
  runIO gitHead >>= \case
    Right (ExitSuccess, out, _)
      | [commit, gitDir] <- lines out -> do
          -- without these dependencies GHC recompilation check would not know that the commit changed.
          -- HEAD reflog is updated on any HEAD change and, unlike branch ref files, git gc cannot remove it
          -- mid-build; it is absent when reflogs are disabled, and addDependentFile fails on a missing file
          mapM_ addDependentFile =<< runIO (filterM doesFileExist [gitDir </> "HEAD", gitDir </> "logs" </> "HEAD"])
          stringE commit
    _ -> stringE ""
  where
    gitHead :: IO (Either SomeException (ExitCode, String, String))
    gitHead = try $ readProcessWithExitCode "git" ["rev-parse", "HEAD", "--git-dir"] ""
