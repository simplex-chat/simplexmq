module Simplex.FileTransfer.Util
  ( uniqueCombine,
    safeFileNameStr,
    removePath,
  )
where

import Simplex.Messaging.Util (ifM, whenM)
import System.FilePath (makeValid, splitExtensions, takeFileName, (</>))
import UnliftIO
import UnliftIO.Directory

safeFileNameStr :: String -> String
safeFileNameStr = notDots . makeValid . takeFileName
  where
    notDots n = if n == "." || n == ".." then "_" else n

-- | The file name is sanitized, so the combined path cannot escape the folder.
uniqueCombine :: MonadIO m => FilePath -> String -> m FilePath
uniqueCombine filePath fileName = tryCombine (0 :: Int)
  where
    tryCombine n =
      let (name, ext) = splitExtensions $ safeFileNameStr fileName
          suffix = if n == 0 then "" else "_" <> show n
          f = filePath </> (name <> suffix <> ext)
       in ifM (doesPathExist f) (tryCombine $ n + 1) (pure f)

removePath :: MonadIO m => FilePath -> m ()
removePath p = do
  ifM (doesDirectoryExist p) (removeDirectoryRecursive p) $
    whenM (doesFileExist p) (removeFile p)
