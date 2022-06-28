---- MODULE groups ----

EXTENDS Naturals, FiniteSets, util

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
    \* Proposal States
    Proposing,
    Kicking,
    \* Approver States
    Active,
    Committed,
    \* Request Type
    PleasePropose,
    Propose,
    Reject,
    Established,
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

MemberSet == [ user : Users, id : InviteIds \union { Nothing } ]

ASSUME
    /\ InitialMembers \subseteq MemberSet
    /\ UserPerceptions \in [ [ perceiver : Users, description : [ by : Users, of : Users ] ] -> Users \union { Nothing } ]
    \* A user always correctly knows their own perceptions
    /\ \A user1, user2 \in Users : UserPerceptions[[ perceiver |-> user1, description |-> [ by |-> user1, of |-> user2 ]]] = user2
    /\ Connections \subseteq (Users \X Users)

\* TODO: This is incorrectly used in places where it could not possibly be
\* known, and instead must be based on perceptions.
Leader ==
    CHOOSE member \in InitialMembers : member.id = Nothing

\* TODO: This actually has a deeper layer, in that this models the direct
\* connections that are pre-group, which are only used for
\* Invite/Accept/Establish messages.  All other messages actually happen over
\* the established connections that are _specific_ to the group, which only
\* exist if _both_ parties believe each other to be in the group.  This is
\* important for things like SyncToken, which otherwise would never occur over
\* other channels, and could potentially cause issues if they did.
HasDirectConnection(x, y) ==
    \/ x = y
    \/ <<x, y>> \in Connections
    \/ <<y, x>> \in Connections

Init ==
    /\ messages = {}
    /\ rng_state = { invite_id \in InviteIds : (\A member \in InitialMembers : member.id /= invite_id) }
    (*
    Notably, group members learn about the changes to the group at different
    times, so we need to track their changes in perception individually.
    The empty set means the user doesn't believe themselves to be part of the
    group (they might actually know who some members are).
    On top of that, users may consider themselves in multiple groups in at the
    same time--even in this model where there is only one leader, because the
    whole point of this protocol is that invites can't be correlated.  As such,
    we need to consider what the user thinks for themselves given a their id
    within the group.
    *)
    /\ group_perceptions = [ member \in MemberSet |-> IF member \in InitialMembers THEN InitialMembers ELSE {} ]
    /\ proposal = Nothing
    /\ complete_proposals = {}
    /\ approver_states = [ x \in (InviteIds \X Users) |-> Nothing ]

SendPleasePropose ==
    \* IMPORTANT: The user should still wait to receive a Propose message from
    \* the leader before acting further, since they can't send an Invite
    \* message yet anyway.  The Leader might be queuing a number of proposals,
    \* and this one could be happening after another, meaning the group size,
    \* which is important for correct invitee behaviour, cannot be known until
    \* the Leader officially starts this proposal.
    \E proposer \in MemberSet, invitee \in Users :
        /\ Cardinality(rng_state) > 0
        /\ LET invite_id == CHOOSE x \in rng_state : TRUE
           IN
            /\ group_perceptions[proposer] /= {}
            /\ \A members \in group_perceptions[proposer] :
                /\ members.user /= invitee
            /\ HasDirectConnection(proposer.user, invitee)
            /\ messages' = messages \union
                {   [ type |-> PleasePropose
                    , sender |-> proposer
                    , recipient |-> Leader
                    , invite_id |-> invite_id
                    , invitee_description |-> [ by |-> proposer.user, of |-> invitee ]
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
            , awaiting_response |-> group_perceptions[Leader]
            ]
        /\ UNCHANGED <<messages, rng_state, group_perceptions, complete_proposals, approver_states>>

BroadcastProposalState(recipient) ==
    /\ proposal /= Nothing
    /\ \E member \in proposal.awaiting_response :
        /\ member = recipient
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
                    , kicked |-> proposal.kicked
                    ]
            }
        /\ UNCHANGED <<rng_state, group_perceptions, proposal, complete_proposals, approver_states>>

LeaderReceiveReject ==
    \E message \in messages :
        /\ message.type = Reject
        /\ message.recipient = Leader
        /\ message.sender \in group_perceptions[Leader]
        /\ message.invite_id \notin complete_proposals
        /\ proposal = Nothing
        /\ proposal.state = Proposing
        /\ message.invite_id = proposal.invite_id
        /\ complete_proposals' = complete_proposals \union { message.invite_id }
        /\ UNCHANGED <<messages, rng_state, group_perceptions, proposal, approver_states>>

