

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


CREATE SCHEMA smp_agent_test_protocol_schema;



CREATE FUNCTION smp_agent_test_protocol_schema.on_rcv_queue_delete() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF OLD.rcv_service_assoc != 0 AND OLD.deleted = 0 THEN
    PERFORM update_aggregates(OLD.conn_id, OLD.host, OLD.port, -1, OLD.rcv_id);
  END IF;
  RETURN OLD;
END;
$$;



CREATE FUNCTION smp_agent_test_protocol_schema.on_rcv_queue_insert() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF NEW.rcv_service_assoc != 0 AND NEW.deleted = 0 THEN
    PERFORM update_aggregates(NEW.conn_id, NEW.host, NEW.port, 1, NEW.rcv_id);
  END IF;
  RETURN NEW;
END;
$$;



CREATE FUNCTION smp_agent_test_protocol_schema.on_rcv_queue_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF OLD.rcv_service_assoc != 0 AND OLD.deleted = 0 THEN
    IF NOT (NEW.rcv_service_assoc != 0 AND NEW.deleted = 0) THEN
      PERFORM update_aggregates(OLD.conn_id, OLD.host, OLD.port, -1, OLD.rcv_id);
    END IF;
  ELSIF NEW.rcv_service_assoc != 0 AND NEW.deleted = 0 THEN
    PERFORM update_aggregates(NEW.conn_id, NEW.host, NEW.port, 1, NEW.rcv_id);
  END IF;
  RETURN NEW;
END;
$$;



CREATE FUNCTION smp_agent_test_protocol_schema.update_aggregates(p_conn_id bytea, p_host text, p_port text, p_change bigint, p_rcv_id bytea) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE q_user_id BIGINT;
BEGIN
  SELECT user_id INTO q_user_id FROM connections WHERE conn_id = p_conn_id;
  UPDATE client_services
  SET service_queue_count = service_queue_count + p_change,
      service_queue_ids_hash = xor_combine(service_queue_ids_hash, public.digest(p_rcv_id, 'md5'))
  WHERE user_id = q_user_id AND host = p_host AND port = p_port;
END;
$$;


SET default_table_access_method = heap;


CREATE TABLE smp_agent_test_protocol_schema.client_notices (
    client_notice_id bigint NOT NULL,
    protocol text NOT NULL,
    host text NOT NULL,
    port text NOT NULL,
    entity_id bytea NOT NULL,
    server_key_hash bytea,
    notice_ttl bigint,
    created_at bigint NOT NULL,
    updated_at bigint NOT NULL
);



ALTER TABLE smp_agent_test_protocol_schema.client_notices ALTER COLUMN client_notice_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME smp_agent_test_protocol_schema.client_notices_client_notice_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE smp_agent_test_protocol_schema.client_services (
    user_id bigint NOT NULL,
    host text NOT NULL,
    port text NOT NULL,
    server_key_hash bytea,
    service_cert bytea NOT NULL,
    service_cert_hash bytea NOT NULL,
    service_priv_key bytea NOT NULL,
    service_id bytea,
    service_queue_count bigint DEFAULT 0 NOT NULL,
    service_queue_ids_hash bytea DEFAULT '\x00000000000000000000000000000000'::bytea NOT NULL
);



CREATE TABLE smp_agent_test_protocol_schema.commands (
    command_id bigint NOT NULL,
    conn_id bytea NOT NULL,
    host text,
    port text,
    corr_id bytea NOT NULL,
    command_tag bytea NOT NULL,
    command bytea NOT NULL,
    agent_version integer DEFAULT 1 NOT NULL,
    server_key_hash bytea,
    created_at timestamp with time zone DEFAULT '1970-01-01 00:00:00+01'::timestamp with time zone NOT NULL,
    failed smallint DEFAULT 0
);



ALTER TABLE smp_agent_test_protocol_schema.commands ALTER COLUMN command_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME smp_agent_test_protocol_schema.commands_command_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE smp_agent_test_protocol_schema.conn_confirmations (
    confirmation_id bytea NOT NULL,
    conn_id bytea NOT NULL,
    e2e_snd_pub_key bytea NOT NULL,
    sender_key bytea,
    ratchet_state bytea NOT NULL,
    sender_conn_info bytea NOT NULL,
    accepted smallint NOT NULL,
    own_conn_info bytea,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    smp_reply_queues bytea,
    smp_client_version integer
);



CREATE TABLE smp_agent_test_protocol_schema.conn_invitations (
    invitation_id bytea NOT NULL,
    contact_conn_id bytea,
    cr_invitation bytea NOT NULL,
    recipient_conn_info bytea NOT NULL,
    accepted smallint DEFAULT 0 NOT NULL,
    own_conn_info bytea,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);



CREATE TABLE smp_agent_test_protocol_schema.connections (
    conn_id bytea NOT NULL,
    conn_mode text NOT NULL,
    last_internal_msg_id bigint DEFAULT 0 NOT NULL,
    last_internal_rcv_msg_id bigint DEFAULT 0 NOT NULL,
    last_internal_snd_msg_id bigint DEFAULT 0 NOT NULL,
    last_external_snd_msg_id bigint DEFAULT 0 NOT NULL,
    last_rcv_msg_hash bytea DEFAULT '\x'::bytea NOT NULL,
    last_snd_msg_hash bytea DEFAULT '\x'::bytea NOT NULL,
    smp_agent_version integer DEFAULT 1 NOT NULL,
    duplex_handshake smallint DEFAULT 0,
    enable_ntfs smallint,
    deleted smallint DEFAULT 0 NOT NULL,
    user_id bigint NOT NULL,
    ratchet_sync_state text DEFAULT 'ok'::text NOT NULL,
    deleted_at_wait_delivery timestamp with time zone,
    pq_support smallint DEFAULT 0 NOT NULL
);



CREATE TABLE smp_agent_test_protocol_schema.deleted_snd_chunk_replicas (
    deleted_snd_chunk_replica_id bigint NOT NULL,
    user_id bigint NOT NULL,
    xftp_server_id bigint NOT NULL,
    replica_id bytea NOT NULL,
    replica_key bytea NOT NULL,
    chunk_digest bytea NOT NULL,
    delay bigint,
    retries bigint DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    failed smallint DEFAULT 0
);



ALTER TABLE smp_agent_test_protocol_schema.deleted_snd_chunk_replicas ALTER COLUMN deleted_snd_chunk_replica_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME smp_agent_test_protocol_schema.deleted_snd_chunk_replicas_deleted_snd_chunk_replica_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE smp_agent_test_protocol_schema.encrypted_rcv_message_hashes (
    encrypted_rcv_message_hash_id bigint NOT NULL,
    conn_id bytea NOT NULL,
    hash bytea NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);



