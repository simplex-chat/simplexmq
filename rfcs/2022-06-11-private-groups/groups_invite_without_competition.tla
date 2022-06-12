---- MODULE groups_invite_without_competition ----

EXTENDS Naturals, FiniteSets

CONSTANTS
    Members,
    Others,
    Nothing,
    \* Request Type
    Propose,
    Invite,
    Accept,
    SyncToken

VARIABLES
    messages,
    rng_state,
    tokens,
    perceived_proposee,
    established

\* TODO: This ignores the complexities of competing proposers, or competition
\* over other membership actions (leave or kick).  These can create uncertainty
\* about who is in the group currently, which makes it complicated to ensure
\* that all (and only) current group members are consulted.
\*
\* High level idea to solve this: proposers must commit to one action at a
\* time, each group member is ranked (order of admittence), and higher ranked
\* proposers can override the current action up until its final stages (drawing
\* a similarity to Paxos).  The highest ranking group member is (likely, TBD)
\* live in all their decisions, and the 2nd ranked is live if the higher member
\* eventually concedes.  That latter is inductive to the lowest rank.  If the
\* highest ranked member permanently disappears, then then group can never
\* change again.  Luckily, a brand new group can be formed in this worst case.
Proposer ==
    CHOOSE member \in Members : TRUE

Proposee ==
    CHOOSE other \in Others : TRUE


Init ==
    /\ messages = {}
    /\ \E f \in [ Members \ { Proposer } -> Others \union { Nothing } ] : perceived_proposee = f
    /\ rng_state = 1
    /\ tokens = [ [ member \in Members |-> Nothing ] EXCEPT ![Proposer] = 0 ]
    /\ established = [ member \in Members |-> Nothing ]

SendProposal ==
    \E member \in (Members \ { Proposer }) :
        /\ messages' = messages \union { [ sender |-> Proposer, recipient |-> member, type |-> Propose ] }
        /\ UNCHANGED <<perceived_proposee, rng_state, tokens, established>>

\* It's safe to send this message right away, because it reveals nothing at the
\* moment, just that the proposer wants you to join a group that is the size of
\* N people.
\* NOTE: Not shown for all Invites is an inviteId (as it would be common across
\* this whole module).  The invite id both correllates the invitations from
\* each member and distinguishes it from unrelated invites.
ProposerInvite ==
    /\ messages' = messages \union { [ sender |-> Proposer, recipient |-> Proposee, type |-> Invite, token |-> 0 ] }
    /\ UNCHANGED <<perceived_proposee, rng_state, tokens, established>>

ReceiveProposal ==
    \E message \in messages :
        /\ message.type = Propose
        /\ tokens[message.recipient] = Nothing
        /\ perceived_proposee[message.recipient] /= Nothing
        /\ tokens' = [ tokens EXCEPT ![message.recipient] = rng_state ]
        /\ rng_state' = rng_state + 1
        \* It's safe to send this message right away, as it only agrees to
        \* reveal information that everyone has agreed to share.  The proposee
        \* now knows that there's a group that involves this member, the
        \* proposer, and any other members that have sent this message, giving
        \* the proposee insight into how these contacts are all connected.
        \* However, that is exactly what they all just agreed to.  Members that
        \* don't agree to send this message remain private.
        /\ messages' = messages \union { [ sender |-> message.recipient, recipient |-> perceived_proposee[message.recipient], type |-> Invite, token |-> rng_state ] }
        /\ UNCHANGED <<perceived_proposee, established>>

BroadcastToken ==
    \E from \in (Members \ { Proposer }) :
        \E to \in (Members \ { from }) :
            /\ tokens[from] /= Nothing
            /\ messages' = messages \union { [ sender |-> from, recipient |-> to, type |-> SyncToken, token |-> tokens[from] ] }
            /\ UNCHANGED <<perceived_proposee, rng_state, tokens, established>>

SendAccept ==
    \E other \in Others :
        LET Invites == { message \in messages : message.type = Invite /\ message.recipient = other }
            Inviters == { message.sender : message \in Invites }
            Tokens == { message.token : message \in Invites }
        IN  IF   Inviters = Members
            THEN
                \E member \in Members :
                    \* This should be invariant, that there is a direct
                    \* connection already established but we make no
                    \* assumptions and ensure that there is a direct
                    \* connection.
                    /\ member /= Proposer => perceived_proposee[member] = other
                    /\ messages' = messages \union { [ sender |-> other, recipient |-> member, type |-> Accept, tokens |-> Tokens ] }
                    /\ UNCHANGED <<perceived_proposee, rng_state, tokens, established>>
            ELSE UNCHANGED <<perceived_proposee, messages, rng_state, tokens, established>>

Establish ==
    \E member \in Members :
        /\ tokens[member] /= Nothing
        /\ LET SyncMessages == { message \in messages : message.recipient = member /\ message.type = SyncToken }
               Senders == { message.sender : message \in SyncMessages }
               \* We know that the Proposers token is known if this member
               \* generated one.
               Tokens == { message.token : message \in SyncMessages } \union { 0, tokens[member] }
           IN  /\ Senders = (Members \ { Proposer, member })
               /\ \E message \in messages :
                   /\ message.type = Accept
                   /\ message.recipient = member
                   /\ message.tokens = Tokens
                   /\ established' = [ established EXCEPT ![member] = message.sender ]
                   /\ UNCHANGED <<perceived_proposee, messages, rng_state, tokens>>

Next ==
    \/ SendProposal
    \/ ProposerInvite
    \/ ReceiveProposal
    \/ BroadcastToken
    \/ SendAccept
    \/ Establish

Spec == Init /\ [][Next]_<<messages, rng_state, tokens, established>>

\* An other that receives two invites (which would share an invite id, even
\* though it's not explicitly modeled here), knows that these two contacts know
\* each other and that they are in a group together with N people.
KnowsTwoMembersKnowEachOther(other, member1, member2) ==
    /\ member1 /= member2
    /\ \E message1, message2 \in messages :
        /\ message1.type = Invite
        /\ message2.type = Invite
        /\ message1.recipient = other
        /\ message2.recipient = other
        /\ message1.sender = member1
        /\ message2.sender = member2

OthersOnlyKnowMembersKnowEachOtherIfMembersAcceptedProposal ==
    \A other \in Others, member1, member2 \in Members :
        KnowsTwoMembersKnowEachOther(other, member1, member2) =>
            /\  \/ member1 = Proposer
                \/ tokens[member1] /= Nothing
            /\  \/ member2 = Proposer
                \/ tokens[member2] /= Nothing

MembersOnlyEstablishWithProposee ==
    \A member \in Members :
        \/ established[member] = Nothing
        \/ established[member] = Proposee

EstablishedOnlyIfAllPerceptionsMatch ==
    (\E member \in Members : established[member] /= Nothing) =>
        \A member \in (Members \ { Proposer }) :
            perceived_proposee[member] = Proposee

\* With this as an (incorrect) invariant, we can see a path to establishing a
\* connection
NoOneCanEstablish ==
    \A member \in Members : established[member] = Nothing

\* With this as an (incorrect) invariant, we can see a path to all members
\* establishing a connection
Incompletable ==
    ~(\A member \in Members :
        established[member] = Proposee
     )

====
