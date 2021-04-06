module SimplexMarkdown where

import Data.String
import Styled
import System.Console.ANSI.Types

data Markdown = Markdown Format String | Markdown :|: Markdown

data Format
  = Bold
  | Italic
  | Underline
  | StrikeThrough
  | Colored Color
  | NoFormat

instance Semigroup Markdown where (<>) = (:|:)

instance Monoid Markdown where mempty = unmarked ""

instance IsString Markdown where fromString = unmarked

unmarked :: String -> Markdown
unmarked = Markdown NoFormat

styleMarkdown :: Markdown -> StyledString
styleMarkdown (s1 :|: s2) = styleMarkdown s1 <> styleMarkdown s2
styleMarkdown (Markdown f s) = Styled sgr s
  where
    sgr = case f of
      Bold -> [SetUnderlining SingleUnderline, SetConsoleIntensity BoldIntensity]
      Italic -> [SetUnderlining SingleUnderline]
      Underline -> [SetUnderlining SingleUnderline]
      StrikeThrough -> [SetSwapForegroundBackground True]
      Colored c -> [SetColor Foreground Vivid c]
      NoFormat -> []

-- parseMarkdown :: String -> Markdown
