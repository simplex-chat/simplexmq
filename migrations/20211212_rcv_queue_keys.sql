ALTER TABLE rcv_queues ADD rcv_srv_verify_key BLOB NOT NULL;
ALTER TABLE rcv_queues ADD rcv_dh_secret BLOB NOT NULL;
ALTER TABLE rcv_queues ADD snd_srv_verify_key BLOB NOT NULL;
