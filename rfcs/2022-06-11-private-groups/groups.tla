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
    InviteIds,
    KickIds,
    \* Proposal States
    Proposing,
    Holding,
    Continuing,
    Kicking,
    \* Approver States
    Active,
    OnHold,
    Resumed,
    Committed,
    \* Request Type
    PleasePropose,
    Propose,
    Reject,
    Hold,
    CantHold,
    WillHold,
    Continue,
    Kick,
    KickAck,
    Invite,
    Accept,
    SyncToken

VARIABLES
    messages,
    rng_state,
    group_perceptions,
    proposal,
    complete_proposals,
    approver_states

ASSUME
    /\ (InviteIds \intersect KickIds) = {}
    /\ InitialMembers \subseteq Users
    /\ Cardinality(InitialMembers) >= 1
    /\ UserPerceptions \in [ [ perceiver : Users, description : [ by : Users, of : Users ] ] -> Users \union { Nothing } ]
    \* A user always correctly knows their own perceptions
    /\ \A user1, user2 \in Users : UserPerceptions[[ perceiver |-> user1, description |-> [ by |-> user1, of |-> user2 ]]] = user2
    /\ Connections \subseteq (Users \X Users)

Leader ==
    CHOOSE x \in InitialMembers : TRUE

HasDirectConnection(x, y) ==
    \/ x = y
    \/ <<x, y>> \in Connections
    \/ <<y, x>> \in Connections

Init ==
    /\ messages = {}
    /\ rng_state = InviteIds
    (*
    Notably, group members learn about the changes to the group at different
    times, so we need to track their changes in perception individually.
    The empty set means the user doesn't believe themselves to be part of the
    group (they might actually know who some members are).
    *)
    /\ group_perceptions = [ x \in Users |-> IF x \in InitialMembers THEN InitialMembers ELSE {} ]
    /\ proposal = Nothing
    /\ complete_proposals = {}
    /\ approver_states = [ x \in ((InviteIds \union KickIds) \X Users) |-> Nothing ]

SendPleasePropose ==
    \* IMPORTANT: The user should still wait to receive a Propose message from
    \* the leader before acting further, since they can't send an Invite
    \* message yet anyway.  The Leader might be queuing a number of proposals,
    \* and this one could be happening after another, meaning the group size,
    \* which is important for correct invitee behaviour, cannot be known until
    \* the Leader officially starts this proposal.
    \E proposer \in Users, invitee \in Users :
        /\ Cardinality(rng_state) > 0
        /\ LET invite_id == CHOOSE x \in rng_state : TRUE
           IN
            /\ proposer \in group_perceptions[proposer]
            /\ invitee \notin group_perceptions[proposer]
            /\ HasDirectConnection(proposer, invitee)
            /\ messages' = messages \union
                {   [ type |-> PleasePropose
                    , sender |-> proposer
                    , recipient |-> Leader
                    , invite_id |-> invite_id
                    , invitee_description |-> [ by |-> proposer, of |-> invitee ]
                    ]
                }
            /\ rng_state' = rng_state \ { invite_id }
            /\ UNCHANGED <<group_perceptions, proposal, complete_proposals, approver_states>>

LeaderReceivePleasePropose ==
    \E message \in messages :
        /\ message.type = PleasePropose
        /\ message.recipient = Leader
        /\ message.sender \in group_perceptions[Leader]
        /\ message.invite_id \notin complete_proposals
        /\ proposal = Nothing
        \* NOTE: As a slight optimization, the Leader can synchronously accept or reject.
        /\ proposal' =
            [ invite_id |-> message.invite_id
            , invitee_description |-> message.invitee_description
            , group_size |-> Cardinality(group_perceptions[Leader])
            , state |-> Proposing
            , awaiting_response |-> Nothing
            ]
        /\ UNCHANGED <<messages, rng_state, group_perceptions, complete_proposals, approver_states>>