ALTER TABLE smp_agent_test_protocol_schema.encrypted_rcv_message_hashes ALTER COLUMN encrypted_rcv_message_hash_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME smp_agent_test_protocol_schema.encrypted_rcv_message_hashes_encrypted_rcv_message_hash_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE smp_agent_test_protocol_schema.inv_short_links (
    inv_short_link_id bigint NOT NULL,
    host text NOT NULL,
    port text NOT NULL,
    server_key_hash bytea,
    link_id bytea NOT NULL,
    link_key bytea NOT NULL,
    snd_private_key bytea NOT NULL,
    snd_id bytea
);



ALTER TABLE smp_agent_test_protocol_schema.inv_short_links ALTER COLUMN inv_short_link_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME smp_agent_test_protocol_schema.inv_short_links_inv_short_link_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE smp_agent_test_protocol_schema.messages (
    conn_id bytea NOT NULL,
    internal_id bigint NOT NULL,
    internal_ts timestamp with time zone NOT NULL,
    internal_rcv_id bigint,
    internal_snd_id bigint,
    msg_type bytea NOT NULL,
    msg_body bytea DEFAULT '\x'::bytea NOT NULL,
    msg_flags text,
    pq_encryption smallint DEFAULT 0 NOT NULL
);



CREATE TABLE smp_agent_test_protocol_schema.migrations (
    name text NOT NULL,
    ts timestamp without time zone NOT NULL,
    down text
);



CREATE TABLE smp_agent_test_protocol_schema.ntf_servers (
    ntf_host text NOT NULL,
    ntf_port text NOT NULL,
    ntf_key_hash bytea NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);



CREATE TABLE smp_agent_test_protocol_schema.ntf_subscriptions (
    conn_id bytea NOT NULL,
    smp_host text,
    smp_port text,
    smp_ntf_id bytea,
    ntf_host text NOT NULL,
    ntf_port text NOT NULL,
    ntf_sub_id bytea,
    ntf_sub_status text NOT NULL,
    ntf_sub_action bytea,
    ntf_sub_smp_action bytea,
    ntf_sub_action_ts timestamp with time zone,
    updated_by_supervisor smallint DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    smp_server_key_hash bytea,
    ntf_failed smallint DEFAULT 0,
    smp_failed smallint DEFAULT 0
);



CREATE TABLE smp_agent_test_protocol_schema.ntf_tokens (
    provider text NOT NULL,
    device_token text NOT NULL,
    ntf_host text NOT NULL,
    ntf_port text NOT NULL,
    tkn_id bytea,
    tkn_pub_key bytea NOT NULL,
    tkn_priv_key bytea NOT NULL,
    tkn_pub_dh_key bytea NOT NULL,
    tkn_priv_dh_key bytea NOT NULL,
    tkn_dh_secret bytea,
    tkn_status text NOT NULL,
    tkn_action bytea,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    ntf_mode bytea
);



CREATE TABLE smp_agent_test_protocol_schema.ntf_tokens_to_delete (
    ntf_token_to_delete_id bigint NOT NULL,
    ntf_host text NOT NULL,
    ntf_port text NOT NULL,
    ntf_key_hash bytea NOT NULL,
    tkn_id bytea NOT NULL,
    tkn_priv_key bytea NOT NULL,
    del_failed smallint DEFAULT 0,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);



ALTER TABLE smp_agent_test_protocol_schema.ntf_tokens_to_delete ALTER COLUMN ntf_token_to_delete_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME smp_agent_test_protocol_schema.ntf_tokens_to_delete_ntf_token_to_delete_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE smp_agent_test_protocol_schema.processed_ratchet_key_hashes (
    processed_ratchet_key_hash_id bigint NOT NULL,
    conn_id bytea NOT NULL,
    hash bytea NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);



ALTER TABLE smp_agent_test_protocol_schema.processed_ratchet_key_hashes ALTER COLUMN processed_ratchet_key_hash_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME smp_agent_test_protocol_schema.processed_ratchet_key_hashes_processed_ratchet_key_hash_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE smp_agent_test_protocol_schema.ratchets (
    conn_id bytea NOT NULL,
    x3dh_priv_key_1 bytea,
    x3dh_priv_key_2 bytea,
    ratchet_state bytea,
    e2e_version integer DEFAULT 1 NOT NULL,
    x3dh_pub_key_1 bytea,
    x3dh_pub_key_2 bytea,
    pq_priv_kem bytea,
    pq_pub_kem bytea
);



CREATE TABLE smp_agent_test_protocol_schema.rcv_file_chunk_replicas (
    rcv_file_chunk_replica_id bigint NOT NULL,
    rcv_file_chunk_id bigint NOT NULL,
    replica_number bigint NOT NULL,
    xftp_server_id bigint NOT NULL,
    replica_id bytea NOT NULL,
    replica_key bytea NOT NULL,
    received smallint DEFAULT 0 NOT NULL,
    delay bigint,
    retries bigint DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);



ALTER TABLE smp_agent_test_protocol_schema.rcv_file_chunk_replicas ALTER COLUMN rcv_file_chunk_replica_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME smp_agent_test_protocol_schema.rcv_file_chunk_replicas_rcv_file_chunk_replica_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE smp_agent_test_protocol_schema.rcv_file_chunks (
    rcv_file_chunk_id bigint NOT NULL,
    rcv_file_id bigint NOT NULL,
    chunk_no bigint NOT NULL,
    chunk_size bigint NOT NULL,
    digest bytea NOT NULL,
    tmp_path text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);



ALTER TABLE smp_agent_test_protocol_schema.rcv_file_chunks ALTER COLUMN rcv_file_chunk_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME smp_agent_test_protocol_schema.rcv_file_chunks_rcv_file_chunk_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE smp_agent_test_protocol_schema.rcv_files (
    rcv_file_id bigint NOT NULL,
    rcv_file_entity_id bytea NOT NULL,
    user_id bigint NOT NULL,
    size bigint NOT NULL,
    digest bytea NOT NULL,
    key bytea NOT NULL,
    nonce bytea NOT NULL,
    chunk_size bigint NOT NULL,
    prefix_path text NOT NULL,
    tmp_path text,
    save_path text NOT NULL,
    status text NOT NULL,
    deleted smallint DEFAULT 0 NOT NULL,
    error text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    save_file_key bytea,
    save_file_nonce bytea,
    failed smallint DEFAULT 0,
    redirect_id bigint,
    redirect_entity_id bytea,
    redirect_size bigint,
    redirect_digest bytea,
    approved_relays smallint DEFAULT 0 NOT NULL
);



