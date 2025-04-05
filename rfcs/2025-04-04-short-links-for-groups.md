# Using short links as group links

## Problem

To use the short links for groups these problems has to be / can be solved:
1. recognizing link as a group link.
2. permanent link with the ability to change chat relays.
3. binding owners signatures to the link.
4. allowing to add/remove owners, both to share ownership and for reliability in case of one owner losing keys/access.

While current short links solve problems 1-3 (via contact type, and via extension of user data in the link), the problem 4 is solved only partially.

We could include the current list of root owners in the user data, and we could send any history of ownership changes from this baseline as a short blockchain on joining the group, we still requrie one master owner to retain access to the queue associated with the group.

## Possible solution approaches

1. "Kick this can down the road" - ignore this problem until there is a namespace, and a group name can be associated with multiple queues.

Pros: simple and reasonable, and it suggests postponing multisig for owners too. The users can still see the list of owners and their keys in user data of the link, and receive admin roster signed by owners on joining.

Cons: if this "master owner" loses the access to the device, no further changes to group profile will be possible.

2. The queue access can be shared by sharing the key and recipient IDs with all owners.

The problems:
- preventing MITM attack between owners (this protect exists for other solutions too).
- protecting these credentials from chat relays. So somehow there should be direct key agreement between members allowing to send e2e encrypted message inaccessible to chat relays.

Pros: simpler than alternatives, and still provides protection against losing the key.
Cons:
- quite clunky, and requires the new primitive anyway (e2e encryption).
- no multisig

This could possibly be evolved into the requirement to have a direct connection with other owners, and verifying the security code before they have access to group.

3. Allow "joint management" of SMP queues.

SMP servers can support multiple recipients for contact queues:\
- subscription would be possible to the "subscriber recipient".
- all other changes (update data, change subscriber recipient, add or remove recipients) would require multiple recipient signatures on SMP command in line with n-of-m multisig rules, that the command sender would have to collect out-of-band (from SMP protocol point of view).

Pros: allows joint ownership, and protects from losing access to master owner device.
Cons:
- complicates queue abstraction with approach that is not needed for most queues.
- still retains the server as a single point of failure.

4. Introduce "group" as a new type of entity managed by SMP servers.

SMP servers would provide a separate set of commands for managing group records that would include in an encrypted container:
- the group profile
- the list of chat relay links
- the list of owner member IDs with their public keys
- multisig rules
- alternative group entity locations
- possibly, a globally unique group identity (as the hash of the initial/seed group data).

While the server domain would be used as the hostname in group link, it may contain alternative hosts (not just hostnames of the same server), both in the link and in the group record data.

Pros: separates additional complexity to where it is needed, allowing reliability and redundancy for group ownership.
Cons: complexity, coupling between SMP and chat protocol.

## Design ideas for group as a separate entity type

The last solution approach seems both the most long-term and also provides the best functionality, so maybe it could be an extensible base.

Its advantage is that it does not require e2e encryption between owners, as only public keys are shared (although MITM is still possible without verification, mitigated by using multiple chat relays).

The proposal is to have a new entity "asset", and a queue mode "asset". This entity represents a reference to some kind of digital asset, not part of SMP spec. Each link is managed by multiple owners, each represented with "asset" queue.

The change from the current design is simple - splitting the link and data from the queue table/record into a separate table, so that the same link can be referenced by multiple queues with different owner IDs. Any of the linked asset queue recipients can modify link data and delete link. The protocol encoding could support multisig, but it can be added later with a separate protocol version. But it would alread allow having multiple owners for link.

It is also probably correct to require that Ed25519 is used for recipient/owner authorization (and not X25519 authenticators that are used for senders).

Question 1: should the same signature key be used for signing server commands and owner-owner comms? There may be a benefit in having two different keys, and in contexts visible to both server and owners use server key, and in contexts visible to owners only use signature key inside data.

Question 2: should non-owners see server keys of owners? If not, does it suggest a third owner-only data blob? Or should the server simply maintain the currently signed ownership agreement? Or even the history of the agreement changes?

Question 3: how would the owner validate the correctness of ownership changes - where this chain will be maintained? Should it maybe be replicated to all owners' "asset" queues? Or will it be a separate "chain" that will be truncated once all owners acknowledge the change? Almost like a separate queue?

The protocol change required would be to make sender ID optional in LNK response. Alternatively, link could have its own sender ID and broadcast messages to link owners, and a rule whether messages can be sent without key, and whether this link can be secured with SKEY. Depending on queue type it would be:

- "messaging" queue: can secure, can send messages.
- "contact" queue: cannot secure (only owner can secure), can send unsigned messages.
- "asset" queue: cannot secure, cannot send unsigned messages.

To allow multiple delegates the queue could allow multiple send keys. In case of delegates (chat relays), we could require that only Ed25519 keys are used (for non-repudiation).

The additional commands required would be to add, get and delete link owners:
- invite owner (OADD): adds some random server-generated new owner ID to link - this token with the current owner's signature will be included in NEW command (the signed token to be passed out of band). Separate table?
- remove owner (ODEL): remove owner from link by owner ID (both before and after new owner accepted ownership).
- get owners (OGET): get current owner IDs and their public keys.
- how would notification be delivered to the owner when s/he is removed? Some event? Possibly all changes are delivered as messages to each "owner's" asset queue, probably with longer expiration periods?

While initially we don't need to build support for multisig in UX, it can be easily added later with this design.

The flow then would be, for new "asset" queue with link - it is created as usual, with "NEW" command, and queueMode QMAsset that is passed linkId and link data.

When additional owners want to be added to the group, they would have to create "link" type queue without link ID (thus preventing non-consensual ownership transfer). The flow would be this:
- group owner(s) offer to become additional owner with the specific new multisig rule, this is sent as a message in chat with signed ID from `OADD` command.
- the proposed owner will validate that this offer is signed according to the current multisig rule, by loading queue data and current owners (possibly via its ID from `OADD` command, that would also secure this owner ID).
- if the proposed owner accepts it, s/he will create a new "asset" queue linking it with the same link ID - the server would also accept signed owner ID as a confirmation.

Alternatively, it could be an out-of-band exchange first, when existing owner sends an offer, the new owner accepts it and returns the key (and signed offer), and then this key is sent to the server by the old owner, returning owner ID to the new owner.
