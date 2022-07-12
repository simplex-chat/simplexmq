# Private Groups

An alternate groups approach that preserves more privacy properties.
These groups can only be formed if all members already have direct connections to all other members.
This eliminates the need for implicit introductions, which offer vectors for MITM attacks.
Critically, we can ensure that we don't reveal any information about a user's network, other than what they opt into sharing for adjusting membership.
Lastly, we require no modification to the underlying protocol.
Standard duplex communication is sufficient.
Agents need new behavior in soliciting proposals for membership changes, and for responding to them.

This group protocol both captures the ethos of the SimpleX message protocol privacy, and increases trust in connections.
Notably, this protocol can serve to _out_ an imposter rather than enable them, should at least one member of the group know the real identity.
Say Alice, Bob, and Carol are in a group and want to add Dave.
Only Alice actually knows Dave, but Mallory has scammed Bob and Carol into believing that she is Dave.
This protocol will not let Dave or Mallory be admitted to the group, since neither can prove that they know all parties.
Alice, Bob, and Carol have increased hopes of identifying Mallory as an imposter once they realize it is impossible to add Dave.

## The Protocol

### Additions

A formal specification of the protocol is defined in TLA+ and can be defined [here](./2022-06-11-private-groups/groups.tla).
A crash course in TLA+ and the key abstractions used in the spec is [here](./2022-06-11-private-groups/README.md).

The protocol has four roles:

  1. The proposer, a group member who wants to add a new user
  1. The invitee, the user the proposer wants to add to the group
  1. The leader, the user who originally established the group and who orchestrates all proposals on behalf of proposers
  1. The approvers, all current group members who are neither proposing or leading

A centralized leader is not a drawback in for this algorithm, because in order to validate that all current members have direct connections with the invitee, all members must actively participate.
The leader allows for a simpler centralized approach, without compromising availability.

#### Proposer

The proposer generates a random invitation identifier and a token.
The proposer sends an Propose message to the leader that includes the invitation identifier and an informal description of the invitee (such as their contact name).
The proposer also sends an Invite message to the invitee that includes the token and the current membership count of the group.

#### Leader and Acceptors (phase 1)

Upon receipt of a Propose message, the user is prompted to see if they want to add the invitee to the group.
Since the description of the invitee is informal, they may also have to manually select which of their contacts match the description.
It is possible that the user does not know the invitee.
It is also possible that the user _thinks_ they know the invitee, but have mistaken them for someone else.
In the case of misidentification, the protocol is still safe and preserves privacy.

If they do not want to add the invitee (possibly because they have no direct connection), it is sufficient to simply ignore the message.
However an explicit rejection message provides a speed up to the inevitable failure to add the contact.

If the Propose recipient wants to add the contact to the group they:
  1. Generate a token.
  1. Store the invitation identifier, proposer's token, and their token.
  1. The Leader: Rebroadcasts the Propose message to all Approvers.
  1. Approvers: Send an Invite message to the invitee that includes the invitation identifier, their token, and the count of current members.

The choice to accept or reject and the generated token should be locally committed before sending messages so conflicting messages are not sent.

#### Invitee

The invitee collects all Invite messages.
While they cannot predict who they are waiting for, each invite includes the number of members in the group.
Upon receipt of Invites from that number that all have the same invitation identifier, the proposer now knows the full membership of the group and the user should be prompted as to whether or not to accept membership.
If they decline, it is sufficient to ignore the messages, but more efficient to send a message as such.

To accept, the invitee responds to all contacts with an Accept message that includes the invitation identifier and all tokens.

In the case of contact confusion between members, it is impossible for anyone outside of the group to send an Accept message as they never collect the correct number of tokens.

#### Approvers (phase 2)

Once a member has an Accept message from the invitee, they begin syncing their tokens with other members via a SyncToken message.
A SyncToken message can both send a token and ack receipt of a token from another member, based on the `ack` flag within the message.

Once a member has all other members' tokens, assuming they all match the Accept message, then the member knows that all parties have agreed to extend membership.

TODO: Welcome messages are not modeled in TLA+

