---- MODULE groups ----

EXTENDS Naturals, FiniteSets

CONSTANTS
    Users,
    \* The user that starts the group orchestrates all proposals for changes in
    \* membership.  Typically, we would want to avoid a central entity as an
    \* orchestrator, due to the lack of fault tolerance.  However, this
    \* algorithm can only succeed with participation of all parties, since we
    \* need to prove that all members are already directly connected to the
    \* newly invited user.  A predetermined leader simplifies the algorithm
    \* without a loss of fault tolerance.
    InitialMembers,
    \* TODO: We should call this Null, since we're using null semantics, not
    \* Maybe semantics (or use Maybe semantics)
    Nothing,
    (*
    This function describes indirect perceptions about contact descriptions.
    We can translate "user_percetions[[ perceiver |-> userA, description |-> [
    by |-> userB, of |-> userC]]] = userD" into the english statement: "userA
    thinks that when userB describes userC they are referring to userD."  It's
    possible that userA knows the correct answer (userD = userC), they don't
    know who userB is talking about (userD = Nothing) or they mistake userC for
    someone else (userD /= Nothing /\ userD /= userC).
    A description is uniquely identified by the user describing and the user
    being described.  However, the description itself should be treated
    opaquely by users, since they must guess at who is being described, they
    cannot ever have access to the internal thoughts of others.
    *)
    UserPerceptions,
    Connections,
    \* Proposal States
    Proposing,
    Holding,
    Continuing,
    \* Approver States
    Active,
    OnHold,
    Committed,
    \* Request Type
    PleasePropose,
    Propose,
    Reject,
    Hold,
    CantHold,
    WillHold,
    Continue,
    Invite,
    Accept,
    SyncToken

VARIABLES
    messages,
    \* TODO: invites and token should be separated, which allows us to check
    \* liveness under the condition that the number of proposals is
    \* constrained.  The number of max number of tokens necessary is then
    \* fairly easily derived (if we also limit the number available for
    \* attackers).
    rng_state,
    group_perceptions,
    proposal,
    complete_proposals,
    approver_states,
    tokens

ASSUME
    /\ InitialMembers \subseteq Users
    /\ Cardinality(InitialMembers) >= 1
    /\ UserPerceptions \in [ [ perceiver : Users, description : [ by : Users, of : Users ] ] -> Users \union { Nothing } ]
    \* A user always correctly knows their own perceptions
    /\ \A user1, user2 \in Users : UserPerceptions[[ perceiver |-> user1, description |-> [ by |-> user1, of |-> user2 ]]] = user2
    /\ Connections \subseteq (Users \X Users)

Leader ==
    CHOOSE x \in InitialMembers : TRUE

InviteIds == Nat

HasDirectConnection(x, y) ==
    \/ x = y
    \/ <<x, y>> \in Connections
    \/ <<y, x>> \in Connections

Init ==
    /\ messages = {}
    /\ rng_state = 0
    (*
    Notably, group members learn about the changes to the group at different
    times, so we need to track their changes in perception individually.
    The empty set means the user doesn't believe themselves to be part of the
    group (they might actually know who some members are).
    *)
    /\ group_perceptions = [ x \in Users |-> IF x \in InitialMembers THEN InitialMembers ELSE {} ]
    /\ proposal = Nothing
    /\ complete_proposals = {}
    /\ approver_states = [ x \in (InviteIds \X Users) |-> Nothing ]
    /\ tokens = [ x \in (InviteIds \X Users) |-> Nothing ]

