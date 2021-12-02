ALTER TABLE messages ADD msg_body BLOB NOT NULL DEFAULT x'';  -- this field replaces body TEXT
-- TODO possibly migrate the data from body if it is possible in migration
ALTER TABLE snd_messages ADD previous_msg_hash BLOB NOT NULL DEFAULT x'';