BroadcastProposalState ==
    \E member \in Users :
        /\ proposal /= Nothing
        /\ member \in group_perceptions[Leader]
        /\ messages' = messages \union
            {   CASE proposal.state = Proposing ->
                    [ sender |-> Leader
                    , recipient |-> member
                    , type |-> Propose
                    , invite_id |-> proposal.invite_id
                    , invitee_description |-> proposal.invitee_description
                    , group_size |-> proposal.group_size
                    ]
                  [] proposal.state = Kicking ->
                    [ sender |-> Leader
                    , recipient |-> member
                    , type |-> Kick
                    , kick_id |-> proposal.kick_id
                    , kicked |-> proposal.kicked
                    ]
                  [] TRUE ->
                    [ sender |-> Leader
                    , recipient |-> member
                    , type |->
                        CASE proposal.state = Holding -> Hold
                          [] proposal.state = Continuing -> Continue
                    , invite_id |-> proposal.invite_id
                    ]
            }
        /\ UNCHANGED <<rng_state, group_perceptions, proposal, complete_proposals, approver_states>>

LeaderReceiveReject ==
    \E message \in messages :
        /\ message.type = Reject
        /\ message.recipient = Leader
        /\ message.invite_id \notin complete_proposals
        /\ proposal = Nothing
        /\ proposal.state = Proposing
        /\ message.invite_id = proposal.invite_id
        /\ complete_proposals' = complete_proposals \union { message.invite_id }
        /\ UNCHANGED <<messages, rng_state, group_perceptions, proposal, approver_states>>

\* We don't specify exactly why, but at some point a Leader may realize that a
\* proposal is likely doomed, even if they never heard a rejection (proposals
\* with confused contacts can never resolve), and abort the proposal.
GiveUpOnProposal ==
    /\ proposal /= Nothing
    /\ proposal.state = Proposing
    /\ proposal' = [ proposal EXCEPT !.state = Holding, !.awaiting_response = group_perceptions[Leader] ]
    /\ UNCHANGED <<messages, rng_state, group_perceptions, complete_proposals, approver_states>>

LeaderReceiveCantHold ==
    \E message \in messages :
        /\ message.type = CantHold
        /\ message.recipient = Leader
        /\ proposal /= Nothing
        /\ proposal.state = Holding
        /\ message.invite_id = proposal.invite_id
        /\ proposal' = [ proposal EXCEPT !.state = Continuing, !.awaiting_response = Nothing ]
        /\ UNCHANGED <<messages, rng_state, group_perceptions, complete_proposals, approver_states>>

LeaderReceiveHold ==
    /\ proposal /= Nothing
    /\ proposal.state = Holding
    /\ \E message \in messages :
        /\ message.type = WillHold
        /\ message.recipient = Leader
        /\ message.invite_id = proposal.invite_id
        /\ IF   proposal.awaiting_response = { message.sender }
           THEN /\ proposal' = Nothing
                /\ complete_proposals' = complete_proposals \union { proposal.invite_id }
           ELSE /\ proposal' = [ proposal EXCEPT !.awaiting_response = @ \ { message.sender } ]
                /\ UNCHANGED <<complete_proposals>>
        /\ UNCHANGED <<messages, rng_state, group_perceptions, approver_states>>

