---- MODULE groups_varied_connections_mc ----

EXTENDS groups

CONSTANTS a, b, c, d

MaxNum == 2

NatMC == 0..MaxNum

\* No one is ever confused
UserPerceptionsMC ==
  [ x \in [ perceiver : Users, description : [ by : Users, of : Users ] ] |-> x.description.of ]

\* A is not connected to D and B is not connected to C
ConnectionsMC ==
  { <<a, b>>, <<a, c>>, <<b, d>>, <<c, d>> }

SizeConstraint == rng_state < MaxNum + 1

SpecialGroupCases ==
   /\ d \notin group_perceptions[Leader]
   /\ (c \in group_perceptions[Leader]) => (b \notin group_perceptions[Leader])

====
