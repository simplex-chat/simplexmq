

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE SCHEMA smp_server;



CREATE PROCEDURE smp_server.dec_msg_count(IN p_recipient_id bytea, IN p_size bigint, IN p_change bigint)
    LANGUAGE plpgsql
    AS $$
BEGIN
  UPDATE msg_queues
  SET msg_can_write = msg_can_write OR p_size <= p_change,
      msg_queue_size = GREATEST(p_size - p_change, 0)
  WHERE recipient_id = p_recipient_id;
END;
$$;



CREATE FUNCTION smp_server.delete_expired_msgs(p_recipient_id bytea, p_old_ts bigint) RETURNS bigint
    LANGUAGE plpgsql
    AS $$
DECLARE
  q_size BIGINT;
  min_id BIGINT;
  del_count BIGINT;
BEGIN
  SELECT msg_queue_size INTO q_size
  FROM msg_queues
  WHERE recipient_id = p_recipient_id AND deleted_at IS NULL
  FOR UPDATE SKIP LOCKED;

  IF NOT FOUND OR q_size = 0 THEN
    RETURN 0;
  END IF;

  SELECT LEAST( -- ignores NULLs
    (SELECT MIN(message_id) FROM messages WHERE recipient_id = p_recipient_id AND msg_ts >= p_old_ts),
    (SELECT MIN(message_id) FROM messages WHERE recipient_id = p_recipient_id AND msg_quota = TRUE)
  ) INTO min_id;

  IF min_id IS NULL THEN
    DELETE FROM messages WHERE recipient_id = p_recipient_id;
  ELSE
    DELETE FROM messages WHERE recipient_id = p_recipient_id AND message_id < min_id;
  END IF;

  GET DIAGNOSTICS del_count = ROW_COUNT;
  IF del_count > 0 THEN
    CALL dec_msg_count(p_recipient_id, q_size, del_count);
  END IF;
  RETURN del_count;
END;
$$;



CREATE PROCEDURE smp_server.expire_old_messages(IN p_now_ts bigint, IN p_ttl bigint, OUT r_expired_msgs_count bigint, OUT r_stored_msgs_count bigint, OUT r_stored_queues bigint)
    LANGUAGE plpgsql
    AS $$
DECLARE
  old_ts BIGINT := p_now_ts - p_ttl;
  very_old_ts BIGINT := p_now_ts - 2 * p_ttl - 86400;
  rid BYTEA;
  min_id BIGINT;
  q_size BIGINT;
  del_count BIGINT;
  total_deleted BIGINT := 0;
BEGIN
  FOR rid IN
    SELECT recipient_id
    FROM msg_queues
    WHERE deleted_at IS NULL AND updated_at > very_old_ts
  LOOP
    BEGIN -- sub-transaction for each queue
      del_count := delete_expired_msgs(rid, old_ts);
      total_deleted := total_deleted + del_count;
    EXCEPTION WHEN OTHERS THEN
      ROLLBACK;
      RAISE WARNING 'STORE, expire_old_messages, error expiring queue %: %', encode(rid, 'base64'), SQLERRM;
      CONTINUE;
    END;
    COMMIT;
  END LOOP;

  r_expired_msgs_count := total_deleted;
  r_stored_msgs_count := (SELECT COUNT(1) FROM messages);
  r_stored_queues := (SELECT COUNT(1) FROM msg_queues WHERE deleted_at IS NULL);
END;
$$;



CREATE FUNCTION smp_server.try_del_msg(p_recipient_id bytea, p_msg_id bytea) RETURNS TABLE(r_msg_id bytea, r_msg_ts bigint, r_msg_quota boolean, r_msg_ntf_flag boolean, r_msg_body bytea)
    LANGUAGE plpgsql
    AS $$
DECLARE
  q_size BIGINT;
  msg RECORD;
