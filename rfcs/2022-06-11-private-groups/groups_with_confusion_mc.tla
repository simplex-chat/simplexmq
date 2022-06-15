---- MODULE groups_with_confusion_mc ----

EXTENDS groups

CONSTANTS a, b, c, d

MaxNum == 6

NatMC == 0..MaxNum

UserPerceptionsMC ==
  [ [ x \in [ perceiver : Users, description : [ by : Users, of : Users ] ] |-> x.description.of ]
  EXCEPT ![[ perceiver |-> b, description |-> [ by |-> a, of |-> c] ]] = d
  ]

\* Everyone knows everyone
ConnectionsMC ==
  [ x \in Users |-> { a, b, c, d } ]

SizeConstraint == rng_state < MaxNum + 1

====
