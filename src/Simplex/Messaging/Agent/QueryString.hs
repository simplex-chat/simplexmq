module Simplex.Messaging.Agent.QueryString where

import Data.Attoparsec.ByteString.Char8 (Parser)
import qualified Data.Attoparsec.ByteString.Char8 as A
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.List (find)
import qualified Network.HTTP.Types as Q
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Parsers (parseAll)

data QueryStringParams = QSP QSPEscaping Q.SimpleQuery
  deriving (Show)

data QSPEscaping = QEscape | QNoEscaping
  deriving (Show)

instance StrEncoding QueryStringParams where
  strEncode (QSP esc q) = case esc of
    QEscape -> Q.renderSimpleQuery False q
    QNoEscaping ->
      Q.renderQueryPartialEscape False $
        map (\(n, v) -> (n, [Q.QN v])) q
  strP = QSP QEscape . Q.parseSimpleQuery <$> A.takeTill (\c -> c == ' ' || c == '\n')

queryParam :: StrEncoding a => ByteString -> QueryStringParams -> Parser a
queryParam name q =
  case queryParamStr name q of
    Just p -> either fail pure $ parseAll strP p
    _ -> fail $ "no qs param " <> B.unpack name

queryParam_ :: StrEncoding a => ByteString -> QueryStringParams -> Parser (Maybe a)
queryParam_ name q =
  case queryParamStr name q of
    Just p -> either fail pure $ parseAll strP p
    _ -> pure Nothing

queryParamStr :: ByteString -> QueryStringParams -> Maybe ByteString
queryParamStr name (QSP _ q) = snd <$> find ((== name) . fst) q