BEGIN
  SELECT msg_queue_size INTO q_size
  FROM msg_queues
  WHERE recipient_id = p_recipient_id AND deleted_at IS NULL
  FOR UPDATE;

  IF FOUND THEN
    SELECT message_id, msg_id, msg_ts, msg_quota, msg_ntf_flag, msg_body INTO msg
    FROM messages
    WHERE recipient_id = p_recipient_id
    ORDER BY message_id ASC LIMIT 1;

    IF FOUND AND msg.msg_id = p_msg_id THEN
      DELETE FROM messages WHERE message_id = msg.message_id;
      IF FOUND THEN
        CALL dec_msg_count(p_recipient_id, q_size, 1);
        RETURN QUERY VALUES (msg.msg_id, msg.msg_ts, msg.msg_quota, msg.msg_ntf_flag, msg.msg_body);
      END IF;
    END IF;
  END IF;
END;
$$;



CREATE FUNCTION smp_server.try_del_peek_msg(p_recipient_id bytea, p_msg_id bytea) RETURNS TABLE(r_msg_id bytea, r_msg_ts bigint, r_msg_quota boolean, r_msg_ntf_flag boolean, r_msg_body bytea)
    LANGUAGE plpgsql
    AS $$
DECLARE
  q_size BIGINT;
  msg RECORD;
BEGIN
  SELECT msg_queue_size INTO q_size
  FROM msg_queues
  WHERE recipient_id = p_recipient_id AND deleted_at IS NULL
  FOR UPDATE;

  IF FOUND THEN
    SELECT message_id, msg_id, msg_ts, msg_quota, msg_ntf_flag, msg_body INTO msg
    FROM messages
    WHERE recipient_id = p_recipient_id
    ORDER BY message_id ASC LIMIT 1;

    IF FOUND THEN
      IF msg.msg_id = p_msg_id THEN
        DELETE FROM messages WHERE message_id = msg.message_id;

        IF FOUND THEN
          CALL dec_msg_count(p_recipient_id, q_size, 1);
          RETURN QUERY VALUES (msg.msg_id, msg.msg_ts, msg.msg_quota, msg.msg_ntf_flag, msg.msg_body);
        END IF;

        RETURN QUERY (
          SELECT msg_id, msg_ts, msg_quota, msg_ntf_flag, msg_body
          FROM messages
          WHERE recipient_id = p_recipient_id
          ORDER BY message_id ASC LIMIT 1
        );
      ELSE
        RETURN QUERY VALUES (msg.msg_id, msg.msg_ts, msg.msg_quota, msg.msg_ntf_flag, msg.msg_body);
      END IF;
    END IF;
  END IF;
END;
$$;



CREATE FUNCTION smp_server.write_message(p_recipient_id bytea, p_msg_id bytea, p_msg_ts bigint, p_msg_quota boolean, p_msg_ntf_flag boolean, p_msg_body bytea, p_quota integer) RETURNS TABLE(quota_written boolean, was_empty boolean)
    LANGUAGE plpgsql
    AS $$
DECLARE
  q_can_write BOOLEAN;
  q_size BIGINT;
BEGIN
  SELECT msg_can_write, msg_queue_size INTO q_can_write, q_size
  FROM msg_queues
  WHERE recipient_id = p_recipient_id AND deleted_at IS NULL
  FOR UPDATE;

  IF q_can_write OR q_size = 0 THEN
    quota_written := p_msg_quota OR q_size >= p_quota;
    was_empty := q_size = 0;

    INSERT INTO messages(recipient_id, msg_id, msg_ts, msg_quota, msg_ntf_flag, msg_body)
    VALUES (p_recipient_id, p_msg_id, p_msg_ts, quota_written, p_msg_ntf_flag AND NOT quota_written, CASE WHEN quota_written THEN '' :: BYTEA ELSE p_msg_body END);

    UPDATE msg_queues
    SET msg_can_write = NOT quota_written,
        msg_queue_size = msg_queue_size + 1
    WHERE recipient_id = p_recipient_id;

    RETURN QUERY VALUES (quota_written, was_empty);
  END IF;
END;
$$;


SET default_table_access_method = heap;


CREATE TABLE smp_server.messages (
    message_id bigint NOT NULL,
    recipient_id bytea NOT NULL,
    msg_id bytea NOT NULL,
    msg_ts bigint NOT NULL,
    msg_quota boolean NOT NULL,
    msg_ntf_flag boolean NOT NULL,
    msg_body bytea NOT NULL
);