SendPleasePropose ==
    \* IMPORTANT: The user should still wait to receive a Propose message from
    \* the leader before acting further, since they can't send an Invite
    \* message yet anyway.  The Leader might be queuing a number of proposals,
    \* and this one could be happening after another, meaning the group size,
    \* which is important for correct invitee behaviour, cannot be known until
    \* the Leader officially starts this proposal.
    \E proposer \in Users, invitee \in Users :
        /\ proposer \in group_perceptions[proposer]
        /\ invitee \notin group_perceptions[proposer]
        /\ HasDirectConnection(proposer, invitee)
        /\ messages' = messages \union
            {   [ type |-> PleasePropose
                , sender |-> proposer
                , recipient |-> Leader
                , invite_id |-> rng_state
                , invitee_description |-> [ by |-> proposer, of |-> invitee ]
                ]
            }
        /\ rng_state' = rng_state + 1
        /\ UNCHANGED <<group_perceptions, proposal, complete_proposals, approver_states, tokens>>

LeaderReceivePleasePropose ==
    \E message \in messages :
        /\ message.type = PleasePropose
        /\ message.recipient = Leader
        /\ message.invite_id \notin complete_proposals
        /\ proposal = Nothing
        \* NOTE: As a slight optimization, the Leader can synchronously accept or reject.
        /\ proposal' =
            [ invite_id |-> message.invite_id
            , invitee_description |-> message.invitee_description
            , group_size |-> Cardinality(group_perceptions[Leader])
            , state |-> Proposing
            ]
        /\ UNCHANGED <<messages, rng_state, group_perceptions, complete_proposals, approver_states, tokens>>

BroadcastProposalState ==
    \E member \in Users :
        /\ proposal /= Nothing
        /\ member \in group_perceptions[Leader]
        /\ messages' = messages \union
            {   IF  proposal.state = Proposing
                THEN
                    [ sender |-> Leader
                    , recipient |-> member
                    , type |-> Propose
                    , invite_id |-> proposal.invite_id
                    , invitee_description |-> proposal.invitee_description
                    , group_size |-> proposal.group_size
                    ]
                ELSE
                    [ sender |-> Leader
                    , recipient |-> member
                    , type |->
                        CASE proposal.state = Holding -> Hold
                          [] proposal.state = Continuing -> Continue
                    , invite_id |-> proposal.invite_id
                    ]
            }
        /\ UNCHANGED <<rng_state, group_perceptions, proposal, complete_proposals, approver_states, tokens>>

LeaderReceiveReject ==
    \E message \in messages :
        /\ message.type = Reject
        /\ message.recipient = Leader
        /\ message.invite_id \notin complete_proposals
        /\ proposal = Nothing
        /\ message.invite_id = proposal.invite_id
        /\ complete_proposals' = complete_proposals \union { message.invite_id }
        /\ UNCHANGED <<messages, rng_state, group_perceptions, proposal, approver_states, tokens>>

\* We don't specify exactly why, but at some point a Leader may realize that a
\* proposal is likely doomed, even if they never heard a rejection (proposals
\* with confused contacts can never resolve), and abort the proposal.
GiveUpOnProposal ==
    /\ proposal /= Nothing
    /\ proposal.state = Proposing
    /\ proposal' = [ proposal EXCEPT !.state = Holding ]
    /\ UNCHANGED <<messages, rng_state, group_perceptions, complete_proposals, approver_states, tokens>>

LeaderReceiveCantHold ==
    \E message \in messages :
        /\ message.type = CantHold
        /\ message.recipient = Leader
        /\ proposal /= Nothing
        /\ message.invite_id = proposal.invite_id
        /\ proposal.state = Holding
        /\ proposal' = [ proposal EXCEPT !.state = Continuing ]
        /\ UNCHANGED <<messages, rng_state, group_perceptions, complete_proposals, approver_states, tokens>>

LeaderReceiveAllHolds ==
    /\ proposal /= Nothing
    /\ \A member \in group_perceptions[Leader] :
        \* TODO: This gets a bit problematic when we need to limit the number
        \* of messages in flight
        \E message \in messages :
            /\ message.type = WillHold
            /\ message.sender = member
            /\ message.recipient = Leader
            /\ message.invite_id = proposal.invite_id
    /\ proposal' = Nothing
    /\ complete_proposals' = complete_proposals \union { proposal.invite_id }
    /\ UNCHANGED <<messages, rng_state, group_perceptions, approver_states, tokens>>