LeaderReceiveEstablished ==
    /\ proposal /= Nothing
    /\ proposal.state = Proposing
    /\ \E message \in messages :
        /\ message.type = Established
        /\ message.recipient = Leader
        /\ message.sender \in group_perceptions[Leader]
        /\ message.invite_id = proposal.invite_id
        /\ IF  proposal.awaiting_response = { message.sender }
           THEN
               /\ proposal' = Nothing
               /\ complete_proposals' = complete_proposals \union { proposal.invite_id }
           ELSE
               /\ proposal' = [ proposal EXCEPT !.awaiting_response = { member \in @ : member /= message.sender } ]
               /\ UNCHANGED <<complete_proposals>>
        /\ UNCHANGED <<messages, rng_state, group_perceptions, approver_states>>

\* We don't specify exactly why, but at some point a Leader may realize that a
\* proposal is likely doomed, even if they never heard a rejection (proposals
\* with confused contacts can never resolve), and abort the proposal.
GiveUpOnProposal ==
    /\ proposal /= Nothing
    /\ proposal.state = Proposing
    \* If no one has established, then the leader may assume there's been
    \* confusion and will end the proposal, kicking the invitee if they did in
    \* fact join.  If some members have established, but _not_ the leader, the
    \* leader may assume the invitee is being weird and kick them.
    \* TODO: Should we always start with kicking the invitee and then only
    \* start kicking current members if they then are nonresponsive to the
    \* invitee kick?
    /\ \/ proposal.awaiting_response = group_perceptions[Leader]
       \/ Leader \in proposal.awaiting_response
    /\ complete_proposals' = complete_proposals \union { proposal.invite_id }
    /\ proposal' =
        [ state |-> Kicking
        , awaiting_response |-> group_perceptions[Leader]
        , kicked |-> { proposal.invite_id }
        ]
    /\ UNCHANGED <<messages, rng_state, group_perceptions, approver_states>>

\* We don't specify exactly why, but this would likely be a human decision
\* based on trying to start a _new_ proposal, but that not being possible
\* because of a pending one.  It would then show the users that are not
\* cooperating and would offer to kick them.  It's also possible that when
\* trying to kick someone, another member goes unresponsive, meaning we need to
\* start a new round of kicking.
GiveUpOnMembers ==
    /\ proposal /= Nothing
    /\ \/ /\ proposal.state = Proposing
          /\ complete_proposals' = complete_proposals \union { proposal.invite_id }
       \/ /\ proposal.state = Kicking
          /\ UNCHANGED <<complete_proposals>>
    \* Leader can't be kicked.  Realistically, they should just act
    \* synchronously when giving up on a proposal.
    /\ Leader \notin proposal.awaiting_response
    /\ LET new_group == group_perceptions[Leader] \ proposal.awaiting_response
       IN
        /\ proposal' =
            [ state |-> Kicking
            , awaiting_response |-> new_group
            , kicked |-> { member.id : member \in proposal.awaiting_response }
            ]
        /\ UNCHANGED <<messages, rng_state, group_perceptions, approver_states>>

LeaderReceiveKickAck ==
    /\ proposal /= Nothing
    /\ proposal.state = Kicking
    /\ \E message \in messages :
        /\ message.type = KickAck
        /\ message.recipient = Leader
        /\ message.sender \in group_perceptions[Leader]
        /\ message.kicked = proposal.kicked
        /\ IF   proposal.awaiting_response = { message.sender }
           THEN proposal' = Nothing
           ELSE proposal' = [ proposal EXCEPT !.awaiting_response = { member \in @ : member /= message.sender } ]
        /\ UNCHANGED <<messages, rng_state, group_perceptions, complete_proposals, approver_states>>

ApproverReceiveProposal(recipient) ==
    \E message \in messages :
        /\ message.recipient = recipient
        /\ message.type = Propose
        /\ LET PerceivedUser == UserPerceptions[[ perceiver |-> message.recipient.user, description |-> message.invitee_description]]
           IN
               IF
                   /\ PerceivedUser /= Nothing
                   /\ HasDirectConnection(message.recipient.user, PerceivedUser)
               THEN
                   /\ approver_states[<<message.invite_id, message.recipient.user>>] = Nothing
                   /\ approver_states' = [ approver_states EXCEPT ![<<message.invite_id, message.recipient.user>>] = <<message.recipient.id, Active>> ]
                   \* It's safe to send this message right away, as it only agrees to
                   \* reveal information that everyone has agreed to share.  The invitee
                   \* now knows that there's a group that involves this member, the
                   \* proposer, and any other members that have sent this message, giving
                   \* the invitee insight into how these contacts are all connected.
                   \* However, that is exactly what they all just agreed to.  Members that
                   \* don't agree to send this message remain private.
                   /\ messages' = messages \union
                       {   [ sender |-> message.recipient.user
                           , recipient |-> PerceivedUser
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
                           , token |-> [ for |-> message.invite_id, by |-> message.recipient.user ]
                           , group_size |-> message.group_size
                           ]
                       }
                   /\ UNCHANGED <<rng_state, group_perceptions, proposal, complete_proposals>>
               ELSE
                   /\ messages' = messages \union
                       {   [ sender |-> message.recipient
                           , recipient |-> Leader
                           , type |-> Reject
                           , invite_id |-> message.invite_id
                           ]
                       }
                   /\ UNCHANGED <<rng_state, group_perceptions, proposal, complete_proposals, approver_states>>

