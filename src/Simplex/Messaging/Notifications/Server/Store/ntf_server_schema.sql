

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


CREATE SCHEMA ntf_server;



CREATE FUNCTION ntf_server.on_subscription_delete() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF OLD.ntf_service_assoc = true THEN
    PERFORM update_ids_hash(OLD.smp_server_id, OLD.smp_notifier_id);
  END IF;
  RETURN OLD;
END;
$$;



CREATE FUNCTION ntf_server.on_subscription_insert() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF NEW.ntf_service_assoc = true THEN
    PERFORM update_ids_hash(NEW.smp_server_id, NEW.smp_notifier_id);
  END IF;
  RETURN NEW;
END;
$$;



CREATE FUNCTION ntf_server.on_subscription_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF OLD.ntf_service_assoc != NEW.ntf_service_assoc THEN
    PERFORM update_ids_hash(NEW.smp_server_id, NEW.smp_notifier_id);
  END IF;
  RETURN NEW;
END;
$$;



CREATE FUNCTION ntf_server.update_ids_hash(p_server_id bigint, p_notifier_id bytea) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
  UPDATE smp_servers
  SET smp_notifier_ids_hash = xor_combine(smp_notifier_ids_hash, public.digest(p_notifier_id, 'md5'))
  WHERE smp_server_id = p_server_id;
END;
$$;



CREATE FUNCTION ntf_server.xor_combine(state bytea, value bytea) RETURNS bytea
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



CREATE AGGREGATE ntf_server.xor_aggregate(bytea) (
    SFUNC = ntf_server.xor_combine,
    STYPE = bytea,
    INITCOND = '\x00000000000000000000000000000000'
);


SET default_table_access_method = heap;


CREATE TABLE ntf_server.last_notifications (
    token_ntf_id bigint NOT NULL,
    token_id bytea NOT NULL,
    subscription_id bytea NOT NULL,
    sent_at timestamp with time zone NOT NULL,
    nmsg_nonce bytea NOT NULL,
    nmsg_data bytea NOT NULL
);



ALTER TABLE ntf_server.last_notifications ALTER COLUMN token_ntf_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME ntf_server.last_notifications_token_ntf_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE ntf_server.migrations (
    name text NOT NULL,
    ts timestamp without time zone NOT NULL,
    down text
);



CREATE TABLE ntf_server.smp_servers (
    smp_server_id bigint NOT NULL,
    smp_host text NOT NULL,
    smp_port text NOT NULL,
    smp_keyhash bytea NOT NULL,
    ntf_service_id bytea,
    smp_notifier_ids_hash bytea DEFAULT '\x00000000000000000000000000000000'::bytea NOT NULL
);



ALTER TABLE ntf_server.smp_servers ALTER COLUMN smp_server_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME ntf_server.smp_servers_smp_server_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE ntf_server.subscriptions (
    subscription_id bytea NOT NULL,
    token_id bytea NOT NULL,
    smp_server_id bigint,
    smp_notifier_id bytea NOT NULL,
    smp_notifier_key bytea NOT NULL,
    status text NOT NULL,
    ntf_service_assoc boolean DEFAULT false NOT NULL
);



CREATE TABLE ntf_server.tokens (
    token_id bytea NOT NULL,
    push_provider text NOT NULL,
    push_provider_token bytea NOT NULL,
    status text NOT NULL,
    verify_key bytea NOT NULL,
    dh_priv_key bytea NOT NULL,
    dh_secret bytea NOT NULL,
    reg_code bytea NOT NULL,
    cron_interval bigint NOT NULL,
    cron_sent_at bigint,
    updated_at bigint
);



ALTER TABLE ONLY ntf_server.last_notifications
    ADD CONSTRAINT last_notifications_pkey PRIMARY KEY (token_ntf_id);



ALTER TABLE ONLY ntf_server.migrations
    ADD CONSTRAINT migrations_pkey PRIMARY KEY (name);



ALTER TABLE ONLY ntf_server.smp_servers
    ADD CONSTRAINT smp_servers_pkey PRIMARY KEY (smp_server_id);



ALTER TABLE ONLY ntf_server.subscriptions
    ADD CONSTRAINT subscriptions_pkey PRIMARY KEY (subscription_id);



ALTER TABLE ONLY ntf_server.tokens
    ADD CONSTRAINT tokens_pkey PRIMARY KEY (token_id);



CREATE INDEX idx_last_notifications_subscription_id ON ntf_server.last_notifications USING btree (subscription_id);



CREATE INDEX idx_last_notifications_token_id_sent_at ON ntf_server.last_notifications USING btree (token_id, sent_at);



CREATE UNIQUE INDEX idx_last_notifications_token_subscription ON ntf_server.last_notifications USING btree (token_id, subscription_id);



CREATE UNIQUE INDEX idx_smp_servers ON ntf_server.smp_servers USING btree (smp_host, smp_port, smp_keyhash);



CREATE UNIQUE INDEX idx_subscriptions_smp_server_id_notifier_id ON ntf_server.subscriptions USING btree (smp_server_id, smp_notifier_id);



CREATE INDEX idx_subscriptions_smp_server_id_ntf_service_status ON ntf_server.subscriptions USING btree (smp_server_id, ntf_service_assoc, status);



CREATE INDEX idx_subscriptions_token_id ON ntf_server.subscriptions USING btree (token_id);



CREATE UNIQUE INDEX idx_tokens_push_provider_token ON ntf_server.tokens USING btree (push_provider, push_provider_token, verify_key);



CREATE INDEX idx_tokens_status_cron_interval_sent_at ON ntf_server.tokens USING btree (status, cron_interval, ((cron_sent_at + (cron_interval * 60))));



CREATE TRIGGER tr_subscriptions_delete AFTER DELETE ON ntf_server.subscriptions FOR EACH ROW EXECUTE FUNCTION ntf_server.on_subscription_delete();



CREATE TRIGGER tr_subscriptions_insert AFTER INSERT ON ntf_server.subscriptions FOR EACH ROW EXECUTE FUNCTION ntf_server.on_subscription_insert();



CREATE TRIGGER tr_subscriptions_update AFTER UPDATE ON ntf_server.subscriptions FOR EACH ROW EXECUTE FUNCTION ntf_server.on_subscription_update();



ALTER TABLE ONLY ntf_server.last_notifications
    ADD CONSTRAINT last_notifications_subscription_id_fkey FOREIGN KEY (subscription_id) REFERENCES ntf_server.subscriptions(subscription_id) ON UPDATE RESTRICT ON DELETE CASCADE;



ALTER TABLE ONLY ntf_server.last_notifications
    ADD CONSTRAINT last_notifications_token_id_fkey FOREIGN KEY (token_id) REFERENCES ntf_server.tokens(token_id) ON UPDATE RESTRICT ON DELETE CASCADE;



ALTER TABLE ONLY ntf_server.subscriptions
    ADD CONSTRAINT subscriptions_smp_server_id_fkey FOREIGN KEY (smp_server_id) REFERENCES ntf_server.smp_servers(smp_server_id) ON UPDATE RESTRICT ON DELETE RESTRICT;



ALTER TABLE ONLY ntf_server.subscriptions
    ADD CONSTRAINT subscriptions_token_id_fkey FOREIGN KEY (token_id) REFERENCES ntf_server.tokens(token_id) ON UPDATE RESTRICT ON DELETE CASCADE;



