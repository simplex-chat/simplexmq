module Styled (StyledString (Styled), plain, bPlain, styledToANSITerm, styledToPlain) where

import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.String
import System.Console.ANSI (SGR (..), setSGRCode)

data StyledString = Styled [SGR] String | Concat StyledString StyledString

instance Semigroup StyledString where (<>) = Concat

instance Monoid StyledString where mempty = plain ""

instance IsString StyledString where
  fromString = plain

plain :: String -> StyledString
plain = Styled []

bPlain :: ByteString -> StyledString
bPlain = Styled [] . B.unpack

styledToANSITerm :: StyledString -> String
styledToANSITerm (Styled [] s) = s
styledToANSITerm (Styled sgr s) = setSGRCode sgr <> s <> setSGRCode [Reset]
styledToANSITerm (Concat s1 s2) = styledToANSITerm s1 <> styledToANSITerm s2

styledToPlain :: StyledString -> String
styledToPlain (Styled _ s) = s
styledToPlain (Concat s1 s2) = styledToPlain s1 <> styledToPlain s2
