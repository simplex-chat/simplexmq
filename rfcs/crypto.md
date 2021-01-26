# SMP agent: cryptography

3 main directions of work to enable basic level of security for communication via SMP agents and servers at the current stage of the project:

- Transport encryption - enable encryption for TCP.

  Out-of-scope for this rfc.

- E2E encryption of messages between SMP agents relayed over SMP servers.

- Authentication of agent commands with SMP servers.

For initial implementation I propose approach to be as simple as possible as long as it meets our security requirements. So no pluggable encryption mechanisms, no configuration, no integration with [Noise Protocol Framework](https://noiseprotocol.org), only the most necessary Crypto schemes pre-decided per area of application.

## E2E encryption

For E2E encryption of messages between SMP agents we should go with some robust [Authenticated Encyption](https://en.wikipedia.org/wiki/Authenticated_encryption) scheme following [Encrypt-then-MAC](https://en.wikipedia.org/wiki/Authenticated_encryption#Encrypt-then-MAC_(EtM)) approach. The good candidate is [TODO insert implementation from a good library here].

Since we have a shared secret (sent out-of-band) there is no point in using digital signatures over MACs for message authentication other than non-repudiation. Besides [digital signatures generally being less performant than MACs](https://crypto.stackexchange.com/a/37657), the non-repudiation quality I believe may in fact be more undesirable than not for many possible applications. If some applications require non-repudiation it can be implemented later on with digital signatures on application level. See a good answer on differences of MAC and digital signature qualities [here](https://crypto.stackexchange.com/a/5647).

Instead of using two assymetric key pairs, we'll use two AE symmetric keys set up in both directions per connection - one key per SMP queue (depending on chosen AE scheme a key here most likely will be a set of two separate keys - one for encryption algorithm and one for MAC). The first key of a Duplex connection is shared out-of-band (by Alice, for Bob-to-Alice SMP queue), the second key is encrypted using the first and shared through the first queue (by Bob, for Alice-to-Bob SMP queue).

## Authentication with SMP server

TODO

## Concerns

- MITM between SMP agent and server is still possible w/t transport encryption.
