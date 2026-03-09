# Transmission encryption

## Problems

### Protection of meta-data from sending proxy

The SEND commands and message queue IDs need to be encrypted so that sending proxy cannot see how many queues exist on each server.

Correlation IDs need to be random and can be re-used as nonces so that the destination relay cannot use the increasing correlation IDs that are sent in v6 of the protocol to track the sender.

###  Protection of the traffic from the attacker who compromised TLS

Currently, even though different sending and receiving queue IDs are used, the attacker who compromised TLS could do statistical analysis and in this way correlate queue IDs of senders and recipients, and therefore correlate the senders and recipients.

## Possible solutions

1. Encrypt sent messages, other commands and their responses in the additional envelope, irrespective of whether proxy is used or not. In this case the requestion transmission could have this syntax:

```abnf
encReqTransmission = pubKey nonce encrypted(reqTransmission)
reqTransmission = respNonce entityId command

encRespTransmission = replyNonce encrypted(respTransmission)
respTransmission = entityId command
```

The keys to encrypt and decrypt both the command and responses would be computed as curve25519 from the key sent together with command and server session key. For the requests, the nonce has to be random and sent outside of the encrypted envelopt, but for the response respNonce would be taken from inside of the encrypted envelope and it would also be used for correlating commands and responses. This way the attacker who could compromise TLS would not be able to correlate the commands and responses, and also observe entity IDs.

2. The remaining question is to how encrypt and decrypt messages delivered not in response to the commands.

The possible options are:
- restore client session key only for that purpose, but do not forward this key to the destination proxy for sent messages. Then the messages can be sent with a random replyNonce and the key would be computed from session keys. The advantage here is that we won't need to parameterize handles as both client and server would have session keys. The downside that we would have to either somehow differentiate messages and responses, either by some flag that would allow some correlation or just by the absense of replyNonce in the lookup map - that is if the client can find replyNonce, it would use the associated key to decrypt, and if not it would use session key.
- use the same key that was sent with SUB or ACK command. This is much more complex, and would only have some upside if we were to introduce receiving proxies (to conceal transport sessions from the receiving relays for the recipients).
