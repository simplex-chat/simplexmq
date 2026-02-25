{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TemplateHaskell #-}

module Simplex.Messaging.Server.Main.GitCommit
  ( gitCommit,
  ) where

import Language.Haskell.TH
import System.Process
import Control.Exception
import System.Exit

gitCommit :: Q Exp
gitCommit = stringE . commit =<< runIO (try $ readProcessWithExitCode "git" ["rev-parse", "HEAD"] "")
  where
    commit :: Either SomeException (ExitCode, String, String) -> String
    commit = \case
      Right (ExitSuccess, out, _) -> take 40 out
      _ -> ""
