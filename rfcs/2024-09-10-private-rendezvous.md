# Private rendezvous protocol

## Problem

Our current handshake protocol is open to this attack: whoever observes the link exchange, knows on which server connection is being made, and if the traffic on this server is observed, then it can confirm communication between parties. Further, even with the [last proposal](./2024-09-09-smp-blobs.md#possible-privacy-improvement), having real-time access to the server data allows to establish the exact messaging queue that is used to send messages.

## Solution

We could make the initial link exchange more private by making it harder for any observer to discover which server will be used for messaging by hiding this information from the server that hosts the initial link.

Preliminary, the protocol could be the following:

1. Connection initiator stores 224-256 bytes of encrypted connection link on a rendezvous server (link contains server host and linkId on another messaging server, not a rendezvous one).

2. Rendezvous server adds these links to buckets, up to 64 links per bucket. Bucket ID is the timestamp when the bucket was created + a sequential bucket number, in case more than one bucket is created per second.

3. The server responds to the link creator with a bucket ID where this link was added. That bucket ID is its timestamp + a number prevents server "fingerprinting" clients and using say one bucket for each client. If timestamp is different or a bucket number within this timestamp is too large, the client can refuse to use it, depending on the client settings.

4. The initiating party will pass to the accepting party the rendezvous server host, the hash of this bucket ID (bucket link) and the passphrase to derive the key from. The initiating party has an option to pass a link and passphrase via two channels - in which case the link will only contain the bucket ID.

5. The accepting party would then request the bucket via its ID hash (the server would store hashes to be able to look up - hash is used to prevent showing time in the link) and attempt to decrypt all contained links using the provided key.
The accepting party then will continue the connection via the decrypted link.

This obviously does not protect accepting party from the initiating party, if it can choose rendezvous server it controls. It also does not protect from the malicious rendezvous server that would collaborate with link observers. I think reunion doesn’t protect from it too.

But it does protect connection from whoever observes the link, particularly if this link only contains the bucket and the key is passed separately, via some other channel.