ALTER TABLE smp_agent_test_protocol_schema.rcv_files ALTER COLUMN rcv_file_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME smp_agent_test_protocol_schema.rcv_files_rcv_file_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE smp_agent_test_protocol_schema.rcv_messages (
    conn_id bytea NOT NULL,
    internal_rcv_id bigint NOT NULL,
    internal_id bigint NOT NULL,
    external_snd_id bigint NOT NULL,
    broker_id bytea NOT NULL,
    broker_ts timestamp with time zone NOT NULL,
    internal_hash bytea NOT NULL,
    external_prev_snd_hash bytea NOT NULL,
    integrity bytea NOT NULL,
    user_ack smallint DEFAULT 0,
    rcv_queue_id bigint NOT NULL
);



CREATE TABLE smp_agent_test_protocol_schema.rcv_queues (
    host text NOT NULL,
    port text NOT NULL,
    rcv_id bytea NOT NULL,
    conn_id bytea NOT NULL,
    rcv_private_key bytea NOT NULL,
    rcv_dh_secret bytea NOT NULL,
    e2e_priv_key bytea NOT NULL,
    e2e_dh_secret bytea,
    snd_id bytea NOT NULL,
    snd_key bytea,
    status text NOT NULL,
    smp_server_version integer DEFAULT 1 NOT NULL,
    smp_client_version integer,
    ntf_public_key bytea,
    ntf_private_key bytea,
    ntf_id bytea,
    rcv_ntf_dh_secret bytea,
    rcv_queue_id bigint NOT NULL,
    rcv_primary smallint NOT NULL,
    replace_rcv_queue_id bigint,
    delete_errors bigint DEFAULT 0 NOT NULL,
    server_key_hash bytea,
    switch_status text,
    deleted smallint DEFAULT 0 NOT NULL,
    last_broker_ts timestamp with time zone,
    link_id bytea,
    link_key bytea,
    link_priv_sig_key bytea,
    link_enc_fixed_data bytea,
    queue_mode text,
    to_subscribe smallint DEFAULT 0 NOT NULL,
    client_notice_id bigint,
    rcv_service_assoc smallint DEFAULT 0 NOT NULL
);



CREATE TABLE smp_agent_test_protocol_schema.servers (
    host text NOT NULL,
    port text NOT NULL,
    key_hash bytea NOT NULL
);



CREATE TABLE smp_agent_test_protocol_schema.servers_stats (
    servers_stats_id bigint NOT NULL,
    servers_stats text,
    started_at timestamp with time zone DEFAULT now() NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);



ALTER TABLE smp_agent_test_protocol_schema.servers_stats ALTER COLUMN servers_stats_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME smp_agent_test_protocol_schema.servers_stats_servers_stats_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE smp_agent_test_protocol_schema.skipped_messages (
    skipped_message_id bigint NOT NULL,
    conn_id bytea NOT NULL,
    header_key bytea NOT NULL,
    msg_n bigint NOT NULL,
    msg_key bytea NOT NULL
);



ALTER TABLE smp_agent_test_protocol_schema.skipped_messages ALTER COLUMN skipped_message_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME smp_agent_test_protocol_schema.skipped_messages_skipped_message_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE smp_agent_test_protocol_schema.snd_file_chunk_replica_recipients (
    snd_file_chunk_replica_recipient_id bigint NOT NULL,
    snd_file_chunk_replica_id bigint NOT NULL,
    rcv_replica_id bytea NOT NULL,
    rcv_replica_key bytea NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);



ALTER TABLE smp_agent_test_protocol_schema.snd_file_chunk_replica_recipients ALTER COLUMN snd_file_chunk_replica_recipient_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME smp_agent_test_protocol_schema.snd_file_chunk_replica_recipi_snd_file_chunk_replica_recipi_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE smp_agent_test_protocol_schema.snd_file_chunk_replicas (
    snd_file_chunk_replica_id bigint NOT NULL,
    snd_file_chunk_id bigint NOT NULL,
    replica_number bigint NOT NULL,
    xftp_server_id bigint NOT NULL,
    replica_id bytea NOT NULL,
    replica_key bytea NOT NULL,
    replica_status text NOT NULL,
    delay bigint,
    retries bigint DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);



ALTER TABLE smp_agent_test_protocol_schema.snd_file_chunk_replicas ALTER COLUMN snd_file_chunk_replica_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME smp_agent_test_protocol_schema.snd_file_chunk_replicas_snd_file_chunk_replica_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE smp_agent_test_protocol_schema.snd_file_chunks (
    snd_file_chunk_id bigint NOT NULL,
    snd_file_id bigint NOT NULL,
    chunk_no bigint NOT NULL,
    chunk_offset bigint NOT NULL,
    chunk_size bigint NOT NULL,
    digest bytea NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);



ALTER TABLE smp_agent_test_protocol_schema.snd_file_chunks ALTER COLUMN snd_file_chunk_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME smp_agent_test_protocol_schema.snd_file_chunks_snd_file_chunk_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE smp_agent_test_protocol_schema.snd_files (
    snd_file_id bigint NOT NULL,
    snd_file_entity_id bytea NOT NULL,
    user_id bigint NOT NULL,
    num_recipients bigint NOT NULL,
    digest bytea,
    key bytea NOT NULL,
    nonce bytea NOT NULL,
    path text NOT NULL,
    prefix_path text,
    status text NOT NULL,
    deleted smallint DEFAULT 0 NOT NULL,
    error text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    src_file_key bytea,
    src_file_nonce bytea,
    failed smallint DEFAULT 0,
    redirect_size bigint,
    redirect_digest bytea
);



ALTER TABLE smp_agent_test_protocol_schema.snd_files ALTER COLUMN snd_file_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME smp_agent_test_protocol_schema.snd_files_snd_file_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE smp_agent_test_protocol_schema.snd_message_bodies (
    snd_message_body_id bigint NOT NULL,
    agent_msg bytea DEFAULT '\x'::bytea NOT NULL
);



