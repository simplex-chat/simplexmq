{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.Postgres.Migrations.Util where

import Data.Text (Text)
import qualified Data.Text as T
import Text.RawString.QQ (r)

-- xor_combine is only applied to locally computed md5 hashes (128 bits/16 bytes),
-- so it is safe to require that all values are of the same length.
createXorHashFuncs :: Text
createXorHashFuncs =
  T.pack
    [r|
CREATE OR REPLACE FUNCTION xor_combine(state BYTEA, value BYTEA) RETURNS BYTEA
LANGUAGE plpgsql IMMUTABLE STRICT
AS $$
DECLARE
  result BYTEA := state;
  i INTEGER;
  len INTEGER := octet_length(value);
BEGIN
  IF octet_length(state) != len THEN
    RAISE EXCEPTION 'Inputs must be equal length (% != %)', octet_length(state), len;
  END IF;
  FOR i IN 0..len-1 LOOP
    result := set_byte(result, i, get_byte(state, i) # get_byte(value, i));
  END LOOP;
  RETURN result;
END;
$$;

CREATE OR REPLACE AGGREGATE xor_aggregate(BYTEA) (
  SFUNC = xor_combine,
  STYPE = BYTEA,
  INITCOND = '\x00000000000000000000000000000000' -- 16 bytes
);
    |]

dropXorHashFuncs :: Text
dropXorHashFuncs =
  T.pack
    [r|
DROP AGGREGATE xor_aggregate(BYTEA);
DROP FUNCTION xor_combine;
    |]
