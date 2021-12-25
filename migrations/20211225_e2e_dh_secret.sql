ALTER TABLE rcv_queues ADD e2e_private_dh_key BLOB;
ALTER TABLE rcv_queues ADD e2e_dh_secret BLOB;

ALTER TABLE snd_queues ADD e2e_public_dh_key BLOB;
ALTER TABLE snd_queues ADD e2e_dh_secret BLOB;
