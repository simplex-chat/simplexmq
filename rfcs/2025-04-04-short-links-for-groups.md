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

2. Allow "joint management" of SMP queues.

SMP servers can support multiple recipients for contact queues:\
- subscription would be possible to the "subscriber recipient".
- all other changes (update data, change subscriber recipient, add or remove recipients) would require multiple recipient signatures on SMP command in line with n-of-m multisig rules, that the command sender would have to collect out-of-band (from SMP protocol point of view).

Pros: allows joint ownership, and protects from losing access to master owner device.
Cons:
- complicates queue abstraction with approach that is not needed for most queues.
- still retains the server as a single point of failure.

3. Introduce "group" as a new type of entity managed by SMP servers.

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