The member locally commits this result sends a Welcome message to share the group-specific ids of each member.
These are the original invitation ids for this member (or none if the member is the Leader).
These ids are still used for kicking members (and the Leader can't be).
Each member sends a message that includes a mapping of tokens to ids, which the Invitee can use to infer the correct id per member.

Once the Invitee receives a Welcome message from each member (ensuring that all members provide the same token-to-id mapping), they then begin to setup new connections with each member specific to each group.

Each Approver notifies the Leader that they have established a connection with the invitee.
This both lets the Leader know that it need not continue to send reminder Propose messages, and it ensures that the Approver does not get kicked in a cancellation (see below).

#### Failures

If an approver does not want to invite the invitee, the proposal is doomed, and they will not be invited.
By notifying the Leader, they can simply mark the proposal as completed.

However, it is not possible to tell the difference between a misidentified invitee and members or the invitee simply needing more time.
In the case of a misidentified invitee, the proposal can never be resolved, as no invitee will ever receive all tokens, meaning the Leader will never receive an Accept message.
Since it's only safe to manage one proposal at a time, we must be able to cancel the proposal in order to make progress.

To cancel, the Leader will face one of two scenarios:

##### Cancellation - None Established

If the leader has not received any notice of established connections, it can assume that all Approvers are operating normally, and that the invite _probably_ won't work.
Since it is uncertain about the latter, it resolves the current proposal but immediately begins the process to Kick the invitee.
If there was confusion about the invitee, then the Kick will resolve immediately, as there's no work to do except record the invitation identifier as being permanently kicked.
In the case that there was a race between establishing a connection and giving up, then those who established a connection will Kick the invitee and ensure that all group members have same perception of membership.

##### Cancellation - Some Established

If the Leader has received an Established message back from any member, then it knows that there was no confusion over the invitee, and they can be brought into the group.
However, it is possible that some previous members are unable to complete the invitation process (such as a lost/destroyed device).
To ensure that the group can complete proposals, the Leader may then Kick any user that has not established a connection (except the Leader).

TODO: Ideally, kicked members (or invitees that established connections with kicked members, who think they are part of the group) eventually learn that they are not in the group after all.

#### Properties

Model checking our formal specification we can demonstrate three key properties:
  1. Users outside of the group only learn about the networks of members who agree to share such information with them.
  1. It is not possible to accidentally establish a group connection with anyone other than the invitee, even if users misidentify the invitee.
  1. If a proposal is complete, then all members (according to the leader) agree on who is a member.
  1. Proposals always complete (successfully or otherwise), assuming the Leader is fair (other members don't need to participate).
  1. Only the Leader need "drive" the process, and can retry by simply sending more Propose messages.  All other parties simply react to requests as they see them.  This offers a simple implementation that avoids livelock.
  1. No members will connect with the invitee unless all members correctly identify them.
  1. Under sufficiently good conditions (no confusion, a patient leader, all users remain active, no members leave) an invite will eventually succeed.

### State Diagrams

#### Leader Specific States

Once this process activates, it _must_ terminate before it can start again.
There cannot be simultaneous invitations.

```mermaid
stateDiagram-v2
    [*] --> Proposing : Member invites
    Proposing --> Kicking : Cancel invite<br>or give up on<br>unresponsive<br>members
    [*] --> Kicking : Member kicks
    Kicking --> Kicking : Give up on<br>unresponsive<br> members
    Proposing --> [*] : All members Establish
    Kicking --> [*] : All members ack
```

#### Approver Specific States

The approver process is unique per invitation identifier, so an approver tracks many such state transitions simultaneously.
The Removed state is terminal, there is no way to restore an invitation identifier to the Added state.
However, a kicked user can be added back to any group with a _new_ invitation identifier.

```mermaid
stateDiagram-v2
    [*] --> Active : Member receives Propose
    Active --> Synchronizing : Member receives Accept
    Synchronizing --> Welcoming : Member receives<br>all other tokens
    Welcoming --> Added : Both queues are setup
    Active --> Removed : Receive Kick
    Synchronizing --> Removed : Receive Kick
    Welcoming --> Removed : Receive Kick
    Added --> Removed : Receive Kick
```

#### Invitee Specific States

The invitee process is unique per invitation identifier, so an user tracks many such states simultaneously.

```mermaid
stateDiagram-v2
    [*] --> Invited : User receives Inivte
    Invited --> Accepted : User receives all tokens
    Accepted --> Welcomed : User receives all Welcomes
```

### Specific Examples

#### Typical Success

We consider a group of three (A, B, and C), trying to add an additional member (D) and succeeding.
In this case, all members have a connection to the proposed user and no one confuses them for someone else.
In this group, A is the leader, and B starts the initial proposal.

##### Sequence Diagram

```mermaid
sequenceDiagram
    participant A
    participant B
    participant C
    participant D
    B->>A: PleasePropose D as 123
    note over A: start proposal 123
    A->>A: Propose D as 123
    note over A: generate token X
    A->>D: Invite 123, token X, n=3
    A->>B: Propose D as 123
    note over B: generate token Y
    B->>D: Invite 123, token Y, n=3
    A->>C: Propose D as 123
    note over C: generate token Z
    C->>D: Invite 123, token Z, n=3
    note over D: 3/3 members provided tokens
    D->>A: Accept 123, tokens X,Y,Z
    D->>B: Accept 123, tokens X,Y,Z
    D->>C: Accept 123, tokens X,Y,Z
    A->>B: SyncToken 123, token X, ack=false
    B->>A: SyncToken 123, token Y, ack=true
    A->>C: SyncToken 123, token X, ack=false
    C->>A: SyncToken 123, token Z, ack=true
    note over A: All tokens received and match
    A->>D: Welcome 123, X=Leader, Y=456, Z=789
    B->>C: SyncToken 123, token Y, ack=false
    note over C: All tokens received and match
    C->>B: SyncToken 123, token Z, ack=true
    note over B: All tokens received and match
    B->>D: Welcome 123, X=Leader, Y=456, Z=789
    C->>D: Welcome 123, X=Leader, Y=456, Z=789
    note over D: Now has all Welomes and they all match.<br>Member now knows how to<br>identify everyone in this group.<br>Starts making new group specific connections
    D->>A: Establish new queue for this group/member
    A->>D: Establish new queue for this group/member
    A->>A: Established 123
    D->>B: Establish new queue for this group/member
    B->>D: Establish new queue for this group/member
    B->>A: Established 123
    D->>C: Establish new queue for this group/member
    C->>D: Establish new queue for this group/member
    C->>A: Established 123
    note over A: proposal 123 complete
```

##### CLI Interactions

```bash
# User B's terminal
> /add #g @D
```

```bash
# User A and C's terminals
> @B wants to add @D to #g, accept? (y/n/change invitee)
> y
```

```bash
# User D's terminal
> @A, @B, and @C would like to invite you to a group, accept? (y/n)
> y
> What would you like to name this group?
> g
```

```bash
# User A, B, and C's terminals
> @D successfully added to group #g!
```

```bash
# User D's terminals
> You have successfully been added to group #g with @A, @B, and @C!
```

#### Success with Identity Resolution

A minor variant of the success case involves a resolvable difference in names.
Proposed member names are just that, names, they don't necessarily uniquely define the potential member.
As such, it's possible that two members see a different contact name for the same identity, which must be resolved.

Consider the same scenario as above, but user C knows user D by the contact name Dee.
The sequence diagram is identical, because the resolution occurs via direct user interactions.

Since C receives a Propose message for D, C has a different CLI interaction:

```bash
# User C's terminal
> @B wants to add @D to #g.  Do you know this contact by a different name? (y/n)
> y
> Please enter contact name:
> @Dee
> Would you like to add @Dee to group #g? (y/n)
> y
```

#### Success with Identity Conflict

A minor variant of the success case involves a resolvable conflict in names.
Proposed member names are just that, names, they don't necessarily uniquely define the potential member.
As such, it's possible that two members see a different contact name for the same identity, one of whom uses the contact name for someone else.

Consider the same scenario as above, but user C knows user D as D2, as they know another distinct contact named D.
However, user C knows that A and B only know D2, not D.
This means that user C can infer from context that B is trying to add D2 to the group, not D.
The sequence diagram is identical, because the resolution occurs via direct user interactions.

Since C receives a Propose message for D, C has a different CLI interaction:

```bash
# User C's terminal
> @B wants to add @D to #g, accept? (y/n/change invitee)
> change invitee
> Who do you think @B is trying to invite?
> @D2
> Would you like to add @D2 to group #g? (y/n)
> y
```

#### Failure Due to Unacquainted Contacts

New members can only be added if they are already known to all current members.
This means that a proposal will fail if any user doesn't recognize the contact proposed.

Consider A, B, and C are in a group.
B would like to add D, who is known to A but not to C.

##### Sequence Diagram

```mermaid
sequenceDiagram
    participant A
    participant B
    participant C
    participant D
    B->>A: PleasePropose D as 123
    note over A: starts proposal, awaiting responses from everyone
    A->>A: Propose D as 123
    note over A: generate token X
    A->>D: Invite 123, token X, n=3
    A->>B: Propose D as 123
    note over B: generate token Y
    B->>D: Invite 123, token Y, n=3
    A->>C: Propose D as 123
    note over C: User cannot identify D
    C->>A: Reject 123
    note over D: Neither user ever sees all three tokens<br>so they never reply with Accept.
    note over A: proposal 123 complete
```

Note that it is safe here to simply mark the proposal as complete and leave A and B with dangling invites sent to C.
This is because it will never be acted on again, A and B will only act upon an Accept message from D or a retried Propose message from A.

##### CLI Example

The notable deviations from the standard flow are when user C is prompted by the Propose message:

```bash
# User C's terminal
> @B wants to add @D to #g.  Do you know this contact by a different name? (y/n)
> n
> Invite rejected.
```

And when user A (the Leader) receives notice that the proposal was rejected:

```bash
# User A's terminal
> @C rejected @B's request to add @D to group #g
```

#### Failure Due to Confusion

In the event that two members agree to add an invitee, but one of the members mistakes the intended invitee for someone else, the Leader must eventually cancel the proposal.
The Leader can't actually tell based on the protocol whether the invitee was confused or one of the parties is inactive, but cancelling remains the only option.
No other changes to membership can occur until the pending proposal is completed.

Consider A, B, and C are in a group, #g.
B would like to add D.
However, C does not know the real D, they instead know E and they know them by the name D.
If this is confusing, it's because that's exactly what is happening.
C has confused E for D.
This means that the protocol will (purposefully) stall to ensure that groups don't add a member that not everyone knows.

##### Sequence Diagram

```mermaid
sequenceDiagram
    participant A
    participant B
    participant C
    participant D
    participant E
    B->>A: PleasePropose D as 123
    note over A: starts proposal, awaiting responses from everyone
    A->>A: Propose D as 123
    note over A: generate token X
    A->>D: Invite 123, token X, n=3
    A->>B: Propose D as 123
    note over B: generate token Y
    B->>D: Invite 123, token Y, n=3
    A->>C: Propose D as 123
    note over C: generate token Z
    C->>E: Invite 123, token Z, n=3
    note over D,E: Neither user ever sees all three tokens<br>so they never reply with Accept.
    note over A: User evenutally aborts due to inactivity<br>starts a proposal to kick 123
    A->>A: Kick 123
    note over A: Commits that 123 is permanently kicked
    A->>A: Kicked 123
    A->>B: Kick 123
    note over B: Commits that 123 is permanently kicked
    B->>A: Kicked 123
    A->>C: Kick 123
    note over C: Commits that 123 is permanently kicked
    C->>A: Kicked 123
    note over A: all acks recieved, kick complete
```

##### CLI Example

The leader can handle the cancellation directly:

```bash
> /pending #g
> Member @B is trying to add @D.  No user have established.  Cancel? (y/n)
> y
```

Or the leader may discover the issue when attempting a (blocked) membership change:

```bash
> Member @B wants to add @X to #g, but there is a pending invite to @D (only one at a time is allowed), cancel invite to @D? (y/n)
> y
```

#### Failure Due to Pre-Establish Permanent Inactivity

It's possible that an invitation is started before members realize that one member has gone long term or permanently offline.

Consider group #g with users A, B, and C.
Member B wants to add D.
However, member C's phone has just fallen in the ocean, and his ability to use his connections are permanently lost.

The result is starts similarly to failure due to confusion, without all members sending their tokens, the invite can never succeed.
However, since we can't be sure that an invite wasn't sent, we must Kick the new member.
The new device will not ever ack the Kick message, which prevents the group from completing the kick, meaning now other membership changes can be made.

However, the Leader can eventually complete the process by kicking any user that hasn't acknowledged the previous request.

This process of kicking members not responding to kicks can happen repeatedly until only active members remain.

##### Sequence Diagram

```mermaid
sequenceDiagram
    participant A
    participant B
    participant C
    participant D
    B->>A: PleasePropose D as 123
    note over A: starts proposal, awaiting responses from everyone
    A->>A: Propose D as 123
    note over A: generate token X
    A->>D: Invite 123, token X, n=3
    A->>B: Propose D as 123
    note over B: generate token Y
    B->>D: Invite 123, token Y, n=3
    A-XC: Propose D as 123
    note over D: Never sees all three tokens<br>so never replies with Accept.
    note over A: User evenutally aborts due to inactivity<br>starts a proposal to kick 123
    A->>A: Kick 123
    note over A: Commits that 123 is permanently kicked
    A->>A: Kicked 123
    A->>B: Kick 123
    note over B: Commits that 123 is permanently kicked
    B->>A: Kicked 123
    A-XC: Kick 123
    note over A: C never acks, so A decides to kick<br>A kicks C via his original invitation id (456)
    A->>A: Kick 456
    note over A: Commits that 456 is permanently kicked
    A->>A: Kicked 456
    A->>B: Kick 456
    note over B: Commits that 456 is permanently kicked
    B->>A: Kicked 456
    note over A: Everyone remaining in the group has acked all kicks<br>proposal is now complete
```

##### CLI Example

The leader cancels the invite (in this example, directly):

```bash
> /pending #g
> Member @B is trying to add @D.  No user have established.  Cancel? (y/n)
> y
```

And then may directly kick C for inactivity:

```bash
> /pending #g
> Cancelling invite, still waiting on @C.  Would you like to kick @C? (y/n)
> y
```

Or they may notice that C is not responding when trying to change membership:

```bash
> Member @B wants to add @X to #g, but @C is not responding to the previous cancellation (cancellations must complete).  Would you like to kick @C? (y/n)
> y
```

#### Failure Due to Post-Establish Permanent Inactivity

It's possible that an invite gets quite far along before a member goes long-term or permanently offline.
In this case, the Leader is presented with two options, they may cancel the invite or they may kick anyone not established with the new member.
The former looks just like the previous example, so we will detail the latter here.

Consider a group #g with member A, B, and C.
Member B would like to add D.
Just as about the invite is about to succeed, C drops their phone in the ocean and cannot recover their connections.

The Leader can decide to cancel the cancel the invite or just cut to the chase can kick out C (and accept D), which we show here.

##### Sequence Diagram

```mermaid
sequenceDiagram
    participant A
    participant B
    participant C
    participant D
    B->>A: PleasePropose D as 123
    note over A: start proposal 123
    A->>A: Propose D as 123
    note over A: generate token X
    A->>D: Invite 123, token X, n=3
    A->>B: Propose D as 123
    note over B: generate token Y
    B->>D: Invite 123, token Y, n=3
    A->>C: Propose D as 123
    note over C: generate token Z
    C->>D: Invite 123, token Z, n=3
    note over D: 3/3 members provided tokens
    D->>A: Accept 123, tokens X,Y,Z
    D->>B: Accept 123, tokens X,Y,Z
    D->>C: Accept 123, tokens X,Y,Z
    A->>B: SyncToken 123, token X, ack=false
    B->>A: SyncToken 123, token Y, ack=true
    A->>C: SyncToken 123, token X, ack=false
    C->>A: SyncToken 123, token Z, ack=true
    note over A: All tokens received and match
    A->>D: Welcome 123, X=Leader, Y=456, Z=789
    B->>C: SyncToken 123, token Y, ack=false
    note over C: All tokens received and match
    C->>B: SyncToken 123, token Z, ack=true
    note over B: All tokens received and match
    B->>D: Welcome 123, X=Leader, Y=456, Z=789
    C->>D: Welcome 123, X=Leader, Y=456, Z=789
    note over D: Now has all Welomes and they all match.<br>Member now knows how to<br>identify everyone in this group.<br>Starts making new group specific connections
    D->>A: Establish new queue for this group/member
    A->>D: Establish new queue for this group/member
    A->>A: Established 123
    D->>B: Establish new queue for this group/member
    B->>D: Establish new queue for this group/member
    B->>A: Established 123
    D->>C: Establish new queue for this group/member
    note over C: Goes permanently offline
    note over A: Knows that A and B established connections<br>but C has not<br>decides to kick C via his original invitation id (456)
    A->>A: Kick 456
    note over A: Commits that 456 is permanently kicked
    A->>A: Kicked 456
    A->>B: Kick 456
    note over B: Commits that 456 is permanently kicked
    B->>A: Kicked 456
    A->>D: Kick 456
    note over D: Commits that 456 is permanently kicked
    D->>A: Kicked 456
    note over A: proposal 123 complete with D added and C removed
```

##### CLI Interactions

The leader can handle the cancellation directly:

```bash
> /pending #g
> Member @B is trying to add @D.  You and @B have added @D, waiting on @C.  You may wait, cancel the invite, or kick @C: (wait/cancel/kick)
> kick
```

Or the leader may discover the issue when attempting a (blocked) membership change:

```bash
> Member @B wants to add @X to #g, but there is a pending invite to @D (only one at a time is allowed). You and @B have added @D, waiting on @C.  You may wait, cancel the invite, or kick @C: (wait/cancel/kick)
> y
```

## Variations Not Pursued

### Centralized Tokens

It may seem odd that a Leader is leveraged for the management of proposals, but a more peer-to-peer style token synchronization step is also involved later.
Message counts could be reduced if the leader was also responsible for validating tokens.
However, this puts increased trust on the leader.
The peer-to-peer style token synchronization ensures that a compromised leader has limited impacts to the group as a whole.
