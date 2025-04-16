

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
    ntf_server_host bytea
);



CREATE TABLE smp_server.ntf_servers (
    ntf_server_host bytea NOT NULL,
    additional_hosts bytea,
    port text NOT NULL,
    key_hash bytea NOT NULL,
    cert_chain bytea NOT NULL,
    signed_auth_key bytea NOT NULL,
    auth_key bytea NOT NULL
);



ALTER TABLE ONLY smp_server.migrations
    ADD CONSTRAINT migrations_pkey PRIMARY KEY (name);



ALTER TABLE ONLY smp_server.msg_queues
    ADD CONSTRAINT msg_queues_pkey PRIMARY KEY (recipient_id);



ALTER TABLE ONLY smp_server.ntf_servers
    ADD CONSTRAINT ntf_servers_pkey PRIMARY KEY (ntf_server_host);



CREATE UNIQUE INDEX idx_msg_queues_link_id ON smp_server.msg_queues USING btree (link_id);



CREATE UNIQUE INDEX idx_msg_queues_notifier_id ON smp_server.msg_queues USING btree (notifier_id);



CREATE INDEX idx_msg_queues_ntf_server_host ON smp_server.msg_queues USING btree (ntf_server_host);



CREATE UNIQUE INDEX idx_msg_queues_sender_id ON smp_server.msg_queues USING btree (sender_id);



CREATE INDEX idx_msg_queues_updated_at ON smp_server.msg_queues USING btree (deleted_at, updated_at);



ALTER TABLE ONLY smp_server.msg_queues
    ADD CONSTRAINT msg_queues_ntf_server_host_fkey FOREIGN KEY (ntf_server_host) REFERENCES smp_server.ntf_servers(ntf_server_host);