ApproverReceiveProposal ==
    \E message \in messages :
        /\ message.type = Propose
        /\ IF   /\ UserPerceptions[[ perceiver |-> message.recipient, description |-> message.invitee_description]] /= Nothing
                /\ HasDirectConnection(message.recipient, UserPerceptions[[ perceiver |-> message.recipient, description |-> message.invitee_description]])
           THEN /\ IF   tokens[<<message.invite_id, message.recipient>>] = Nothing
                   THEN /\ tokens' = [ tokens EXCEPT ![<<message.invite_id, message.recipient>>] = rng_state ]
                        /\ rng_state' = rng_state + 1
                        /\ approver_states' = [ approver_states EXCEPT ![<<message.invite_id, message.recipient>>] = Active ]
                   ELSE UNCHANGED <<tokens, rng_state, approver_states>>
                \* It's safe to send this message right away, as it only agrees to
                \* reveal information that everyone has agreed to share.  The invitee
                \* now knows that there's a group that involves this member, the
                \* proposer, and any other members that have sent this message, giving
                \* the invitee insight into how these contacts are all connected.
                \* However, that is exactly what they all just agreed to.  Members that
                \* don't agree to send this message remain private.
                /\ messages' = messages \union
                    {   [ sender |-> message.recipient
                        , recipient |-> UserPerceptions[[ perceiver |-> message.recipient, description |-> message.invitee_description]]
                        , type |-> Invite
                        , invite_id |-> message.invite_id
                        , token |-> tokens'[<<message.invite_id, message.recipient>>]
                        , group_size |-> message.group_size
                        ]
                    }
                /\ UNCHANGED <<group_perceptions, proposal, complete_proposals>>
           ELSE /\ messages' = messages \union
                    {   [ sender |-> message.recipient
                        , recipient |-> Leader
                        , type |-> Reject
                        , invite_id |-> message.invite_id
                        ]
                    }
                /\ UNCHANGED <<rng_state, group_perceptions, proposal, complete_proposals, approver_states, tokens>>

ApproverReceiveHold ==
    \E message \in messages :
        /\ message.type = Hold
        /\ IF   approver_states[<<message.invite_id, message.recipient>>] = Committed
           THEN /\ messages' = messages \union
                    {   [ type |-> CantHold
                        , sender |-> message.recipient
                        , recipient |-> Leader
                        , invite_id |-> message.invite_id
                        ]
                    }
                /\ UNCHANGED <<approver_states>>
           \* TODO: For the moment, we enforce that we must hear a proposal
           \* message before holding, because it simplifies token generation.
           \* However, it's not live, because if the Propose message is dropped
           \* and now the Leader is only sending Hold messages, this node is
           \* going to ignore everything.
           ELSE /\ approver_states[<<message.invite_id, message.recipient>>] = Active
                /\ approver_states' = [ approver_states EXCEPT ![<<message.invite_id, message.recipient>>] = OnHold ]
                \* TODO: This can't be atomic
                /\ messages' = messages \union
                    {   [ type |-> WillHold
                        , sender |-> message.recipient
                        , recipient |-> Leader
                        , invite_id |-> message.invite_id
                        ]
                    }
        /\ UNCHANGED <<rng_state, group_perceptions, proposal, complete_proposals, tokens>>

BroadcastToken ==
    \E from \in Users, invite_id \in InviteIds :
        \E to \in (group_perceptions[from] \ { from }) :
            /\ tokens[<<invite_id, from>>] /= Nothing
            /\ messages' = messages \union
                {   [ sender |-> from
                    , recipient |-> to
                    , type |-> SyncToken
                    , token |-> tokens[<<invite_id, from>>]
                    , invite_id |-> invite_id
                    ]
                }
            /\ UNCHANGED <<rng_state, group_perceptions, proposal, complete_proposals, approver_states, tokens>>