ALTER TABLE smp_agent_test_protocol_schema.snd_message_bodies ALTER COLUMN snd_message_body_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME smp_agent_test_protocol_schema.snd_message_bodies_snd_message_body_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE smp_agent_test_protocol_schema.snd_message_deliveries (
    snd_message_delivery_id bigint NOT NULL,
    conn_id bytea NOT NULL,
    snd_queue_id bigint NOT NULL,
    internal_id bigint NOT NULL,
    failed smallint DEFAULT 0
);



ALTER TABLE smp_agent_test_protocol_schema.snd_message_deliveries ALTER COLUMN snd_message_delivery_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME smp_agent_test_protocol_schema.snd_message_deliveries_snd_message_delivery_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE smp_agent_test_protocol_schema.snd_messages (
    conn_id bytea NOT NULL,
    internal_snd_id bigint NOT NULL,
    internal_id bigint NOT NULL,
    internal_hash bytea NOT NULL,
    previous_msg_hash bytea DEFAULT '\x'::bytea NOT NULL,
    retry_int_slow bigint,
    retry_int_fast bigint,
    rcpt_internal_id bigint,
    rcpt_status text,
    msg_encrypt_key bytea,
    padded_msg_len bigint,
    snd_message_body_id bigint
);



CREATE TABLE smp_agent_test_protocol_schema.snd_queues (
    host text NOT NULL,
    port text NOT NULL,
    snd_id bytea NOT NULL,
    conn_id bytea NOT NULL,
    snd_private_key bytea NOT NULL,
    e2e_dh_secret bytea NOT NULL,
    status text NOT NULL,
    smp_server_version integer DEFAULT 1 NOT NULL,
    smp_client_version integer DEFAULT 1 NOT NULL,
    snd_public_key bytea,
    e2e_pub_key bytea,
    snd_queue_id bigint NOT NULL,
    snd_primary smallint NOT NULL,
    replace_snd_queue_id bigint,
    server_key_hash bytea,
    switch_status text,
    queue_mode text
);



CREATE TABLE smp_agent_test_protocol_schema.users (
    user_id bigint NOT NULL,
    deleted smallint DEFAULT 0 NOT NULL
);



ALTER TABLE smp_agent_test_protocol_schema.users ALTER COLUMN user_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME smp_agent_test_protocol_schema.users_user_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE smp_agent_test_protocol_schema.xftp_servers (
    xftp_server_id bigint NOT NULL,
    xftp_host text NOT NULL,
    xftp_port text NOT NULL,
    xftp_key_hash bytea NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);



ALTER TABLE smp_agent_test_protocol_schema.xftp_servers ALTER COLUMN xftp_server_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME smp_agent_test_protocol_schema.xftp_servers_xftp_server_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



ALTER TABLE ONLY smp_agent_test_protocol_schema.client_notices
    ADD CONSTRAINT client_notices_pkey PRIMARY KEY (client_notice_id);



ALTER TABLE ONLY smp_agent_test_protocol_schema.commands
    ADD CONSTRAINT commands_pkey PRIMARY KEY (command_id);



ALTER TABLE ONLY smp_agent_test_protocol_schema.conn_confirmations
    ADD CONSTRAINT conn_confirmations_pkey PRIMARY KEY (confirmation_id);



ALTER TABLE ONLY smp_agent_test_protocol_schema.conn_invitations
    ADD CONSTRAINT conn_invitations_pkey PRIMARY KEY (invitation_id);



ALTER TABLE ONLY smp_agent_test_protocol_schema.connections
    ADD CONSTRAINT connections_pkey PRIMARY KEY (conn_id);



ALTER TABLE ONLY smp_agent_test_protocol_schema.deleted_snd_chunk_replicas
    ADD CONSTRAINT deleted_snd_chunk_replicas_pkey PRIMARY KEY (deleted_snd_chunk_replica_id);



ALTER TABLE ONLY smp_agent_test_protocol_schema.encrypted_rcv_message_hashes
    ADD CONSTRAINT encrypted_rcv_message_hashes_pkey PRIMARY KEY (encrypted_rcv_message_hash_id);



ALTER TABLE ONLY smp_agent_test_protocol_schema.inv_short_links
    ADD CONSTRAINT inv_short_links_pkey PRIMARY KEY (inv_short_link_id);



ALTER TABLE ONLY smp_agent_test_protocol_schema.messages
    ADD CONSTRAINT messages_pkey PRIMARY KEY (conn_id, internal_id);



ALTER TABLE ONLY smp_agent_test_protocol_schema.migrations
    ADD CONSTRAINT migrations_pkey PRIMARY KEY (name);



ALTER TABLE ONLY smp_agent_test_protocol_schema.ntf_servers
    ADD CONSTRAINT ntf_servers_pkey PRIMARY KEY (ntf_host, ntf_port);



ALTER TABLE ONLY smp_agent_test_protocol_schema.ntf_subscriptions
    ADD CONSTRAINT ntf_subscriptions_pkey PRIMARY KEY (conn_id);



ALTER TABLE ONLY smp_agent_test_protocol_schema.ntf_tokens
    ADD CONSTRAINT ntf_tokens_pkey PRIMARY KEY (provider, device_token, ntf_host, ntf_port);



ALTER TABLE ONLY smp_agent_test_protocol_schema.ntf_tokens_to_delete
    ADD CONSTRAINT ntf_tokens_to_delete_pkey PRIMARY KEY (ntf_token_to_delete_id);



ALTER TABLE ONLY smp_agent_test_protocol_schema.processed_ratchet_key_hashes
    ADD CONSTRAINT processed_ratchet_key_hashes_pkey PRIMARY KEY (processed_ratchet_key_hash_id);



ALTER TABLE ONLY smp_agent_test_protocol_schema.ratchets
    ADD CONSTRAINT ratchets_pkey PRIMARY KEY (conn_id);



ALTER TABLE ONLY smp_agent_test_protocol_schema.rcv_file_chunk_replicas
    ADD CONSTRAINT rcv_file_chunk_replicas_pkey PRIMARY KEY (rcv_file_chunk_replica_id);



ALTER TABLE ONLY smp_agent_test_protocol_schema.rcv_file_chunks
    ADD CONSTRAINT rcv_file_chunks_pkey PRIMARY KEY (rcv_file_chunk_id);



ALTER TABLE ONLY smp_agent_test_protocol_schema.rcv_files
    ADD CONSTRAINT rcv_files_pkey PRIMARY KEY (rcv_file_id);



ALTER TABLE ONLY smp_agent_test_protocol_schema.rcv_files
    ADD CONSTRAINT rcv_files_rcv_file_entity_id_key UNIQUE (rcv_file_entity_id);



