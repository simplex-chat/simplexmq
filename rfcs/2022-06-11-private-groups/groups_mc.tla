---- MODULE groups_mc ----

\* Our most basic model considers a group of two people who both know of two
\* others (that also know each other), and enough random numbers ar available
\* to invite either one of them.

EXTENDS groups

CONSTANTS a, b, c, d

MaxNum == 1

NatMC == 0..MaxNum

\* No one is ever confused
UserPerceptionsMC ==
  [ x \in [ perceiver : Users, description : [ by : Users, of : Users ] ] |-> x.description.of ]

\* Everyone knows everyone
ConnectionsMC ==
  Users \X Users

SizeConstraint == rng_state < MaxNum + 1

====
