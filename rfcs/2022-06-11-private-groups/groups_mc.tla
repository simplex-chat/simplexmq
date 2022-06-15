---- MODULE groups_mc ----

EXTENDS groups

CONSTANTS a, b, c, d

MaxNum == 6

NatMC == 0..MaxNum

\* No one is ever confused
UserPerceptionsMC ==
  [ x \in [ perceiver : Users, description : [ by : Users, of : Users ] ] |-> x.description.of ]

\* Everyone knows everyone
ConnectionsMC ==
  Users \X Users

SizeConstraint == rng_state < MaxNum + 1

====
