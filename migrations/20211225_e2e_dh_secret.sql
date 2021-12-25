ALTER TABLE rcv_queues ADD e2e_priv_dh_key BLOB;
ALTER TABLE rcv_queues ADD e2e_dh_secret BLOB;

ALTER TABLE snd_queues ADD e2e_pub_dh_key BLOB;
ALTER TABLE snd_queues ADD e2e_dh_secret BLOB;

ALTER TABLE conn_confirmations ADD e2e_pub_dh_key BLOB;
