module Simplex.FileTransfer.Util
  ( uniqueCombine,
    createUniqueDirectory,
    safeFileNameStr,
    removePath,
  )
where

import Simplex.Messaging.Util (ifM, whenM)
import System.FilePath (makeValid, splitExtensions, takeFileName, (</>))
import System.IO.Error (isAlreadyExistsError)
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
      let f = candidatePath filePath fileName n
       in ifM (doesPathExist f) (tryCombine $ n + 1) (pure f)

createUniqueDirectory :: MonadUnliftIO m => FilePath -> String -> m FilePath
createUniqueDirectory filePath dirName = tryCreate (0 :: Int)
  where
    tryCreate n =
      let d = candidatePath filePath dirName n
       in (d <$ createDirectory d) `catch` \e -> if isAlreadyExistsError e then tryCreate (n + 1) else throwIO e

candidatePath :: FilePath -> String -> Int -> FilePath
candidatePath filePath fileName n = filePath </> (name <> suffix <> ext)
  where
    (name, ext) = splitExtensions $ safeFileNameStr fileName
    suffix = if n == 0 then "" else "_" <> show n

removePath :: MonadIO m => FilePath -> m ()
removePath p = do
  ifM (doesDirectoryExist p) (removeDirectoryRecursive p) $
    whenM (doesFileExist p) (removeFile p)
