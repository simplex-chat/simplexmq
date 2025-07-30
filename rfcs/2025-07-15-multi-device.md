# Using the same profile from multiple devices

## Problem

Double Ratchet algorithm makes it hard to send/receive messages sent to the user from different devices, as each message changes the state of Double Ratchet keys, and these state changes must be strictly sequential and they cannot be reversed (although skipping is possible).

Traditional approach for multi-device converts each direct conversation into a group, where each device participates as a member. Likewise, for group conversations each device also participates as a member. While these members *look* as if they are the same user to others, a very simple client app modification may show device ID for each message, and the communication peers, both in direct chats and in groups would know how many devices a user has and which device the user sent the message from. In addition to that, with this approach communication peers can send different messages to different devices (it can be prevented by provider who would request that only message key is encrypted with DR, while the encrypted message is the same) or withheld from some devices (it cannot be prevented by provider, as it cannot add key to the communication in case it is missing, and cannot withhold the message completely too). These opens various vectors for targeted attacks, e.g.:
- tracking movements of the user: once each devices is identified as "desk" and "phone" it would allow to know where the user is at a given time.
- manipulating information by sending messages to one device (to have proof it was sent) and withholding from others, or sending different messages if the protocol allows it.

In addition to that, the specific implementation of this approach in Signal compromises break-in recovery property (aka post-compromise security) of Double-Ratchet algorithm, making its design ineffective - the only reason to have the second ratchet in DR algorithm is to provide break-in recovery, without it a much simpler design with a single ratchet is sufficient. See [this paper](https://eprint.iacr.org/2021/626.pdf) for details.

While this limitation can be addressed with notifications when a new device is added and per-device keys, we still find the remaining attack vectors on user security and privacy to be unacceptable, and opening unsuspecting users to various criminal actions - and it is wrong to say that would only affect security conscious users, and most people would not be affected by these risks. Allowing potential criminals in groups to know which device you are currently using is a real risk for all users.

Another approach was offered by Threema that is ["mediator" server](https://threema.com/en/blog/md-architectural-overview) where the state of encryption ratchets is stored server-side. While it protects the user from their communication peers, it increases required level of trust to the servers, and in case of SimpleX network it would expose the knowledge of who communicates to whom. So while the idea of server-side storage of encryption state is promising, it has to be per-connection, to retain "no-accounts" property of SimpleX messaging network.

Also see [FAQ](https://simplex.chat/faq/#why-cant-i-use-the-same-profile-on-different-devices) and [this issue](https://github.com/simplex-chat/simplex-chat/issues/444#issuecomment-3066968358).

## Proposed solution

One of the ideas presented in FAQ - to store the state of Double Ratchet algorithm in the encrypted container on the server seems promising. The RFC develops this idea.

### Considerations for the design

1. The largest ratchet state size with the current implementation is less than 8kb (which is achieved when both sides shared PQ keys and ciphertexts), so while it cannot fit in the same transport blocks together with sent and received messages, it would fit in one transport block.

2. Protocol commands and events may be changed (even if at the cost of slightly reducing message size) can fit the hash of the ratchet state (32 bytes sha256 would be sufficient), so that the client can determine whether it has the most recent ratchet state or if it needs to retrieve the latest copy. Message size reduction won't affect the users because we use compression, and there is a substantial reserve.

3. Client commands that modify ratchet state would include the hash of the previous ratchet state so that the server can reject or ignore the command in case the previous ratchet state is different or in case command is repeated in case of lost response).

4. The client does not need to retrieve message state for each encryption and decryption operation - it can "speculatively" use the ratchet state it has, and receive correct ratchet state in the "error" response after attempting encryption based on incorrect ratchet state.

## Proposed protocol design

Ratchet state will be stored on the same server that stores message queue, as part of message queue record. 8kb is a sufficient size for this blob (the actual max size is 7800 bytes). The server would also store the hashes of the current and, possibly, the previous ratchet states (TBC).

While ratchet is used for duplex connection, the connection still has primary queue, and with redundancy the same ratchet state can be stored on all secondary queues.

Ratchet state will be encrypted using secret_box - a symmetric encryption scheme, so PQ-resistant. If ratchet state is stored on more than one server, it has to be encrypted with a different key for each server.

Questions: how to rotate the key used to store ratchet? Should key used to encrypt ratchet rotate at the same time when queue is rotated? The latter is a logical option, as it prevents additional complexity and solves the problem anyway. A possible option is to have "ratchet version" that will be used to advance the key used to encrypt ratchet via HKDF.

Security considerations: the scheme may reduce break-in recovery to the points queues are rotated, unless there is some randomness mixed-in into the key derivation (the key used to encrypt ratchet state). But including randomness would defeat the purpose, as other devices wouldn't be able to access the ratchets. Another approach would be to have each device use its own key for encryption, and encrypt to all keys of all devices (or to encrypt key, to avoid size increase). Having multiple encryptions would show how many devices use the queue, but servers already can observe it, so it is a better tradeoff. Another idea would be to rotate the key used to authorize queue commands - we already support multiple recipient keys, and it can be used for multi-device scenario. That would partially mitigate break-in attacks as the attacker who obtained the key from ratchet state would be able to decrypt it, but won't be able to decrypt it (the attacker collusion with the server is not mitigated). Yet another idea would be for each party (device) to share its private (or encapsulation) key and to have a symmetric key (used to encrypt the ratchet state) encrypted (encapsulated) separately for each device. This would reduce the size of the stored data to `ratchet size` + `encrypted key size` * N, so even in case of PQ encryption (e.g. sntrup) the size required to store the ratchet would be under transport block size, while limiting it to say 4-8 devices, which is sufficient.

To participate in multi-device scheme the devices would join the usual group that will be used to share public (encapsulation) device keys and to communicate updates to conversations that were received by the currently "active" device. "Active" means the device that received or sent and processed the message, and while only one device can receive messages from a given queue, device "active" state may be determined per queue, allowing concurrent usage.

The scheme must be resilient to state updates being lost, and in case of direct messages it would result in some messages not being shown (or shown as skipped), while conversation preference and profile updates can be re-requested from peers, while the current profile of the user would become the latest. Likewise, for groups state updates ca be requested from super-peers or for decentralized groups - from owners. Maintaining chat state consistency is an important consideration, but is not a focus of this RFC - the focus is managing message delivery and DR encryption for multiple devices. Other multi-device schemes have the same issues with state consistency. Partially, the profile state consistency can be improved by using a single shared queue (or set of queues) to store user's profile and chat preferences to synchronize profile updates asynchronously between the devices.

## The protocol to send the message

`rsi` - ratchet state on device `i`.

`enc(rs)` - current authoritative ratchet state on the server.

`pt` and `ct` - plaintext and ciphertext messages.

Encryption is a state transition function ratchetEnc: `(ct, rs') = ratchetEnc(pt, rs)`.

1. Device encrypts the message using the stored ratchet state: `(ct, rsi') = ratchetEnc(pt, rsi)`

2. Device sends modified encrypted ratchet state and the hash of the previous encrypted state to the server that stores the queue: `RSET (hash(enc(rsi)), enc(rsi'))`.

3. If the hash of the previous state matches state stored on the server (`hash(enc(rsi)) == hash(enc(rs))`), the server updates the state and responds with `ratchet_ok` (that may include the current state or it's hash, for validation). If the hash is different, the server responds with `bad_ratchet(enc(rs))` message that includes the correct ratchet state. These updates must be atomic. In this case device has to update the local ratchet state (provided it can decrypt it), and repeat encryption attempt. If device cannot decrypt the provided ratchet state, it means that the connection is disrupted (possibly, device is removed from device group, but missed the notifications).

4. After successful state update in primary receiving queue, the device would update it in secondary receiving queues.

5. Device sends encrypted message as usual, via proxy that must be different both from the server that stores the ratchet and from the destination server.

6. Device broadcasts sent message and new ratchet state to other devices in the device group.

This protocol is simple, and it minimizes requests when sending the message to one additional request to update ratchet state in most cases, only requiring two requests when device state was not updated via device group prior to message sending attempt.

## The protocol to receive the message

Decryption is also a state transition function: `(pt, rs') = ratchetDec(ct, rs)`

1. Server sends the message to the device (can be in response to SUB or ACK commands, or with active subscription). Pushed message would include the hash of the currently stored ratchet state: `hash(enc(rs))`.

2. If device has the ratchet state with the same hash (`hash(enc(rs)) == hash(enc(rsi))`), it decrypts the message: `(pt, rsi') = ratchetDec(ct, rsi)`.

3. If device has ratchet state with a different hash, it requests ratchet from the server with additional protocol command `RGET` with response `RCHT (enc(rs))` and updates the local state.

4. Device decrypts the message `(pt, rsi') = ratchetDec(ct, rsi)` and processes it as usual.

5. Device sends acknowledgement to the server as usual, but now it includes the new ratchet state and the hash of the previous state: `ACK msgId (hash(enc(rsi)), enc(rsi'))`

6. The server compares ratchet state with stored state hash, and in case it matches it processes `ACK` and responds with `OK` as usual (or `NO_MSG` in case msgId is incorrect, also as usual - it would happen in repeated ACK requests). If ratchet state hash does not match, the server would respond with `bad_ratchet(enc(rs))` - which means that the message was already processed by another device and ratchet was advanced. This is a complex scenario, as the client has to either revert the change from message processing or somehow combine the change with the updates communicated via device group (as a side note, device group can simply re-broadcast messages, not state updates, but it will result in state divergence between devices when different messages are lost).

Unlike sending messages, this flow does not require any additional requests in most cases, only requiring requesting message state reconciliation when the same message was received and processed by more than one client, but it does not require re-acknowledgement.

## Challenges

This is an idea of the design rather than the actual design, as it requires more thinking about:
- how to handle concurrent ratchet state updates,
- "active" status transitions per queue,
- avoiding concurrent subscriptions to queues from multiple devices,
- state updates and synchronization between devices,
- handling skipped messages,
- costs to update ratchets in bulk send scenario - this scheme would substantially increase costs of preparing large broadcasts, and it makes this scheme not acceptable for chat relays. Which means that "profile" on desktop used as chat relay won't be synched to other devices.
- etc.

## Advantages

The communication peers won't know how many devices the user has, and which device was used to send the message. Also, the communication peers won't be able to send different messages to different user's devices, or to withhold messages from some devices.
