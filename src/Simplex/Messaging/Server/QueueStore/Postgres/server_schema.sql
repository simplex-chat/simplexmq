

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



CREATE FUNCTION smp_server.on_queue_delete() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF OLD.rcv_service_id IS NOT NULL THEN
    PERFORM update_queue_hash(OLD.rcv_service_id, 'M', OLD.recipient_id);
  END IF;
  IF OLD.ntf_service_id IS NOT NULL THEN
    PERFORM update_queue_hash(OLD.ntf_service_id, 'N', OLD.notifier_id);
  END IF;
  RETURN OLD;
END;
$$;



CREATE FUNCTION smp_server.on_queue_insert() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF NEW.rcv_service_id IS NOT NULL THEN
    PERFORM update_queue_hash(NEW.rcv_service_id, 'M', NEW.recipient_id);
  END IF;
  IF NEW.ntf_service_id IS NOT NULL THEN
    PERFORM update_queue_hash(NEW.ntf_service_id, 'N', NEW.notifier_id);
  END IF;
  RETURN NEW;
END;
$$;



CREATE FUNCTION smp_server.on_queue_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF OLD.rcv_service_id IS DISTINCT FROM NEW.rcv_service_id THEN
    PERFORM update_queue_hash(OLD.rcv_service_id, 'M', OLD.recipient_id);
    PERFORM update_queue_hash(NEW.rcv_service_id, 'M', NEW.recipient_id);
  END IF;
  IF OLD.ntf_service_id IS DISTINCT FROM NEW.ntf_service_id THEN
    PERFORM update_queue_hash(OLD.ntf_service_id, 'N', OLD.notifier_id);
    PERFORM update_queue_hash(NEW.ntf_service_id, 'N', NEW.notifier_id);
  END IF;
  RETURN NEW;
END;
$$;



CREATE FUNCTION smp_server.update_ids_hash(p_service_id bytea, p_role text, p_queue_id bytea) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
  UPDATE services
  SET queue_ids_hash = xor_combine(queue_ids_hash, digest(p_queue_id, 'md5'))
  WHERE service_id = p_service_id AND service_role = p_role;
END;
$$;



CREATE FUNCTION smp_server.xor_combine(state bytea, value bytea) RETURNS bytea
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



CREATE AGGREGATE smp_server.xor_aggregate(bytea) (
    SFUNC = smp_server.xor_combine,
    STYPE = bytea,
    INITCOND = '\x00000000000000000000000000000000'
);


SET default_table_access_method = heap;


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
    ntf_service_id bytea
);



CREATE TABLE smp_server.services (
    service_id bytea NOT NULL,
    service_role text NOT NULL,
    service_cert bytea NOT NULL,
    service_cert_hash bytea NOT NULL,
    created_at bigint NOT NULL,
    queue_ids_hash bytea
);



ALTER TABLE ONLY smp_server.migrations
    ADD CONSTRAINT migrations_pkey PRIMARY KEY (name);



ALTER TABLE ONLY smp_server.msg_queues
    ADD CONSTRAINT msg_queues_pkey PRIMARY KEY (recipient_id);



ALTER TABLE ONLY smp_server.services
    ADD CONSTRAINT services_pkey PRIMARY KEY (service_id);



ALTER TABLE ONLY smp_server.services
    ADD CONSTRAINT services_service_cert_hash_key UNIQUE (service_cert_hash);



CREATE UNIQUE INDEX idx_msg_queues_link_id ON smp_server.msg_queues USING btree (link_id);



CREATE UNIQUE INDEX idx_msg_queues_notifier_id ON smp_server.msg_queues USING btree (notifier_id);



CREATE INDEX idx_msg_queues_ntf_service_id ON smp_server.msg_queues USING btree (ntf_service_id, deleted_at);



CREATE INDEX idx_msg_queues_rcv_service_id ON smp_server.msg_queues USING btree (rcv_service_id, deleted_at);



CREATE UNIQUE INDEX idx_msg_queues_sender_id ON smp_server.msg_queues USING btree (sender_id);



CREATE INDEX idx_msg_queues_updated_at ON smp_server.msg_queues USING btree (deleted_at, updated_at);



CREATE INDEX idx_services_service_role ON smp_server.services USING btree (service_role);



CREATE TRIGGER tr_queue_delete AFTER DELETE ON smp_server.msg_queues FOR EACH ROW EXECUTE FUNCTION smp_server.on_queue_delete();



CREATE TRIGGER tr_queue_insert AFTER INSERT ON smp_server.msg_queues FOR EACH ROW EXECUTE FUNCTION smp_server.on_queue_insert();



CREATE TRIGGER tr_queue_update AFTER UPDATE ON smp_server.msg_queues FOR EACH ROW EXECUTE FUNCTION smp_server.on_queue_update();



ALTER TABLE ONLY smp_server.msg_queues
    ADD CONSTRAINT msg_queues_ntf_service_id_fkey FOREIGN KEY (ntf_service_id) REFERENCES smp_server.services(service_id) ON UPDATE RESTRICT ON DELETE SET NULL;



ALTER TABLE ONLY smp_server.msg_queues
    ADD CONSTRAINT msg_queues_rcv_service_id_fkey FOREIGN KEY (rcv_service_id) REFERENCES smp_server.services(service_id) ON UPDATE RESTRICT ON DELETE SET NULL;