ALTER TABLE ONLY smp_agent_test_protocol_schema.rcv_messages
    ADD CONSTRAINT rcv_messages_pkey PRIMARY KEY (conn_id, internal_rcv_id);



ALTER TABLE ONLY smp_agent_test_protocol_schema.rcv_queues
    ADD CONSTRAINT rcv_queues_host_port_snd_id_key UNIQUE (host, port, snd_id);



ALTER TABLE ONLY smp_agent_test_protocol_schema.rcv_queues
    ADD CONSTRAINT rcv_queues_pkey PRIMARY KEY (host, port, rcv_id);



ALTER TABLE ONLY smp_agent_test_protocol_schema.servers
    ADD CONSTRAINT servers_pkey PRIMARY KEY (host, port);



ALTER TABLE ONLY smp_agent_test_protocol_schema.servers_stats
    ADD CONSTRAINT servers_stats_pkey PRIMARY KEY (servers_stats_id);



ALTER TABLE ONLY smp_agent_test_protocol_schema.skipped_messages
    ADD CONSTRAINT skipped_messages_pkey PRIMARY KEY (skipped_message_id);



ALTER TABLE ONLY smp_agent_test_protocol_schema.snd_file_chunk_replica_recipients
    ADD CONSTRAINT snd_file_chunk_replica_recipients_pkey PRIMARY KEY (snd_file_chunk_replica_recipient_id);



ALTER TABLE ONLY smp_agent_test_protocol_schema.snd_file_chunk_replicas
    ADD CONSTRAINT snd_file_chunk_replicas_pkey PRIMARY KEY (snd_file_chunk_replica_id);



ALTER TABLE ONLY smp_agent_test_protocol_schema.snd_file_chunks
    ADD CONSTRAINT snd_file_chunks_pkey PRIMARY KEY (snd_file_chunk_id);



ALTER TABLE ONLY smp_agent_test_protocol_schema.snd_files
    ADD CONSTRAINT snd_files_pkey PRIMARY KEY (snd_file_id);



ALTER TABLE ONLY smp_agent_test_protocol_schema.snd_message_bodies
    ADD CONSTRAINT snd_message_bodies_pkey PRIMARY KEY (snd_message_body_id);



ALTER TABLE ONLY smp_agent_test_protocol_schema.snd_message_deliveries
    ADD CONSTRAINT snd_message_deliveries_pkey PRIMARY KEY (snd_message_delivery_id);



ALTER TABLE ONLY smp_agent_test_protocol_schema.snd_messages
    ADD CONSTRAINT snd_messages_pkey PRIMARY KEY (conn_id, internal_snd_id);



ALTER TABLE ONLY smp_agent_test_protocol_schema.snd_queues
    ADD CONSTRAINT snd_queues_pkey PRIMARY KEY (host, port, snd_id);



ALTER TABLE ONLY smp_agent_test_protocol_schema.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (user_id);



ALTER TABLE ONLY smp_agent_test_protocol_schema.xftp_servers
    ADD CONSTRAINT xftp_servers_pkey PRIMARY KEY (xftp_server_id);



ALTER TABLE ONLY smp_agent_test_protocol_schema.xftp_servers
    ADD CONSTRAINT xftp_servers_xftp_host_xftp_port_xftp_key_hash_key UNIQUE (xftp_host, xftp_port, xftp_key_hash);



CREATE UNIQUE INDEX idx_client_notices_entity ON smp_agent_test_protocol_schema.client_notices USING btree (protocol, host, port, entity_id);



CREATE INDEX idx_commands_conn_id ON smp_agent_test_protocol_schema.commands USING btree (conn_id);



CREATE INDEX idx_commands_host_port ON smp_agent_test_protocol_schema.commands USING btree (host, port);



CREATE INDEX idx_commands_server_commands ON smp_agent_test_protocol_schema.commands USING btree (host, port, created_at, command_id);



CREATE INDEX idx_conn_confirmations_conn_id ON smp_agent_test_protocol_schema.conn_confirmations USING btree (conn_id);



CREATE INDEX idx_conn_invitations_contact_conn_id ON smp_agent_test_protocol_schema.conn_invitations USING btree (contact_conn_id);



CREATE INDEX idx_connections_user ON smp_agent_test_protocol_schema.connections USING btree (user_id);



CREATE INDEX idx_deleted_snd_chunk_replicas_pending ON smp_agent_test_protocol_schema.deleted_snd_chunk_replicas USING btree (created_at);



CREATE INDEX idx_deleted_snd_chunk_replicas_user_id ON smp_agent_test_protocol_schema.deleted_snd_chunk_replicas USING btree (user_id);



CREATE INDEX idx_deleted_snd_chunk_replicas_xftp_server_id ON smp_agent_test_protocol_schema.deleted_snd_chunk_replicas USING btree (xftp_server_id);



CREATE INDEX idx_encrypted_rcv_message_hashes_created_at ON smp_agent_test_protocol_schema.encrypted_rcv_message_hashes USING btree (created_at);



CREATE INDEX idx_encrypted_rcv_message_hashes_hash ON smp_agent_test_protocol_schema.encrypted_rcv_message_hashes USING btree (conn_id, hash);



CREATE UNIQUE INDEX idx_inv_short_links_link_id ON smp_agent_test_protocol_schema.inv_short_links USING btree (host, port, link_id);



CREATE INDEX idx_messages_conn_id ON smp_agent_test_protocol_schema.messages USING btree (conn_id);



CREATE INDEX idx_messages_conn_id_internal_rcv_id ON smp_agent_test_protocol_schema.messages USING btree (conn_id, internal_rcv_id);



CREATE INDEX idx_messages_conn_id_internal_snd_id ON smp_agent_test_protocol_schema.messages USING btree (conn_id, internal_snd_id);



CREATE INDEX idx_messages_internal_ts ON smp_agent_test_protocol_schema.messages USING btree (internal_ts);



CREATE INDEX idx_messages_snd_expired ON smp_agent_test_protocol_schema.messages USING btree (conn_id, internal_snd_id, internal_ts);



CREATE INDEX idx_ntf_subscriptions_ntf_host_ntf_port ON smp_agent_test_protocol_schema.ntf_subscriptions USING btree (ntf_host, ntf_port);



CREATE INDEX idx_ntf_subscriptions_smp_host_smp_port ON smp_agent_test_protocol_schema.ntf_subscriptions USING btree (smp_host, smp_port);



CREATE INDEX idx_ntf_tokens_ntf_host_ntf_port ON smp_agent_test_protocol_schema.ntf_tokens USING btree (ntf_host, ntf_port);



