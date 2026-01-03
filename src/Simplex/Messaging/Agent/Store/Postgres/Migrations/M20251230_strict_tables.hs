{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.Postgres.Migrations.M20251230_strict_tables where

import Data.Text (Text)
import Text.RawString.QQ (r)

m20251230_strict_tables :: Text
m20251230_strict_tables =
  isValidText
    <> [r|
DELETE FROM ntf_tokens
WHERE NOT simplex_is_valid_text(ntf_mode);

ALTER TABLE ntf_tokens
  ALTER COLUMN device_token TYPE BYTEA USING device_token::BYTEA,
  ALTER COLUMN ntf_mode TYPE TEXT USING ntf_mode::TEXT;

UPDATE ntf_subscriptions
SET ntf_sub_action = NULL
WHERE NOT simplex_is_valid_text(ntf_sub_action);

UPDATE ntf_subscriptions
SET ntf_sub_smp_action = NULL
WHERE NOT simplex_is_valid_text(ntf_sub_smp_action);

ALTER TABLE ntf_subscriptions
  ALTER COLUMN ntf_sub_action TYPE TEXT USING ntf_sub_action::TEXT,
  ALTER COLUMN ntf_sub_smp_action TYPE TEXT USING ntf_sub_smp_action::TEXT;

DROP FUNCTION simplex_is_valid_text(BYTEA);
|]

down_m20251230_strict_tables :: Text
down_m20251230_strict_tables =
  isValidText
    <> [r|
DELETE FROM ntf_tokens
WHERE NOT simplex_is_valid_text(device_token);

ALTER TABLE ntf_tokens
  ALTER COLUMN device_token TYPE TEXT USING device_token::TEXT,
  ALTER COLUMN ntf_mode TYPE BYTEA USING ntf_mode::BYTEA;

ALTER TABLE ntf_subscriptions
  ALTER COLUMN ntf_sub_action TYPE BYTEA USING ntf_sub_action::BYTEA,
  ALTER COLUMN ntf_sub_smp_action TYPE BYTEA USING ntf_sub_smp_action::BYTEA;

DROP FUNCTION simplex_is_valid_text(BYTEA);
|]

isValidText :: Text
isValidText =
  [r|
CREATE FUNCTION simplex_is_valid_text(b BYTEA)
RETURNS BOOLEAN
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM b::TEXT;
    RETURN TRUE;
EXCEPTION
    WHEN OTHERS THEN RETURN FALSE;
END;
$$;
|]
