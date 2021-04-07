{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

module SimplexMarkdown where

import Data.Attoparsec.Text (Parser)
import qualified Data.Attoparsec.Text as A
import Data.Functor (($>))
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Data.String
import Data.Text (Text)
import qualified Data.Text as T
import Styled
import System.Console.ANSI.Types

data Markdown = Markdown Format Text | Markdown :|: Markdown
  deriving (Show)

data Format
  = Bold
  | Italic
  | Underline
  | StrikeThrough
  | Colored Color
  | NoFormat
  deriving (Show)

instance Semigroup Markdown where (<>) = (:|:)

instance Monoid Markdown where mempty = unmarked ""

instance IsString Markdown where fromString = unmarked . T.pack

unmarked :: Text -> Markdown
unmarked = Markdown NoFormat

styleMarkdown :: Markdown -> StyledString
styleMarkdown (s1 :|: s2) = styleMarkdown s1 <> styleMarkdown s2
styleMarkdown (Markdown f s) = Styled sgr $ T.unpack s
  where
    sgr = case f of
      Bold -> [SetConsoleIntensity BoldIntensity]
      Italic -> [SetUnderlining SingleUnderline]
      Underline -> [SetUnderlining SingleUnderline]
      StrikeThrough -> [SetSwapForegroundBackground True]
      Colored c -> [SetColor Foreground Vivid c]
      NoFormat -> []

formats :: Map Char Format
formats =
  M.fromList
    [ ('*', Bold),
      ('_', Italic),
      ('+', Underline),
      ('~', StrikeThrough),
      ('^', Colored White)
    ]

colors :: Map Text Color
colors =
  M.fromList
    [ ("red", Red),
      ("green", Green),
      ("blue", Blue),
      ("yellow", Yellow),
      ("cyan", Cyan),
      ("magenta", Magenta)
    ]

markdownP :: Parser Markdown
markdownP = (:|:) <$> fragmentP <*> markdownP
  where
    fragmentP :: Parser Markdown
    fragmentP = do
      end <- A.atEnd
      if end
        then pure ""
        else do
          c <- A.anyChar
          case M.lookup c formats of
            Just (Colored White) -> coloredP
            Just f -> formattedP c f
            Nothing -> unformattedP c
    formattedP :: Char -> Format -> Parser Markdown
    formattedP c f = do
      s <- A.takeTill (== c)
      end <- A.atEnd
      if end
        then pure $ unmarked s
        else A.anyChar $> Markdown f s
    coloredP :: Parser Markdown
    coloredP = do
      cs <- A.takeTill (== ' ')
      let f = maybe NoFormat Colored (M.lookup cs colors)
      A.takeWhile (== ' ') *> formattedP '^' f
    unformattedP :: Char -> Parser Markdown
    unformattedP c = unmarked . (T.singleton c <>) <$> wordsP
    wordsP :: Parser Text
    wordsP = do
      s <- A.takeTill (== ' ')
      end <- A.atEnd
      if end
        then pure s
        else do
          _ <- A.anyChar -- this is space
          A.peekChar >>= \case
            Just c -> case M.lookup c formats of
              Just _ -> pure s
              Nothing -> (s <>) <$> wordsP
            Nothing -> pure s