CREATE INDEX idx_processed_ratchet_key_hashes_created_at ON smp_agent_test_protocol_schema.processed_ratchet_key_hashes USING btree (created_at);



CREATE INDEX idx_processed_ratchet_key_hashes_hash ON smp_agent_test_protocol_schema.processed_ratchet_key_hashes USING btree (conn_id, hash);



CREATE INDEX idx_ratchets_conn_id ON smp_agent_test_protocol_schema.ratchets USING btree (conn_id);



CREATE INDEX idx_rcv_file_chunk_replicas_pending ON smp_agent_test_protocol_schema.rcv_file_chunk_replicas USING btree (received, replica_number);



CREATE INDEX idx_rcv_file_chunk_replicas_rcv_file_chunk_id ON smp_agent_test_protocol_schema.rcv_file_chunk_replicas USING btree (rcv_file_chunk_id);



CREATE INDEX idx_rcv_file_chunk_replicas_xftp_server_id ON smp_agent_test_protocol_schema.rcv_file_chunk_replicas USING btree (xftp_server_id);



CREATE INDEX idx_rcv_file_chunks_rcv_file_id ON smp_agent_test_protocol_schema.rcv_file_chunks USING btree (rcv_file_id);



CREATE INDEX idx_rcv_files_redirect_id ON smp_agent_test_protocol_schema.rcv_files USING btree (redirect_id);



CREATE INDEX idx_rcv_files_status_created_at ON smp_agent_test_protocol_schema.rcv_files USING btree (status, created_at);



CREATE INDEX idx_rcv_files_user_id ON smp_agent_test_protocol_schema.rcv_files USING btree (user_id);



CREATE INDEX idx_rcv_messages_conn_id_internal_id ON smp_agent_test_protocol_schema.rcv_messages USING btree (conn_id, internal_id);



CREATE UNIQUE INDEX idx_rcv_queue_id ON smp_agent_test_protocol_schema.rcv_queues USING btree (conn_id, rcv_queue_id);



CREATE INDEX idx_rcv_queues_client_notice_id ON smp_agent_test_protocol_schema.rcv_queues USING btree (client_notice_id);



CREATE UNIQUE INDEX idx_rcv_queues_link_id ON smp_agent_test_protocol_schema.rcv_queues USING btree (host, port, link_id);



CREATE UNIQUE INDEX idx_rcv_queues_ntf ON smp_agent_test_protocol_schema.rcv_queues USING btree (host, port, ntf_id);



CREATE INDEX idx_rcv_queues_to_subscribe ON smp_agent_test_protocol_schema.rcv_queues USING btree (to_subscribe);



CREATE INDEX idx_server_certs_host_port ON smp_agent_test_protocol_schema.client_services USING btree (host, port);



CREATE UNIQUE INDEX idx_server_certs_user_id_host_port ON smp_agent_test_protocol_schema.client_services USING btree (user_id, host, port, server_key_hash);



CREATE INDEX idx_skipped_messages_conn_id ON smp_agent_test_protocol_schema.skipped_messages USING btree (conn_id);



CREATE INDEX idx_snd_file_chunk_replica_recipients_snd_file_chunk_replica_id ON smp_agent_test_protocol_schema.snd_file_chunk_replica_recipients USING btree (snd_file_chunk_replica_id);



CREATE INDEX idx_snd_file_chunk_replicas_pending ON smp_agent_test_protocol_schema.snd_file_chunk_replicas USING btree (replica_status, replica_number);



CREATE INDEX idx_snd_file_chunk_replicas_snd_file_chunk_id ON smp_agent_test_protocol_schema.snd_file_chunk_replicas USING btree (snd_file_chunk_id);



CREATE INDEX idx_snd_file_chunk_replicas_xftp_server_id ON smp_agent_test_protocol_schema.snd_file_chunk_replicas USING btree (xftp_server_id);



CREATE INDEX idx_snd_file_chunks_snd_file_id ON smp_agent_test_protocol_schema.snd_file_chunks USING btree (snd_file_id);



CREATE INDEX idx_snd_files_snd_file_entity_id ON smp_agent_test_protocol_schema.snd_files USING btree (snd_file_entity_id);



CREATE INDEX idx_snd_files_status_created_at ON smp_agent_test_protocol_schema.snd_files USING btree (status, created_at);



CREATE INDEX idx_snd_files_user_id ON smp_agent_test_protocol_schema.snd_files USING btree (user_id);



CREATE INDEX idx_snd_message_deliveries ON smp_agent_test_protocol_schema.snd_message_deliveries USING btree (conn_id, snd_queue_id);



CREATE INDEX idx_snd_message_deliveries_conn_id_internal_id ON smp_agent_test_protocol_schema.snd_message_deliveries USING btree (conn_id, internal_id);



CREATE INDEX idx_snd_message_deliveries_expired ON smp_agent_test_protocol_schema.snd_message_deliveries USING btree (conn_id, snd_queue_id, failed, internal_id);



CREATE INDEX idx_snd_messages_conn_id_internal_id ON smp_agent_test_protocol_schema.snd_messages USING btree (conn_id, internal_id);



CREATE INDEX idx_snd_messages_rcpt_internal_id ON smp_agent_test_protocol_schema.snd_messages USING btree (conn_id, rcpt_internal_id);



CREATE INDEX idx_snd_messages_snd_message_body_id ON smp_agent_test_protocol_schema.snd_messages USING btree (snd_message_body_id);



CREATE UNIQUE INDEX idx_snd_queue_id ON smp_agent_test_protocol_schema.snd_queues USING btree (conn_id, snd_queue_id);



CREATE INDEX idx_snd_queues_host_port ON smp_agent_test_protocol_schema.snd_queues USING btree (host, port);



CREATE TRIGGER tr_rcv_queue_delete AFTER DELETE ON smp_agent_test_protocol_schema.rcv_queues FOR EACH ROW EXECUTE FUNCTION smp_agent_test_protocol_schema.on_rcv_queue_delete();



CREATE TRIGGER tr_rcv_queue_insert AFTER INSERT ON smp_agent_test_protocol_schema.rcv_queues FOR EACH ROW EXECUTE FUNCTION smp_agent_test_protocol_schema.on_rcv_queue_insert();



CREATE TRIGGER tr_rcv_queue_update AFTER UPDATE ON smp_agent_test_protocol_schema.rcv_queues FOR EACH ROW EXECUTE FUNCTION smp_agent_test_protocol_schema.on_rcv_queue_update();