\* We don't specify exactly why, but this would likely be a human decision
\* based on trying to start a _new_ proposal, but that not being possible
\* because of a pending one.  It would then show the users that are not
\* cooperating and would offer to kick them.  It's also possible that when
\* trying to kick someone, another member goes unresponsive, meaning we need to
\* start a new round of kicking.
GiveUpOnMembers ==
    /\ proposal /= Nothing
    /\ proposal.state = Holding
    \* Leader can't be kicked.  Realistically, they should just act
    \* synchronously when giving up on a proposal.
    /\ Leader \notin proposal.awaiting_response
    /\ Cardinality(KickIds) > 0
    /\ LET kick_id == CHOOSE x \in KickIds : TRUE
           new_group == group_perceptions[Leader] \ proposal.awaiting_response
       IN
        /\ complete_proposals' = complete_proposals \union { proposal.invite_id }
        /\ proposal' =
            [ state |-> Kicking
            , kick_id |-> kick_id
            , awaiting_response |-> new_group
            \* TODO: it's not really implementable to just send the users
            \* directly, because every user talks to each user via totally
            \* different channels with no unified identifier.  Some options for
            \* identifying users is by join order (index, which invitees
            \* curretnly know about themselves but for anyone else), original
            \* description (this currently isn't shared with the invitee), or
            \* by invite_id (which everyone can currently know).
            , kicked |-> proposal.awaiting_response
            ]
        /\ UNCHANGED <<messages, rng_state, group_perceptions, approver_states>>

ApproverReceiveProposal ==
    \E message \in messages :
        /\ message.type = Propose
        /\ IF   /\ UserPerceptions[[ perceiver |-> message.recipient, description |-> message.invitee_description]] /= Nothing
                /\ HasDirectConnection(message.recipient, UserPerceptions[[ perceiver |-> message.recipient, description |-> message.invitee_description]])
           THEN /\ approver_states[<<message.invite_id, message.recipient>>] = Nothing
                /\ approver_states' = [ approver_states EXCEPT ![<<message.invite_id, message.recipient>>] = Active ]
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
                        \* Token generation is abstract/symbolic.  Instead of
                        \* the actual value of our token, we just name the
                        \* generator and its purpose.  That means that 1:1
                        \* mapping of a token to an invite_id is implied, and
                        \* it means that approvers must permanently commit to
                        \* the choice of the token before issuing it.  It is
                        \* critical that this spec treats a token as opaque,
                        \* passing around only its value, not looking inside,
                        \* or "generating" on in the wrong context, or our spec
                        \* may be impossible to implement.
                        , token |-> [ for |-> message.invite_id, by |-> message.recipient ]
                        , group_size |-> message.group_size
                        ]
                    }
                /\ UNCHANGED <<rng_state, group_perceptions, proposal, complete_proposals>>
           ELSE /\ messages' = messages \union
                    {   [ sender |-> message.recipient
                        , recipient |-> Leader
                        , type |-> Reject
                        , invite_id |-> message.invite_id
                        ]
                    }
                /\ UNCHANGED <<rng_state, group_perceptions, proposal, complete_proposals, approver_states>>

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
        /\ UNCHANGED <<rng_state, group_perceptions, proposal, complete_proposals>>

ApproverReceiveContinue ==
    \E message \in messages :
        /\ message.type = Continue
        /\ \/ approver_states[<<message.invite_id, message.recipient>>] = OnHold
           \* If we see a Continue while Active, we can assume that we missed
           \* the Hold, and can just skip right to the Resumed state
           \/ approver_states[<<message.invite_id, message.recipient>>] = Active
        /\ approver_states' = [ approver_states EXCEPT ![<<message.invite_id, message.recipient>>] = Resumed ]
        \* TODO: Currently, this isn't live, because the approver only sends
        \* Invites on Propose messages.  Since it's possible that the approver
        \* never received a Propose message at all, the Resume message needs to
        \* carry enough information that the approver can form an invitation
        \* from it.  Then it will act as a reminder that makes approvers live
        \* (if the Leader is).
        /\ UNCHANGED <<messages, rng_state, group_perceptions, proposal, complete_proposals>>

ApproverReceiveKick ==
    \E message \in messages :
        /\ message.type = Kick
        /\ message.sender = Leader
        /\ approver_states' = [ approver_states EXCEPT ![<<message.kick_id, message.recipient>>] = Committed ]
        /\ group_perceptions' = [ group_perceptions EXCEPT ![message.recipient] = @ \ message.kicked ]
        /\ messages' = messages \union
            {   [ type |-> KickAck
                , sender |-> message.recipient
                , recipient |-> message.sender
                , kick_id |-> message.kick_id
                ]
            }
        /\ UNCHANGED <<rng_state, proposal, complete_proposals>>

