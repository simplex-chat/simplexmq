---- MODULE groups_liveness_resolve_without_kick_mc ----

\* This particular model explores the very specific circumstance where we are
\* guaranteed to eventually complete a proposal successfully.  All users are
\* live, there is no confusion, and the leader never gives up.

EXTENDS groups

CONSTANTS a, b, c

InviteIdsMC == 0..1

\* No one is ever confused
UserPerceptionsMC ==
  [ x \in [ perceiver : Users, description : [ by : Users, of : Users ] ] |-> x.description.of ]

\* Everyone knows everyone
ConnectionsMC ==
  Users \X Users

InitialMembersMC ==
  { [ id |-> Nothing, user |-> a ]
  , [ id |-> 0, user |-> b ]
  }

PatientNext ==
    \/ DropMessage
    \/ SendPleasePropose
    \/ LeaderReceivePleasePropose
    \/ \E member \in MemberSet : BroadcastProposalState(member)
    \/ LeaderReceiveReject
    \/ LeaderReceiveEstablished
    \/ LeaderReceiveKickAck
    \/ \E member \in MemberSet : ApproverReceiveProposal(member)
    \/ \E member \in MemberSet, kicked \in SUBSET InviteIds : ApproverReceiveKick(member, kicked)
    \/ \E user \in Users : ApproverReceiveAccept(user)
    \/ \E member \in MemberSet : ReceiveSyncToken(member)
    \/ \E member \in MemberSet : ApproverEstablish(member)
    \/ \E user \in Users : UserReceiveInvite(user)
    \/ \E user \in Users : UserReceiveWelcome(user)

\* There are so many fairness conditions to track that the only way we can get
\* them to be checkable is to be very specific to the ones we need for this
\* model.  This definition does not generalize to in a few ways.  A clear way
\* is that we only consider initial members, meaning this only works for one
\* additional user.  Also, most actions need to be fair by sender, recipient,
\* and invitation identifier.  This just adds a fair amount of noise to our
\* spec for something that's too large to check anyway (even just adding a
\* fourth user instead of three is adds some multiple days).
AllUsersFair ==
    /\ WF_AllVars(DropMessage)
    /\ SF_AllVars(LeaderReceivePleasePropose)
    /\ \A member \in MemberSet :
        WF_AllVars(BroadcastProposalState(member))
    /\ SF_AllVars(LeaderReceiveReject)
    /\ SF_AllVars(LeaderReceiveEstablished)
    /\ \A member \in InitialMembers :
        /\ SF_AllVars(ApproverReceiveProposal(member))
        /\ SF_AllVars(ReceiveSyncToken(member))
        /\ SF_AllVars(ApproverEstablish(member))
    /\ \A user \in { member.user : member \in InitialMembers } :
        /\ SF_AllVars(ApproverReceiveAccept(user))
        /\ SF_AllVars(UserReceiveInvite(user))
        /\ SF_AllVars(UserReceiveWelcome(user))

FairAndPatientSpec == Init /\ [][PatientNext]_AllVars /\ AllUsersFair

====