\* IMPORTANT: It is NOT inviariant that the invitee matches across the same
\* invite_id, because some members may have confused the invitee.
GetInvites(invite_id, invitee) ==
    { message \in messages : message.type = Invite /\ message.recipient = invitee /\ message.invite_id = invite_id }

SendAccept ==
    \E message \in messages :
        /\ message.type = Invite
        /\ LET  invitee == message.recipient
                invite_id == message.invite_id
                Invites == GetInvites(invite_id, invitee)
                Inviters == { invite.sender : invite \in Invites }
                Tokens == { invite.token : invite \in Invites }
           IN   IF   Cardinality(Inviters) = message.group_size
                THEN
                    \E member \in Inviters :
                        \* IMPORTANT: The Accept may still has a chance of
                        \* being ignored (or token mismatch or something odd),
                        \* so the invitee does not yet believe themself to be
                        \* part of the group.  At least one member must
                        \* establish a connection with them first.
                        /\ messages' = messages \union
                            {   [ sender |-> invitee
                                , recipient |-> member
                                , type |-> Accept
                                , tokens |-> Tokens
                                , invite_id |-> invite_id
                                ]
                            }
                ELSE UNCHANGED <<messages>>
        /\ UNCHANGED <<rng_state, group_perceptions, proposal, complete_proposals, approver_states, tokens>>

Establish ==
    \E message \in messages :
        /\ message.type = Accept
        /\ LET SyncMessages == { sync \in messages : sync.recipient = message.recipient /\ sync.type = SyncToken /\ sync.invite_id = message.invite_id }
               Senders == { sync.sender : sync \in SyncMessages }
               Tokens == { sync.token : sync \in SyncMessages } \union { tokens[<<message.invite_id, message.recipient>>] }
           IN  /\ Senders = (group_perceptions[message.recipient] \ { message.recipient })
               /\ message.tokens = Tokens
               /\ approver_states[<<message.invite_id, message.recipient>>] = Active
               /\ approver_states' = [ approver_states EXCEPT ![<<message.invite_id, message.recipient>>] = Committed ]
               \* TODO: This can't be atomic
               /\ group_perceptions' =
                   [ group_perceptions
                   EXCEPT ![message.recipient] = @ \union { message.sender }
                   \* If this is the first member to establish, the invitee
                   \* now knows they are in the group with everyone who
                   \* invited them
                   , ![message.sender] =
                       IF @ = {}
                       THEN { invite.sender : invite \in GetInvites(message.invite_id, message.sender) } \union { message.sender }
                       ELSE @
                   ]
               /\  IF  /\ proposal /= Nothing
                       /\ proposal.invite_id = message.invite_id
                       /\ message.recipient = Leader
                   THEN
                       /\ complete_proposals' = complete_proposals \union { message.invite_id }
                       /\ proposal' = Nothing
                   ELSE UNCHANGED <<proposal, complete_proposals>>
               /\ UNCHANGED <<messages, rng_state, tokens>>

\* TODO: If a user reported that they committed to a invitation, the Leader
\* needs to notify all users to resume the invitation.

\* TODO: Need to be able to Kick.  Notably, this is easier, because we don't
\* need to confirm identities.

\* TODO: Need to be able to kick users who are preventing progress in an
\* invitation.  Any user who is not responding to a Hold is safely kickable.
\* In the worst case, the kicked user(s) did establish a connection with the
\* invitee, meaning the kicked and invitee still think they are part of the
\* group, even though they've been kicked out.  Ideally, they can eventually
\* learn that they are kicked out.  Once kicked, it's safe to send a Cancel
\* message to all other members.  In fact, the kicked members can be
\* piggy-backed on the Cancel message.  Then new invites can be sent.