BroadcastToken ==
    \E from \in Users, invite_id \in InviteIds :
        \E to \in (group_perceptions[from] \ { from }) :
            /\ approver_states[<<invite_id, from>>] /= Nothing
            /\ messages' = messages \union
                {   [ sender |-> from
                    , recipient |-> to
                    , type |-> SyncToken
                    \* Note again that tokens are abstract/symbolic.  In this
                    \* context, the spec implies that this is using a
                    \* pregenerated token that is permanently associated for
                    \* this invite_id.
                    , token |-> [ for |-> invite_id, by |-> from ]
                    , invite_id |-> invite_id
                    ]
                }
            /\ UNCHANGED <<rng_state, group_perceptions, proposal, complete_proposals, approver_states>>

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
        /\ UNCHANGED <<rng_state, group_perceptions, proposal, complete_proposals, approver_states>>

Establish ==
    \E message \in messages :
        /\ message.type = Accept
        /\ LET SyncMessages == { sync \in messages : sync.recipient = message.recipient /\ sync.type = SyncToken /\ sync.invite_id = message.invite_id }
               Senders == { sync.sender : sync \in SyncMessages }
               \* Note that it's safe to "access" "its" token here
               Tokens == { sync.token : sync \in SyncMessages } \union { [ for |-> message.invite_id, by |-> message.recipient ] }
           IN  /\ Senders = (group_perceptions[message.recipient] \ { message.recipient })
               /\ message.tokens = Tokens
               /\  \/ approver_states[<<message.invite_id, message.recipient>>] = Active
                   \/ approver_states[<<message.invite_id, message.recipient>>] = Resumed
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
               /\  IF  message.recipient = Leader
                   THEN
                       /\ proposal /= Nothing
                       /\ proposal.state \in { Proposing, Continuing }
                       /\ proposal.invite_id = message.invite_id
                       /\ complete_proposals' = complete_proposals \union { message.invite_id }
                       /\ proposal' = Nothing
                   ELSE UNCHANGED <<proposal, complete_proposals>>
               /\ UNCHANGED <<messages, rng_state>>

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

\* TODO: An irony of cancellation is that while the proposal is "done" from the
\* perspective that the user cannot be added to the portion of the group that
\* was holding, we then need acks for cancellation so the Leader can stop
\* sending Cancel or Kick messages.  It's possible however that one of these
\* members then goes offline forever!  The only way to handle that would then
\* be to Kick them too...  So we end up in a place where we have Kicks for
\* Kicks for Kicks for Kicks....


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
    \/ LeaderReceiveHold
    \/ GiveUpOnMembers
    \/ ApproverReceiveProposal
    \/ ApproverReceiveHold
    \/ ApproverReceiveContinue
    \/ ApproverReceiveKick
    \/ BroadcastToken
    \/ SendAccept
    \/ Establish

Spec == Init /\ [][Next]_<<messages, rng_state, group_perceptions, proposal, complete_proposals, approver_states>>


CannotCommunicateWithoutAConnection ==
    \A message \in messages :
        HasDirectConnection(message.sender, message.recipient)

TokensMatch ==
    \A message \in messages :
        message.type = Invite \/ message.type = SyncToken =>
            /\ message.token = [ for |-> message.invite_id, by |-> message.sender ]
            /\ approver_states[<<message.invite_id, message.sender>>] /= Nothing

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
\* seeing if they have a state for the invite_id that brought.
NonMembersOnlyKnowMembersKnowEachOtherIfMembersAcceptedProposal ==
    \A message1, message2 \in messages :
        \/ message1 = message2
        \/  /\ message1.type = Invite
            /\ message2.type = Invite
            /\ message1.recipient = message2.recipient
            /\ message1.invite_id = message2.invite_id
            =>  /\ approver_states[<<message1.invite_id, message1.sender>>] /= Nothing
                /\ approver_states[<<message2.invite_id, message2.sender>>] /= Nothing

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