ALTER TABLE ONLY smp_agent_test_protocol_schema.client_services
    ADD CONSTRAINT client_services_host_port_fkey FOREIGN KEY (host, port) REFERENCES smp_agent_test_protocol_schema.servers(host, port) ON UPDATE CASCADE ON DELETE RESTRICT;



ALTER TABLE ONLY smp_agent_test_protocol_schema.client_services
    ADD CONSTRAINT client_services_user_id_fkey FOREIGN KEY (user_id) REFERENCES smp_agent_test_protocol_schema.users(user_id) ON UPDATE RESTRICT ON DELETE CASCADE;



ALTER TABLE ONLY smp_agent_test_protocol_schema.commands
    ADD CONSTRAINT commands_conn_id_fkey FOREIGN KEY (conn_id) REFERENCES smp_agent_test_protocol_schema.connections(conn_id) ON DELETE CASCADE;



ALTER TABLE ONLY smp_agent_test_protocol_schema.commands
    ADD CONSTRAINT commands_host_port_fkey FOREIGN KEY (host, port) REFERENCES smp_agent_test_protocol_schema.servers(host, port) ON UPDATE CASCADE ON DELETE RESTRICT;



ALTER TABLE ONLY smp_agent_test_protocol_schema.conn_confirmations
    ADD CONSTRAINT conn_confirmations_conn_id_fkey FOREIGN KEY (conn_id) REFERENCES smp_agent_test_protocol_schema.connections(conn_id) ON DELETE CASCADE;



ALTER TABLE ONLY smp_agent_test_protocol_schema.conn_invitations
    ADD CONSTRAINT conn_invitations_contact_conn_id_fkey FOREIGN KEY (contact_conn_id) REFERENCES smp_agent_test_protocol_schema.connections(conn_id) ON DELETE SET NULL;



ALTER TABLE ONLY smp_agent_test_protocol_schema.connections
    ADD CONSTRAINT connections_user_id_fkey FOREIGN KEY (user_id) REFERENCES smp_agent_test_protocol_schema.users(user_id) ON DELETE CASCADE;



ALTER TABLE ONLY smp_agent_test_protocol_schema.deleted_snd_chunk_replicas
    ADD CONSTRAINT deleted_snd_chunk_replicas_user_id_fkey FOREIGN KEY (user_id) REFERENCES smp_agent_test_protocol_schema.users(user_id) ON DELETE CASCADE;



ALTER TABLE ONLY smp_agent_test_protocol_schema.deleted_snd_chunk_replicas
    ADD CONSTRAINT deleted_snd_chunk_replicas_xftp_server_id_fkey FOREIGN KEY (xftp_server_id) REFERENCES smp_agent_test_protocol_schema.xftp_servers(xftp_server_id) ON DELETE CASCADE;



ALTER TABLE ONLY smp_agent_test_protocol_schema.encrypted_rcv_message_hashes
    ADD CONSTRAINT encrypted_rcv_message_hashes_conn_id_fkey FOREIGN KEY (conn_id) REFERENCES smp_agent_test_protocol_schema.connections(conn_id) ON DELETE CASCADE;



