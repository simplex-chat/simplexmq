# Repudiation for message senders

## Problem

We use double ratchet protocol to send messages. One of its important qualities is the use of symmetric encryption with forward secrecy, when the new key to encrypt the message is rotated after each message. This provides senders ability to plausibly deny having sent some messages, without denying having sent others. While the recipients can prove to themselves that the message was indeed sent by the sender, because it was encrypted using authenticated encryption with associated data, the recipients cannot prove it to any third party - as the message could have been encrypted by themselves, as they also have the same symmetric keys.

To receive the messages, the recipients agree a message queue with the senders, and the commands sent to this queue are signed by the senders using the cryptographic key (Edwards curve key) of which the public counterpart was shared with the recipient in the confirmation message of SMP protocol (this confirmation message itself is not signed).

While it was never claimed that the messaging protocol provides deniability, the deniability is often mentioned as one of the important qualities of double ratchet algorithm used in the innermost layer of e2e encryption, so without explicit disclaimer of deniability limitations, it may be assumed by the users that the system as a whole provides the same level of deniability as the double ratchet algorithm, which currently is not the case.

While societal understanding and legal acceptance of repudiation is arguable, there was less than a decade since this quality became widely available in Signal - legal systems take longer to evolve.  While the argument that the message was forged is unlikely to be accepted in the usual court cases with the ordinary people, it is likely to be considered in cases with high profile defendants, who can reasonably claim that they are the target of smear campaign and are being attributed something that they never sent - the statement that the message is forged is reasonable in such cases, and it provides plausible deniability, and the cryptographic experts invited to the hearing would attest to that.

It’s important to both continue providing repudiation quality in communication systems, when it is appropriate, and also to educate the users about when it can be used as a reasonable defence strategy, thus improving privacy of communication and making digital off-the-record communications possible and understood both by the society and by legal systems.

## Solution

The proposed solution is to avoid the use of signature algorithm for server command authorization, and instead use authenticated encryption to authorize the commands sent to the server queues. If this protocol change is adopted, it could be used both for senders and recipients commands, both for consistency, and also to provide the deniability to recipients about executing any commands on the servers, in a similar way.

The proposed approach is to use NaCl crypto_box that proves authentication and third party unforgeability and, unlike signature, repudiation guarantee. See [crypto_box docs](https://nacl.cr.yp.to/box.html):

> The crypto_box function is designed to meet the standard notions of privacy and third-party unforgeability for a public-key authenticated-encryption scheme using nonces. The crypto_box function is not meant to provide non-repudiation. On the contrary: the crypto_box function guarantees repudiability. A receiver can freely modify a boxed message, and therefore cannot convince third parties that this particular message came from the sender. The sender and receiver are nevertheless protected against forgeries by other parties. In the terminology of https://groups.google.com/group/sci.crypt/msg/ec5c18b23b11d82c, crypto_box uses "public-key authenticators" rather than "public-key signatures.”

DJB further writes in the link above:

> If you were already planning to encrypt the message, using another key derived from g^xy, then you don't have to do any extra public-key work. A secret-key authenticator is easier to implement than a public-key signature, and it takes less CPU time to compute.

So the proposed solution appears to have desired security qualities, without non-repudiation, that is undesirable in the context of private messaging.

When queue is created or secured, the recipient would provide a DH key (X25519) to the server (either their own or received from the sender), and the server would provide its own random X25519 key per session. Then, either the authenticator will be computed in this way:

```abnf
transmission = authenticator authorized
authenticator = crypto_box(sha512(authorized), secret = dh(client long term queue key, server session key), nonce = correlation ID)
authorized = tlsunique correlationId queueId protocol_command ; same as the currently signed part of the transmission
```

The authenticator is smaller in size than currently used signature size, freeing ~34 bytes from the transmission.

This allows to retain the protocol logic and make authentication scheme configurable, both by the clients and servers, e.g. some servers might be configured to use signature for non-repudiation, and clients may be configured to either agree or disagree to that, per conversation.

There is no required change in SMP command syntax other than allowing X25519 key instead of Ed signature keys passed to the server in NEW and KEY commands. We could add support for migration of the existing queues to the new authorization scheme, but it is not strictly required, as the clients provide a mechanism to rotate the receiving addresses (currently manually, and once automated all queues will be rotated). On another hand, per queue key and identifiers rotation is cheaper than negotiating the new queue (it can be done between client and server, without the involvement of another party), and could be considered as an independent improvement.

## Migration plan

As this new scheme breaks backward compatibility, as the new scheme requires additional keys in protocol handshake, and current implementation does not support forward compatible header extension, we have to migrate in multiple steps, to minimize any disruption to the users.

1. Upgrade clients for forward compatibility of the protocol handshake (ignore extra bytes) - 5.5.3.
2. Add support for handshake and version negotiation to XFTP - 5.5.4 or 5.6.
3. Upgrade clients to drop support of SMP earlier than v4 (batching) and also drop support of old double ratchet protocol and old handshake - 5.6.
4. Upgrade servers to offer SMP v7 with support for new authorization - by the time 5.6 is released.
5. Upgrade clients to require server support for SMP v7 / new authorization scheme and start using it - 5.7 or 5.8. At this point the old version of the servers will not be supported, as maintaining this backward compatibility would substantially increase the complexity and logic of the client - at the point of generating the key we do not even know which server version will be used.
