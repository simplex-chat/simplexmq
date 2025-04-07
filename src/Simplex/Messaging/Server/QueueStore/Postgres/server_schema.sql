--
-- PostgreSQL database dump
--

-- Dumped from database version 15.12 (Homebrew)
-- Dumped by pg_dump version 15.12 (Homebrew)

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

--
-- Name: smp_server; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA smp_server;


--
-- Name: migrations; Type: TABLE; Schema: smp_server; Owner: -
--

CREATE TABLE smp_server.migrations (
    name text NOT NULL,
    ts timestamp without time zone NOT NULL,
    down text
);


--
-- Name: msg_queues; Type: TABLE; Schema: smp_server; Owner: -
--

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
    user_data bytea
);


--
-- Name: migrations migrations_pkey; Type: CONSTRAINT; Schema: smp_server; Owner: -
--

ALTER TABLE ONLY smp_server.migrations
    ADD CONSTRAINT migrations_pkey PRIMARY KEY (name);


--
-- Name: msg_queues msg_queues_pkey; Type: CONSTRAINT; Schema: smp_server; Owner: -
--

ALTER TABLE ONLY smp_server.msg_queues
    ADD CONSTRAINT msg_queues_pkey PRIMARY KEY (recipient_id);


--
-- Name: idx_msg_queues_link_id; Type: INDEX; Schema: smp_server; Owner: -
--

CREATE UNIQUE INDEX idx_msg_queues_link_id ON smp_server.msg_queues USING btree (link_id);


--
-- Name: idx_msg_queues_notifier_id; Type: INDEX; Schema: smp_server; Owner: -
--

CREATE UNIQUE INDEX idx_msg_queues_notifier_id ON smp_server.msg_queues USING btree (notifier_id);


--
-- Name: idx_msg_queues_sender_id; Type: INDEX; Schema: smp_server; Owner: -
--

CREATE UNIQUE INDEX idx_msg_queues_sender_id ON smp_server.msg_queues USING btree (sender_id);


--
-- Name: idx_msg_queues_updated_at; Type: INDEX; Schema: smp_server; Owner: -
--

CREATE INDEX idx_msg_queues_updated_at ON smp_server.msg_queues USING btree (deleted_at, updated_at);


--
-- PostgreSQL database dump complete
--