ApproverReceiveKick(recipient, kicked) ==
    \E message \in messages :
        /\ message.type = Kick
        /\ message.recipient = recipient
        /\ message.kicked = kicked
        /\ message.sender = Leader
        /\ group_perceptions' = [ group_perceptions EXCEPT ![message.recipient] = { member \in @ : member.id \notin message.kicked } ]
        /\ approver_states' =
            FoldSet(
              LAMBDA next, prev :
                  [ prev EXCEPT ![<<next, message.recipient.user>>] = <<message.recipient.id, Committed>> ],
              approver_states,
              message.kicked
            )
        /\ messages' = messages \union
            {   [ type |-> KickAck
                , sender |-> message.recipient
                , recipient |-> message.sender
                , kicked |-> message.kicked
                ]
            }
        /\ UNCHANGED <<rng_state, proposal, complete_proposals>>

BroadcastToken ==
    \E from \in MemberSet, invite_id \in InviteIds :
        \E to \in group_perceptions[from] :
            /\ from /= to
            /\ approver_states[<<invite_id, from.user>>] /= Nothing
            /\ messages' = messages \union
                {   [ sender |-> from
                    , recipient |-> to
                    , type |-> SyncToken
                    \* Note again that tokens are abstract/symbolic.  In this
                    \* context, the spec implies that this is using a
                    \* pregenerated token that is permanently associated for
                    \* this invite_id.
                    , token |-> [ for |-> invite_id, by |-> from.user ]
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
                    \* IMPORTANT: The Accept may still has a chance of being
                    \* ignored (or token mismatch or something odd), so the
                    \* invitee does not yet believe themself to be part of the
                    \* group.  At least one member must establish a connection
                    \* with them first.
                    /\ messages' = messages \union
                        {   [ sender |-> invitee
                            , recipient |-> message.sender
                            , type |-> Accept
                            , tokens |-> Tokens
                            , invite_id |-> invite_id
                            ]
                        }
                ELSE UNCHANGED <<messages>>
        /\ UNCHANGED <<rng_state, group_perceptions, proposal, complete_proposals, approver_states>>

Establish(recipient) ==
    \E message \in messages :
        /\ message.recipient = recipient
        /\ message.type = Accept
        /\ approver_states[<<message.invite_id, message.recipient>>] /= Nothing
        /\ approver_states[<<message.invite_id, message.recipient>>][2] = Active
        /\ LET RecipientId == approver_states[<<message.invite_id, message.recipient>>][1]
               RecipientMember == [ user |-> message.recipient, id |-> RecipientId ]
               SenderMember == [ user |-> message.sender, id |-> message.invite_id ]
               SyncMessages == { sync \in messages : sync.recipient = RecipientMember /\ sync.type = SyncToken /\ sync.invite_id = message.invite_id }
               Senders == { sync.sender : sync \in SyncMessages }
               \* Note that it's safe to "access" "its" token here
               Tokens == { sync.token : sync \in SyncMessages } \union { [ for |-> message.invite_id, by |-> message.recipient ] }
               InviteeDoesntBelieveInviterIsKicked ==
                   /\ RecipientId /= Nothing
                   /\ approver_states[<<RecipientId, message.sender>>] /= Nothing
                   /\ approver_states[<<RecipientId, message.sender>>][2] = Committed
           IN  /\ Senders = group_perceptions[RecipientMember] \ { RecipientMember }
               /\ message.tokens = Tokens
               /\ approver_states' = [ approver_states EXCEPT ![<<message.invite_id, message.recipient>>] = [ @ EXCEPT ![2] = Committed ] ]
               \* TODO: This can't be atomic
               /\ group_perceptions' =
                   [ group_perceptions
                   EXCEPT ![RecipientMember] = @ \union { SenderMember }
                   ,      ![SenderMember] = @ \union (IF InviteeDoesntBelieveInviterIsKicked THEN {} ELSE { RecipientMember, SenderMember })
                   ]
               /\ messages' = messages \union
                   {   [ type |-> Established
                       , sender |-> RecipientMember
                       , recipient |-> Leader
                       , invite_id |-> message.invite_id
                       ]
                   }
               /\ UNCHANGED <<rng_state, proposal, complete_proposals>>

\* TODO: Need to be able to Kick outside of failed proposals.

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
    \/ \E member \in MemberSet : BroadcastProposalState(member)
    \/ LeaderReceiveReject
    \/ LeaderReceiveEstablished
    \/ GiveUpOnProposal
    \/ GiveUpOnMembers
    \/ LeaderReceiveKickAck
    \/ \E member \in MemberSet : ApproverReceiveProposal(member)
    \/ \E member \in MemberSet, kicked \in SUBSET InviteIds : ApproverReceiveKick(member, kicked)
    \/ BroadcastToken
    \/ SendAccept
    \/ \E user \in Users : Establish(user)

AllVars ==
    <<messages, rng_state, group_perceptions, proposal, complete_proposals, approver_states>>

Fairness ==
    /\ SF_AllVars(LeaderReceivePleasePropose)
    /\ \A member \in MemberSet :
        WF_AllVars(BroadcastProposalState(member))
    /\ SF_AllVars(LeaderReceiveReject)
    /\ SF_AllVars(LeaderReceiveEstablished)
    /\ WF_AllVars(GiveUpOnProposal)
    /\ WF_AllVars(GiveUpOnMembers)
    /\ SF_AllVars(LeaderReceiveKickAck)
    /\ SF_AllVars(ApproverReceiveProposal(Leader))
    /\ \A kicked \in SUBSET InviteIds :
        SF_AllVars(ApproverReceiveKick(Leader, kicked))
    /\ SF_AllVars(Establish(Leader.user))


Spec == Init /\ [][Next]_AllVars /\ Fairness


IdsAreUnique ==
    \A member \in MemberSet :
        \/ group_perceptions[member] = {}
        \/ Cardinality({ m.id : m \in group_perceptions[member] }) = Cardinality(group_perceptions[member])

IdsAndLeaderMatchAcrossAllMembers ==
    \A invite_id \in (InviteIds \union { Nothing }), member1, member2 \in MemberSet :
        LET matches1 == { member \in group_perceptions[member1] : member.id = invite_id }
            matches2 == { member \in group_perceptions[member2] : member.id = invite_id }
        IN  \/ matches1 = {}
            \/ matches2 = {}
            \/ matches1 = matches2

CannotCommunicateWithoutAConnection ==
    \A message \in messages :
        IF   message.type \in { Invite, Accept }
        THEN HasDirectConnection(message.sender, message.recipient)
        ELSE HasDirectConnection(message.sender.user, message.recipient.user)

TokensMatch ==
    \A message \in messages :
        /\ message.type = Invite =>
            /\ message.token = [ for |-> message.invite_id, by |-> message.sender ]
            /\ approver_states[<<message.invite_id, message.sender>>] /= Nothing
        /\ message.type = SyncToken =>
            /\ message.token = [ for |-> message.invite_id, by |-> message.sender.user ]
            /\ approver_states[<<message.invite_id, message.sender.user>>] /= Nothing

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

AllMembersUsers ==
    UNION { { member.user : member \in group_perceptions[x] } : x \in MemberSet }

MembersOnlyEstablishWithInvitee ==
    \A member_user \in (AllMembersUsers \ { member.user : member \in InitialMembers }) :
        \E message \in messages :
            /\ message.type = Propose
            /\ message.invitee_description.of = member_user

AllMembersAreConnectedToAllOtherMembers ==
    \A member1 \in MemberSet :
        \A member2 \in group_perceptions[member1] :
            HasDirectConnection(member1.user, member2.user)

EstablishedOnlyIfAllPerceptionsMatch ==
    \A member_user \in AllMembersUsers :
        \A message \in messages :
            /\ message.type = Propose
            /\ message.invitee_description.of = member_user
            => UserPerceptions[[ perceiver |-> message.recipient.user, description |-> message.invitee_description ]] = member_user

AllMembersAccordingToTheLeaderAgreeWithTheLeaderWithoutProposal ==
    proposal = Nothing =>
        \A member \in group_perceptions[Leader] :
            group_perceptions[member] = group_perceptions[Leader]

AllProposalsResolve ==
    []<>(proposal = Nothing)

====
