# SMP agent: cryptography

3 main directions of work to enable basic level of security for communication via SMP agents and servers at the current stage of the project:

- Transport encryption - enable encryption for TCP.

  Out-of-scope for this rfc.

- Initial handshake using asymmetric key pairs, starting with out-of-band message.

- E2E encryption of messages between SMP agents relayed over SMP servers.

- Authentication of agent commands with SMP servers.

For initial implementation I propose approach to be as simple as possible as long as it meets our security requirements. So no pluggable encryption mechanisms, no configuration, no integration with [Noise Protocol Framework](https://noiseprotocol.org), only the most necessary Crypto schemes pre-decided per area of application.

## Initial handshake
### Why handshake has to be with asymmetric keys

    E controls servers & listens out-of-band.
    Keys are generated on the clients (A & B), queues are generated on servers.
    1. A generates Apub, Aprv, BAq
    2. A --oob-> B: Apub, BAq; E listens this, however she can't substitute this (passive attack on out-of-band, active on servers)
    3. E generates EpubA, EprvA, AEq
    4. E --BAq-> A: EpubA, AEq - encrypted with Apub;
    Alice thinks this message is from Bob
    5. B generates Bpub, Bprv, ABq
    6. B --BAq-> ~~A~~E: Bpub, ABq - encrypted with Apub;
    Eve controls servers so this doesn't get sent to Alice, instead it is received by Eve
    7. Eve has to send to Bob via ABq encrypting with his Bpub. By controlling servers E could know ABq so she wouldn't have to decrypt it - she knows where to send. Even so she can't decrypt Bpub w/t Aprv. The problem [for Eve] is that Bpub and Aprv are generated on the clients, which she doesn't control.

If keys were symmetric she could simply decrypt Bob's key with the key Alice sent out-of-band.

### Where MITM attempt fails

In asymmetric setup the following happens:

- In Bob to Alice direction Eve intercepts messages from Bob and re-encrypts them using Apub.

- In Alice to Bob direction Alice encrypts messages with EpubA and Eve can decrypt them with EprvA. Eve can't, however, re-encrypt them for Bob because she doesn't know Bpub. She also couldn't substitute it because it is out of her control. Alice wouldn't [technically] notice the MITM attempt, but Bob will not be receiving decryptable messages, and he would have to tell Alice out-of-band.

> **To be discussed:** Implementation-wise Bob's connection probably should be shut down if he receives a message he fails to decrypt, or after some timeout if he doesn't receive messages.

### Handshake implementation

TODO

## E2E encryption

For E2E encryption of messages between SMP agents we should go with some robust [Authenticated Encyption](https://en.wikipedia.org/wiki/Authenticated_encryption) scheme following [Encrypt-then-MAC](https://en.wikipedia.org/wiki/Authenticated_encryption#Encrypt-then-MAC_(EtM)) approach. The good candidate is [TODO insert implementation from a good library here].

Since we have a shared secret Apub, Bpub (if Apub is compromised connection should be shut down on Bob's side, see [above](#MITM-attempt-problem)) there is no point in using digital signatures over MACs for message authentication other than non-repudiation. Besides [digital signatures generally being less performant than MACs](https://crypto.stackexchange.com/a/37657), the non-repudiation quality I believe may in fact be more undesirable than not for many possible applications. If some applications require non-repudiation it can be implemented later on with digital signatures on application level. See a good answer on differences of MAC and digital signature qualities [here](https://crypto.stackexchange.com/a/5647).

Instead of using two assymetric key pairs, we'll use two AE symmetric keys set up in both directions per connection - one key per SMP queue (depending on chosen AE scheme a key here most likely will be a set of two separate keys - one for encryption algorithm and one for MAC). 

For current purposes it should be good enough to share these keys during [handshake](#-Initial-handshake):

    5*. B generates Bpub, Bprv, ABq, Bsym
    6*. B --BAq-> A: Bpub, ABq, Bsym - encrypted with Apub
    7. A generates Asym
    8. A --ABq-> B: Asym
    A & B can send messages to each other encrypted with symmetric keys Bsym and Asym respectively.

Not necessarily in current scope, but in future these symmetric keys have to be rotated per session.

## Authentication with SMP server

TODO

## Concerns

- MITM between SMP agent and server is still possible w/t transport encryption.