ALTER TABLE smp_server.messages ALTER COLUMN message_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME smp_server.messages_message_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE smp_server.migrations (
    name text NOT NULL,
    ts timestamp without time zone NOT NULL,
    down text
);



CREATE TABLE smp_server.msg_queues (
    recipient_id bytea NOT NULL,
    recipient_keys bytea NOT NULL,
    rcv_dh_secret bytea NOT NULL,
    sender_id bytea NOT NULL,
    sender_key bytea,
    notifier_id bytea,
    notifier_key bytea,
    rcv_ntf_dh_secret bytea,
    status text NOT NULL,
    updated_at bigint,
    deleted_at bigint,
    queue_mode text,
    link_id bytea,
    fixed_data bytea,
    user_data bytea,
    rcv_service_id bytea,
    ntf_service_id bytea,
    msg_can_write boolean DEFAULT true NOT NULL,
    msg_queue_size bigint DEFAULT 0 NOT NULL
);



CREATE TABLE smp_server.services (
    service_id bytea NOT NULL,
    service_role text NOT NULL,
    service_cert bytea NOT NULL,
    service_cert_hash bytea NOT NULL,
    created_at bigint NOT NULL
);



ALTER TABLE ONLY smp_server.messages
    ADD CONSTRAINT messages_pkey PRIMARY KEY (message_id);



ALTER TABLE ONLY smp_server.migrations
    ADD CONSTRAINT migrations_pkey PRIMARY KEY (name);



ALTER TABLE ONLY smp_server.msg_queues
    ADD CONSTRAINT msg_queues_pkey PRIMARY KEY (recipient_id);



ALTER TABLE ONLY smp_server.services
    ADD CONSTRAINT services_pkey PRIMARY KEY (service_id);



ALTER TABLE ONLY smp_server.services
    ADD CONSTRAINT services_service_cert_hash_key UNIQUE (service_cert_hash);



CREATE INDEX idx_messages_recipient_id_message_id ON smp_server.messages USING btree (recipient_id, message_id);



CREATE INDEX idx_messages_recipient_id_msg_quota ON smp_server.messages USING btree (recipient_id, msg_quota);



CREATE INDEX idx_messages_recipient_id_msg_ts ON smp_server.messages USING btree (recipient_id, msg_ts);



CREATE UNIQUE INDEX idx_msg_queues_link_id ON smp_server.msg_queues USING btree (link_id);



CREATE UNIQUE INDEX idx_msg_queues_notifier_id ON smp_server.msg_queues USING btree (notifier_id);



CREATE INDEX idx_msg_queues_ntf_service_id ON smp_server.msg_queues USING btree (ntf_service_id, deleted_at);



CREATE INDEX idx_msg_queues_rcv_service_id ON smp_server.msg_queues USING btree (rcv_service_id, deleted_at);



CREATE UNIQUE INDEX idx_msg_queues_sender_id ON smp_server.msg_queues USING btree (sender_id);



CREATE INDEX idx_msg_queues_updated_at ON smp_server.msg_queues USING btree (deleted_at, updated_at);



CREATE INDEX idx_services_service_role ON smp_server.services USING btree (service_role);



ALTER TABLE ONLY smp_server.messages
    ADD CONSTRAINT messages_recipient_id_fkey FOREIGN KEY (recipient_id) REFERENCES smp_server.msg_queues(recipient_id) ON UPDATE RESTRICT ON DELETE CASCADE;



ALTER TABLE ONLY smp_server.msg_queues
    ADD CONSTRAINT msg_queues_ntf_service_id_fkey FOREIGN KEY (ntf_service_id) REFERENCES smp_server.services(service_id) ON UPDATE RESTRICT ON DELETE SET NULL;



ALTER TABLE ONLY smp_server.msg_queues
    ADD CONSTRAINT msg_queues_rcv_service_id_fkey FOREIGN KEY (rcv_service_id) REFERENCES smp_server.services(service_id) ON UPDATE RESTRICT ON DELETE SET NULL;



