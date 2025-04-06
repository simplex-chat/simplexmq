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

## Design for channel/group as a separate queue mode

Option 1.

A queue mode "channel" when owners are represented by their individual queues (either a separate mode, or a submode of "channel", or just normal contact address queues). In this case sending message to channel queue would broadcast message to queue owners, without exposing even the number of owners.

Pros:
- allows chat relays to send messages to all owners (e.g., channel can be secured with the list of snd keys, one per relay).
- quite easy to evolve from the current design.
- extensible.
Cons:
- close to "solution in search of a problem".
- does not require data model changes - channel queue would simply have a list of owner "recipient IDs", and each owner queue would also point to channel.

Option 2.

Also a separate queue mode "channel", but instead of having a linked owner queues, it would simply maintain a list of owner keys to maintain the data. In this case, messages cannot be sent to this "queue" at all.

Pros:
- simpler design.
- we could allow sending messages to it too, with the "main" owner receiving them. This could be negotiated in the protocol.
- it may be easier to migrate the current groups, as the admin link would be this queue (although for public groups in directory it would have to be recreated anyway).
- Possibly, when queue is created there should be a flag whether it should accept unsigned messages - then contact addresses would be created with unsigned messages ON, messages queues, once SKEY is universally supported, with unsigned messages OFF, and channel queues with unsigned messages OFF too for new public queues.
Cons:
- if no messages are accepted, this is not even a queue.
- no way to directly contact owners (maybe it is not a downside, as for relays there would be a communication channel anyway as part of the group).

Option 2 looks more simple and attractive, implementing server broadcast for SMP seems unnecessary, as while it could have been used for simple groups, it does not solve such problems as spam and pre-moderation anyway - it requires a higher level protocol.

The command to update owner keys would be `RKEY` with the list of keys, and we can make `NEW` accept multiple keys too, although the use case here is less clear.

## Multiple owners managing queue data.

Option 1: Use the same keys in SMP as when signing queue data.

Option 2: Use different keys.

The value here could be that the server could validate these signatures too, and also maintain the chain of key changes. While tempting, it is probably unnecessary, and this chain of ownership is better to be maintained on chat relay level, as there are no size constraints on the size of this chain. Also, it is better for metadata privacy to not couple transport and chat protocol keys.

We still need to bind the mutable data updates to the "genesis" signature key (the one included in the immutable data).

The proposed design:

- when mutable data is signed by genesis key, then it is bound, and no changes is needed.
- mutable data may be signed by the key of the new owner, in which case mutable part itself must contain the binding.

Current mutable data:

```haskell
data UserLinkData = UserLinkData
  { agentVRange :: VersionRangeSMPA,
    userData :: ConnInfo
  }
```

Proposed mutable data:

```haskell
data UserLinkData = UserLinkData
  { agentVRange :: VersionRangeSMPA,
    owners :: [OwnerInfo]
    userData :: ConnInfo
  }

type OwnerId = ByteString

data OwnerInfo = OwnerInfo
  { ownerId :: OwnerId, -- unique in the list, application specific - e.g., MemberId
    ownerKey :: PublicKeyEd25519,
    -- owner signature of immutable data,
    -- confirms that the owner agreed with being the owner,
    -- prevents a member being added as an owner without consent.
    ownerSig :: SignatureEd25519,
    -- owner authorization, sig(ownerId || ownerKey, prevKey), where prevKey is either a "genesis key" or some other key previously signed by the genesis key.
    ownerAuthId :: OwnerId, -- null for "genesis"
    ownerAuthSig :: SignatureEd25519
  }
```

The size of the OwnerInfo record encoding is:
- ownerId: 1 + 12
- ownerKey: 1 + 32
- ownerSig: 1 + 64
- ownerAuthId: 1 + 12
- ownerAuthSig: 1 + 64

~189 bytes, so we should practically limit the number of owners to say 8 - 1 original + 7 addiitonal. Original creator could use a different key as a "genesis" key, to conceal creator identity from other members, and it needs to include the record with memberId anyway.

The structure is simplified, and it does not allow arbitrary ownership changes. Its purpose is not to comprehensively manage ownership changes - while it is possible with a generic blockchain, it seems not appropriate at this stage, - but rather to ensure access continuity.

For example it would only allow any given owner to remove subsequenty added owners, preserving the group link and identity, but it won't allow removing owners that signed this owner authorization. So owners are not equal, with the creator having the highest rank and being able to remove all additional owners, and owners authorise by creator can remove all other owners but themselves and creator, and so on - they have to maintain the chain that authorized themselves, at least. We could explicitely include owner rank into OwnerInfo, or we could require that they are sorted by rank, or the rank can be simply derived from signatures.

When additional owners want to be added to the group, they would have to provide any of the current owners:
- the key for SMP commands authorization - this will be passed to SMP server together with other keys. There could be either RKEY to pass all keys (some risk to miss some, or of race conditions), or RADD/RGET/RDEL to add and remove recipient keys, which has no risk of race conditions.
- the signature of the immutable data by their member key included in their profile.
- the current owner would then include their member key into the queue data, and update it with LSET command. In any case there should be some simple consensus protocol between owners for owner changes, and it has to be maintained as a blockchain by owners and by chat relays, as otherwise it may lead to race conditions with LSET command.

Potentially, there could be one command to update keys and link data, so that they are consistent.
