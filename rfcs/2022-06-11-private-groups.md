# Private Groups

An alternate groups approach that preserves more privacy properties.
These groups can only be formed if all members already have direct connections to all other members.
This eliminates the need for implicit introductions, which offer vectors for MITM attacks.
Critically, we can ensure that we don't reveal any information about a user's network, other than what they opt into sharing for adjusting membership.
Lastly, we require no modification to the underlying protocol.
Standard duplex communication is sufficient.
Agents need new behavior in soliciting proposals for membership changes, and for responding to them.

## The Protocol

To give a high-level summary, we at first ignore contention in desired membership changes.

### Additions

A formal specification of the protocol is defined in TLA+ and can be defined [here](./2022-06-11-private-groups/groups_invite_without_competition.tla).

#### Proposer (phase 1)

To add a group member, a current member proposes a contact (henceforth the proposer and invitee respectively).
The proposer generates a random invitation identifier and a token.
They broadcast these to all other current members as a Propose message, also including an informal contact description (such as their contact name).

The proposer also sends an Invite message to the invitee that includes their token and the current membership count of the group.

#### Non-Proposing Member (phase 1)

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
  1. Broadcast a SyncToken message that includes the invitation identifier and their token.
  1. Send an Invite message to the invitee that includes the invitation identifier, their token, and the count of current members.

The choice to accept or reject and the generated token should be locally committed before sending messages so conflicting messages are not sent.

_TODO: If a malicious member receives all tokens from the other members, they can then fabricate legitimate Accept messages.
However, members must only listen to an Accept messages from the user they invited (who they believe to be the invitee).
This means that when all members agree on the invitee, the ability to fabricate an Accept message is useless.
When member(s) mistake the invitee for a collaborator of the malicious member, the malicious member can help the collaborator trick the confused member into accepting the collaborator's membership.
Seemingly, this offers little benefit, because the malicious parties cannot fool any other member.
The confused party now believes the collaborator to be part of the group, but to what end?
This can be avoided by moving the TokenSync messages to after receipt of the Accept message, but is less efficient._

#### Invitee

The invitee collects all Invite messages.
While they cannot predict who they are waiting for, each invite includes the number of members in the group.
Upon receipt of Invites from that number that all have the same invitation identifier, the proposer now knows the full membership of the group and the user should be prompted as to whether or not to accept membership.
If they decline, it is sufficient to ignore the messages, but more efficient to send a messages as such.

To accept, the invitee responds to all contacts with an Accept message that includes the invitation identifier and all tokens.

In the case of contact confusion between members, it is impossible for anyone outside of the group to send an Accept message as they never collect the correct number of tokens.

#### Members (phase 2)

Once a member has received a SyncToken message from all other non-proposing members and an Accept message from the invitee, they compare the tokens received.
If the invitee can present a match, then the member now knows that all parties have agreed to extend membership.
The member locally commits this result and establishes a new connection with the invitee specifically for group communication.

#### Properties

Model checking our formal specification we can demonstrate three key properties:
  1. Users outside of the group only learn about the networks of members who agree to share such information with them.
  1. It is not possible to accidentally establish a group connection with anyone other than the invitee, even if users misidentify the invitee.
  1. No members will connect with the invitee unless all members correctly identify them.
