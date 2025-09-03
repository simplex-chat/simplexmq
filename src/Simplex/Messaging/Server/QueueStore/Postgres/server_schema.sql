

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



CREATE FUNCTION smp_server.on_message_delete() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  UPDATE msg_queues
  SET msg_can_write = msg_can_write OR msg_queue_size <= 1,
      msg_queue_size = msg_queue_size - 1
  WHERE recipient_id = OLD.recipient_id;
  RETURN OLD;
END;
$$;



CREATE FUNCTION smp_server.on_message_insert() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  UPDATE msg_queues
  SET msg_can_write = NOT NEW.msg_quota,
      msg_queue_size = msg_queue_size + 1
  WHERE recipient_id = NEW.recipient_id;
  RETURN NEW;
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



CREATE INDEX idx_messages_msg_ts ON smp_server.messages USING btree (msg_ts);



CREATE INDEX idx_messages_recipient_id_message_id ON smp_server.messages USING btree (recipient_id, message_id);



CREATE INDEX idx_messages_recipient_id_msg_ts ON smp_server.messages USING btree (recipient_id, msg_ts);



CREATE UNIQUE INDEX idx_msg_queues_link_id ON smp_server.msg_queues USING btree (link_id);



CREATE UNIQUE INDEX idx_msg_queues_notifier_id ON smp_server.msg_queues USING btree (notifier_id);



CREATE INDEX idx_msg_queues_ntf_service_id ON smp_server.msg_queues USING btree (ntf_service_id, deleted_at);



CREATE INDEX idx_msg_queues_rcv_service_id ON smp_server.msg_queues USING btree (rcv_service_id, deleted_at);



CREATE UNIQUE INDEX idx_msg_queues_sender_id ON smp_server.msg_queues USING btree (sender_id);



CREATE INDEX idx_msg_queues_updated_at ON smp_server.msg_queues USING btree (deleted_at, updated_at);



CREATE INDEX idx_services_service_role ON smp_server.services USING btree (service_role);



CREATE TRIGGER tr_messages_delete AFTER DELETE ON smp_server.messages FOR EACH ROW EXECUTE FUNCTION smp_server.on_message_delete();



CREATE TRIGGER tr_messages_insert AFTER INSERT ON smp_server.messages FOR EACH ROW EXECUTE FUNCTION smp_server.on_message_insert();



ALTER TABLE ONLY smp_server.messages
    ADD CONSTRAINT messages_recipient_id_fkey FOREIGN KEY (recipient_id) REFERENCES smp_server.msg_queues(recipient_id) ON UPDATE RESTRICT ON DELETE CASCADE;



ALTER TABLE ONLY smp_server.msg_queues
    ADD CONSTRAINT msg_queues_ntf_service_id_fkey FOREIGN KEY (ntf_service_id) REFERENCES smp_server.services(service_id) ON UPDATE RESTRICT ON DELETE SET NULL;



ALTER TABLE ONLY smp_server.msg_queues
    ADD CONSTRAINT msg_queues_rcv_service_id_fkey FOREIGN KEY (rcv_service_id) REFERENCES smp_server.services(service_id) ON UPDATE RESTRICT ON DELETE SET NULL;



