{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.Postgres.Migrations.M20250702_conn_invitations_remove_cascade_delete where

import Data.Text (Text)
import qualified Data.Text as T
import Text.RawString.QQ (r)

m20250702_conn_invitations_remove_cascade_delete :: Text
m20250702_conn_invitations_remove_cascade_delete =
  T.pack
    [r|
ALTER TABLE conn_invitations DROP CONSTRAINT conn_invitations_contact_conn_id_fkey;

ALTER TABLE conn_invitations ALTER COLUMN contact_conn_id DROP NOT NULL;

ALTER TABLE conn_invitations
  ADD CONSTRAINT conn_invitations_contact_conn_id_fkey
  FOREIGN KEY (contact_conn_id)
  REFERENCES connections(conn_id)
  ON DELETE SET NULL;
|]

down_m20250702_conn_invitations_remove_cascade_delete :: Text
down_m20250702_conn_invitations_remove_cascade_delete =
  T.pack
    [r|
ALTER TABLE conn_invitations DROP CONSTRAINT conn_invitations_contact_conn_id_fkey;

ALTER TABLE conn_invitations ALTER COLUMN contact_conn_id SET NOT NULL;

ALTER TABLE conn_invitations
  ADD CONSTRAINT conn_invitations_contact_conn_id_fkey
  FOREIGN KEY (contact_conn_id)
  REFERENCES connections(conn_id)
  ON DELETE CASCADE;
|]