ALTER TABLE ONLY smp_agent_test_protocol_schema.messages
    ADD CONSTRAINT fk_messages_rcv_messages FOREIGN KEY (conn_id, internal_rcv_id) REFERENCES smp_agent_test_protocol_schema.rcv_messages(conn_id, internal_rcv_id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;



ALTER TABLE ONLY smp_agent_test_protocol_schema.messages
    ADD CONSTRAINT fk_messages_snd_messages FOREIGN KEY (conn_id, internal_snd_id) REFERENCES smp_agent_test_protocol_schema.snd_messages(conn_id, internal_snd_id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;



ALTER TABLE ONLY smp_agent_test_protocol_schema.inv_short_links
    ADD CONSTRAINT inv_short_links_host_port_fkey FOREIGN KEY (host, port) REFERENCES smp_agent_test_protocol_schema.servers(host, port) ON UPDATE CASCADE ON DELETE RESTRICT;



ALTER TABLE ONLY smp_agent_test_protocol_schema.messages
    ADD CONSTRAINT messages_conn_id_fkey FOREIGN KEY (conn_id) REFERENCES smp_agent_test_protocol_schema.connections(conn_id) ON DELETE CASCADE;



ALTER TABLE ONLY smp_agent_test_protocol_schema.ntf_subscriptions
    ADD CONSTRAINT ntf_subscriptions_ntf_host_ntf_port_fkey FOREIGN KEY (ntf_host, ntf_port) REFERENCES smp_agent_test_protocol_schema.ntf_servers(ntf_host, ntf_port) ON UPDATE CASCADE ON DELETE RESTRICT;



ALTER TABLE ONLY smp_agent_test_protocol_schema.ntf_subscriptions
    ADD CONSTRAINT ntf_subscriptions_smp_host_smp_port_fkey FOREIGN KEY (smp_host, smp_port) REFERENCES smp_agent_test_protocol_schema.servers(host, port) ON UPDATE CASCADE ON DELETE SET NULL;



ALTER TABLE ONLY smp_agent_test_protocol_schema.ntf_tokens
    ADD CONSTRAINT ntf_tokens_ntf_host_ntf_port_fkey FOREIGN KEY (ntf_host, ntf_port) REFERENCES smp_agent_test_protocol_schema.ntf_servers(ntf_host, ntf_port) ON UPDATE CASCADE ON DELETE RESTRICT;



ALTER TABLE ONLY smp_agent_test_protocol_schema.processed_ratchet_key_hashes
    ADD CONSTRAINT processed_ratchet_key_hashes_conn_id_fkey FOREIGN KEY (conn_id) REFERENCES smp_agent_test_protocol_schema.connections(conn_id) ON DELETE CASCADE;



ALTER TABLE ONLY smp_agent_test_protocol_schema.ratchets
    ADD CONSTRAINT ratchets_conn_id_fkey FOREIGN KEY (conn_id) REFERENCES smp_agent_test_protocol_schema.connections(conn_id) ON DELETE CASCADE;



ALTER TABLE ONLY smp_agent_test_protocol_schema.rcv_file_chunk_replicas
    ADD CONSTRAINT rcv_file_chunk_replicas_rcv_file_chunk_id_fkey FOREIGN KEY (rcv_file_chunk_id) REFERENCES smp_agent_test_protocol_schema.rcv_file_chunks(rcv_file_chunk_id) ON DELETE CASCADE;



ALTER TABLE ONLY smp_agent_test_protocol_schema.rcv_file_chunk_replicas
    ADD CONSTRAINT rcv_file_chunk_replicas_xftp_server_id_fkey FOREIGN KEY (xftp_server_id) REFERENCES smp_agent_test_protocol_schema.xftp_servers(xftp_server_id) ON DELETE CASCADE;



ALTER TABLE ONLY smp_agent_test_protocol_schema.rcv_file_chunks
    ADD CONSTRAINT rcv_file_chunks_rcv_file_id_fkey FOREIGN KEY (rcv_file_id) REFERENCES smp_agent_test_protocol_schema.rcv_files(rcv_file_id) ON DELETE CASCADE;



ALTER TABLE ONLY smp_agent_test_protocol_schema.rcv_files
    ADD CONSTRAINT rcv_files_redirect_id_fkey FOREIGN KEY (redirect_id) REFERENCES smp_agent_test_protocol_schema.rcv_files(rcv_file_id) ON DELETE SET NULL;



ALTER TABLE ONLY smp_agent_test_protocol_schema.rcv_files
    ADD CONSTRAINT rcv_files_user_id_fkey FOREIGN KEY (user_id) REFERENCES smp_agent_test_protocol_schema.users(user_id) ON DELETE CASCADE;



ALTER TABLE ONLY smp_agent_test_protocol_schema.rcv_messages
    ADD CONSTRAINT rcv_messages_conn_id_internal_id_fkey FOREIGN KEY (conn_id, internal_id) REFERENCES smp_agent_test_protocol_schema.messages(conn_id, internal_id) ON DELETE CASCADE;



ALTER TABLE ONLY smp_agent_test_protocol_schema.rcv_queues
    ADD CONSTRAINT rcv_queues_client_notice_id_fkey FOREIGN KEY (client_notice_id) REFERENCES smp_agent_test_protocol_schema.client_notices(client_notice_id) ON UPDATE RESTRICT ON DELETE SET NULL;



ALTER TABLE ONLY smp_agent_test_protocol_schema.rcv_queues
    ADD CONSTRAINT rcv_queues_conn_id_fkey FOREIGN KEY (conn_id) REFERENCES smp_agent_test_protocol_schema.connections(conn_id) ON DELETE CASCADE;



ALTER TABLE ONLY smp_agent_test_protocol_schema.rcv_queues
    ADD CONSTRAINT rcv_queues_host_port_fkey FOREIGN KEY (host, port) REFERENCES smp_agent_test_protocol_schema.servers(host, port) ON UPDATE CASCADE ON DELETE RESTRICT;



ALTER TABLE ONLY smp_agent_test_protocol_schema.skipped_messages
    ADD CONSTRAINT skipped_messages_conn_id_fkey FOREIGN KEY (conn_id) REFERENCES smp_agent_test_protocol_schema.ratchets(conn_id) ON DELETE CASCADE;



ALTER TABLE ONLY smp_agent_test_protocol_schema.snd_file_chunk_replica_recipients
    ADD CONSTRAINT snd_file_chunk_replica_recipient_snd_file_chunk_replica_id_fkey FOREIGN KEY (snd_file_chunk_replica_id) REFERENCES smp_agent_test_protocol_schema.snd_file_chunk_replicas(snd_file_chunk_replica_id) ON DELETE CASCADE;



ALTER TABLE ONLY smp_agent_test_protocol_schema.snd_file_chunk_replicas
    ADD CONSTRAINT snd_file_chunk_replicas_snd_file_chunk_id_fkey FOREIGN KEY (snd_file_chunk_id) REFERENCES smp_agent_test_protocol_schema.snd_file_chunks(snd_file_chunk_id) ON DELETE CASCADE;



ALTER TABLE ONLY smp_agent_test_protocol_schema.snd_file_chunk_replicas
    ADD CONSTRAINT snd_file_chunk_replicas_xftp_server_id_fkey FOREIGN KEY (xftp_server_id) REFERENCES smp_agent_test_protocol_schema.xftp_servers(xftp_server_id) ON DELETE CASCADE;



ALTER TABLE ONLY smp_agent_test_protocol_schema.snd_file_chunks
    ADD CONSTRAINT snd_file_chunks_snd_file_id_fkey FOREIGN KEY (snd_file_id) REFERENCES smp_agent_test_protocol_schema.snd_files(snd_file_id) ON DELETE CASCADE;



ALTER TABLE ONLY smp_agent_test_protocol_schema.snd_files
    ADD CONSTRAINT snd_files_user_id_fkey FOREIGN KEY (user_id) REFERENCES smp_agent_test_protocol_schema.users(user_id) ON DELETE CASCADE;



ALTER TABLE ONLY smp_agent_test_protocol_schema.snd_message_deliveries
    ADD CONSTRAINT snd_message_deliveries_conn_id_fkey FOREIGN KEY (conn_id) REFERENCES smp_agent_test_protocol_schema.connections(conn_id) ON DELETE CASCADE;



ALTER TABLE ONLY smp_agent_test_protocol_schema.snd_message_deliveries
    ADD CONSTRAINT snd_message_deliveries_conn_id_internal_id_fkey FOREIGN KEY (conn_id, internal_id) REFERENCES smp_agent_test_protocol_schema.messages(conn_id, internal_id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;



ALTER TABLE ONLY smp_agent_test_protocol_schema.snd_messages
    ADD CONSTRAINT snd_messages_conn_id_internal_id_fkey FOREIGN KEY (conn_id, internal_id) REFERENCES smp_agent_test_protocol_schema.messages(conn_id, internal_id) ON DELETE CASCADE;



ALTER TABLE ONLY smp_agent_test_protocol_schema.snd_messages
    ADD CONSTRAINT snd_messages_snd_message_body_id_fkey FOREIGN KEY (snd_message_body_id) REFERENCES smp_agent_test_protocol_schema.snd_message_bodies(snd_message_body_id) ON DELETE SET NULL;



ALTER TABLE ONLY smp_agent_test_protocol_schema.snd_queues
    ADD CONSTRAINT snd_queues_conn_id_fkey FOREIGN KEY (conn_id) REFERENCES smp_agent_test_protocol_schema.connections(conn_id) ON DELETE CASCADE;



ALTER TABLE ONLY smp_agent_test_protocol_schema.snd_queues
    ADD CONSTRAINT snd_queues_host_port_fkey FOREIGN KEY (host, port) REFERENCES smp_agent_test_protocol_schema.servers(host, port) ON UPDATE CASCADE ON DELETE RESTRICT;