(*
TODO: Byzantine Modeling
This is actually a bit easier than it at first seems.  First, we consider only
one attacker (or a group of fully coordinated attackers), since this is
obviously worse than multiple independent attackers). We should add two
constants, CompromisedConnections and CompromisedUsers.  The former represents
the Connections with a MITM, where the attacker may see all messages, block
legitimate messages, or fabricate messages from either user that look
authentic.  The latter represents a user that is either working with or
corrupted by the attacker, where the attacker may see all messages, drop
legitimate messages, or fabricate messages from the compromised user.

In order to fabricate messages, the attacker assembles messages from various
pieces of any message it can see.  It can also generate a set of random values
that it can use at any time.  Blocked messages must be moved to a special
variable so that the attacker can "remember" their composite parts, even though
they prevent their transmition.

In order to represent an attacker setting up new MITM connections, we need to
model the connection process more explicitly.

Invariants become a bit more challenging.  For example, "all parties should
agree to new members."  A corrupted member doesn't really have a choice in the
matter.  We potentially need a new variable as to whether or not a user trusts
the group, where a user that sees evidence of tampering can stop all further
participation.  In this case we need to ensure that users always trust valid
groups, but ideally they always detect when tampering has occurred (notably,
silent agents are undetectable!).
*)


Next ==
    \/ SendPleasePropose
    \/ LeaderReceivePleasePropose
    \/ BroadcastProposalState
    \/ LeaderReceiveReject
    \/ GiveUpOnProposal
    \/ LeaderReceiveCantHold
    \/ LeaderReceiveAllHolds
    \/ ApproverReceiveProposal
    \/ ApproverReceiveHold
    \/ BroadcastToken
    \/ SendAccept
    \/ Establish

Spec == Init /\ [][Next]_<<messages, rng_state, group_perceptions, proposal, complete_proposals, approver_states, tokens>>


CannotCommunicateWithoutAConnection ==
    \A message \in messages :
        HasDirectConnection(message.sender, message.recipient)

TokensMatch ==
    \A message \in messages :
        message.type = Invite =>
            message.token = tokens[<<message.invite_id, message.sender>>]

GroupSizesMatch ==
    \A message1, message2 \in messages :
        /\ message1.type = Invite
        /\ message2.type = Invite
        /\ message1.invite_id = message2.invite_id
        => message1.group_size = message2.group_size

\* Anyone that receives two invites which share an invite id, knows that
\* these two contacts know each other and that they are in a group together
\* with N people.
\* This kind of correlation should only be possible if the invite senders
\* agreed to invite that individual, meaning that they are willing to divulge
\* to the invitee that they know all members of the group.  We check this by
\* seeing if they generated a token for this invite (which means accepting the
\* proposal).
NonMembersOnlyKnowMembersKnowEachOtherIfMembersAcceptedProposal ==
    \A message1, message2 \in messages :
        \/ message1 = message2
        \/  /\ message1.type = Invite
            /\ message2.type = Invite
            /\ message1.recipient = message2.recipient
            /\ message1.invite_id = message2.invite_id
            =>  /\ tokens[<<message1.invite_id, message1.sender>>] /= Nothing
                /\ tokens[<<message2.invite_id, message2.sender>>] /= Nothing

AllMembers ==
    UNION { group_perceptions[x] : x \in Users }

MembersOnlyEstablishWithInvitee ==
    \A member \in (AllMembers \ InitialMembers) :
        \E message \in messages :
            /\ message.type = Propose
            /\ message.invitee_description.of = member

AllMembersAreConnectedToAllOtherMembers ==
    \A member1, member2 \in AllMembers :
        \/ member1 = member2
        \/ HasDirectConnection(member1, member2)

EstablishedOnlyIfAllPerceptionsMatch ==
    \A member \in AllMembers :
        \A message \in messages :
            /\ message.type = Propose
            /\ message.invitee_description.of = member
            => UserPerceptions[[ perceiver |-> message.recipient, description |-> message.invitee_description ]] = member

====
