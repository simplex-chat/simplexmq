# TLA+ Crash Course

This guide is both opinionated and imprecise, but aims to be a warp speed introduction to TLA+ in the context of the specifications here.

TLA+ is a specification language ideal for modeling distributed systems.
The goal is to specify possible (a) starting states(s), and define next state transitions.
We do this mathematically, where everything is made of boolean expressions.

Along side of our system specification, we can also define properties (such as invariants) it should satisfy.
The TLC model checker can then explore every possible state of the specification and validate that all properties hold across all possible behaviors.

The model checker works via BFS.
When a AND condition is encountered, it acts as a guard.
When an OR condition is encountered, it acts as non-determinism, searching all possibilities.

## Basic Syntax

### Simple (Haskell) Translations of Basic Syntax

Since TLA+ is based on ZFC Set theory, the most critical syntax is based around booleans and sets.

Booleans:
  - `/\` is `&&` (think '/\nd').
  - `\/` is `||`
  - `~` is `not`
  - `==` and `=` are backwards
  - `/=` is still `/=`
  - `\A x \in xs : f(x)` is `all $ fmap f xs`
  - `\E x \in xs : f(x)` is `any $ fmap f xs`

Sets:
  - `{ x, y, ..., z}` is `Set.fromList [ x, y, ..., z ]`
  - `a \union b` is `Set.union a b`
  - `a \ b` is ``Set.difference a b`
  - `x \notin xs` is `Set.notMember x xs`
  - `xs \subset ys` is `Set.isSubsetOf xs ys`
  - `{ x \in xs : f(x) }` is `Set.filter f xs`
  - `{ f(x) : x \in xs }` is `Set.map f xs`

### Bulleted Lists

Bulleted lists are common in TLA+ because strings of `/\` and `\/` are so frequent.
Any vertically aligned `/\` and `\/` that all match are all strung together.

So this:

```tla
  /\ a
  /\ b
  /\ \/ c
     \/ d
```

Is the same as:

```tla
a /\ b /\ (c \/ d)
```

Bulleted lists are dramatically more readable for things that TLA+ is good at.

## Basic Anatomy of a Spec

### Variables

Variables are all the values that will change over the course of time.
Variables don't "change," so much as variables have a current state `x`, and they have a _next_ state `x'`.
When writing specs, both `x` and `x'` are immutable values, but the prime lets us define the step from here to there.
Specifying a next value for a variable is still a boolean expression (e.i. `x' = 1`), just one that we always expect to be true.

### Initial State

We define a simple boolean expression that describes the initial possible value(s) of our Variables.

### Next State

Our next state transition is often broken down into distinct sets of actions via operators for readability.
An Action is typically has two halves: the guards and the transitions.
More complex actions may intermix these two.

```tla
GoTo1 ==
    /\ x = 2
    /\ x' = 1

GoTo2 ==
    /\ x = 1
    /\ x' = 2

Next ==
    \/ GoTo1
    \/ GoTo2
```

Our next state relation must _completely_ define the next state of all variables.
This means if some actions do not cause variable `x` to change we must specify that `x' = x`.
Alternatively, we can use `UNCHANGED x` or provide it a tuple of variables to say none of them do, like `UNCHANGED <<x, y, z>>`.

## Examples

We can take a look a slightly simplified verion of the action to kick a Leaver.
We'll build a whole spec where `a`, `b`, and `c` are the states of the users.
We're going to use string values to simplify things, but normally we would use Constants, introduced below.

```tla
VARIABLES
    a,
    b,
    c,
    proposal

Init ==
    /\ a = "Leader"
    /\ b = "Joined"
    /\ c = "Joined"
    /\ proposal = "Null"

MemberLeave ==
    \/ /\ b = "Joined"
       /\ b' = "Left"
       /\ UNCHANGED <<a, c, proposal>>
    \/ /\ c' = "Joined"
       /\ c = "Left"
       /\ UNCHANGED <<a, b, proposal>>

LeaderDetectLeaver ==
    /\ proposal = "Null"
    /\ \E member \in { b, c } :
        /\ member = "Left"
        /\ proposal' = "Kick"
        /\ UNCHANGED <<a, b, c>>

Next ==
    \/ Leave
    \/ LeaderDetectLeaver
```

In the initial state, `a` is assigned the value "Leader", meaning it is managing the group.
`b` and `c` are assigned the "Joined" state, meaning they are members of the group.
`proposal` is set to "Null", meaning that the Leader is not proposing any group changes.

We define two actions, `MemberLeave` and `LeaderDetectLeaver`.
Both of these appear as options in the `Next` operator, which defines all possible things that could occur.

The `MemberLeave` action has two possibilities.
One is that `a` leaves (assuming `a` is still "Joined"), by switching its state to "Left".
The other is the same, but `b` instead of `a`.

The `LeaderDetectLeaver` action can start a "Kick" proposal if the proposal is currently "Null".
It does this by exploring a different option for each item in the set `{ a, b }`.
Each item of that set that evalutes to `TRUE` in the following expression will be explored.
If the member chosen from the set has "Left", then the proposal will switch to "Kick".

This spec only has a few behaviors:
  - `b` leaves, the proposal moves to "Kick", `c` leaves
  - `c` leaves, the proposal moves to "Kick", `b` leaves
  - `b` leaves, `c` leaves, the proposal moves to "Kick"
  - `c` leaves, `b` leaves, the proposal moves to "Kick"
  - Any of the above, but stopping anywhere in the middle (called stuttering)

Our full spec of course has many other things to worry about.
It needs to capture who to kick, send and receive the appropriate messages to act on the proposal, handle arbitrary members, and handle them joining in the first place.
However, this simplified part of the spec illustrates start to finish how we can define multiple stateful entities changing to new states based on their current states.

## More Advanced Syntax

### Type Sets

```tla
MemberSet == [ user : Users, id : InviteIds \union { Null } ]
```

### Initialized Functions

Functions act more or less like `Map k`, where `k` is some set..
We can initialize one with all values defined by whatever we'd like:

```tla
[ x \in k |-> f(x) ]
```

### Other (Haskell) Translations

Tuples and Sequences:
  - `<<x, y, ..., z>>` is `(x, y, ..., z)` or `[x, y, ..., z]`

Records:
  - `[ x |-> a, y |-> b, ..., z |-> c ]` is `MyRecord { x = a, y = b, ..., z = c }`
  - `[ r EXCEPT !.x = a, !.y = b, ..., !.z = c ]` is `r { x = a, y = b, ..., z = c }`

Functions (Maps):
  - `[ r EXCEPT ![x] = a ]` is `Map.adjust (const a) x r`
  - `[ \x in xs |-> f(x) ]` is `Map.fromList $ map (\x -> (x, f(x))) $ Set.toList xs`

Selecting from a set:
  - `CHOOSE x \in xs : f(x)` is `head $ filter f xs`
  - `CHOOSE x \in xs : f(x)` is `head $ filter f xs`

Misc:
  - `LAMBDA a, b : ...` is `\a b -> ...`
  - `CASE` acts more like guards

### Liveness Operators

These are both more advanced and less important, but `[]` means "always," and `<>` means "eventually."
This means that `[]~` is "never."

So Rick Astley is `[]~GonnaGiveYouUp`.

A normal song `<>Ends`, but the Song That Never Ends `[]<>Sings("this is the song that never ends.")`.

## Other Components of a Spec

### Constants

Constants allow us to define any values that are fixed over the state transitions.
These can be used for a variety of things such as abstract descriptions of the world or enum values.

When specifying, Constants help us stay abstract.
For example we can just say Users is the set of all possible users, without actually saying anything else about it.
When model checking, we must define all Constants concretely.
We define finite and "small" values in place of infinite or large ones to ensure that checking is tractable.
Cleverness here allows us to make strong guarantees about our specification without too much state explosion.

### Assumptions

Assumptions help us clarify invariants around constants.
These help clarify things to a reader and ensure we setup our Constants correctly when model checking.

### Fairness

An advanced topic that describes what options must _NOT_ be ignored given that they are infinitely available.
You might try to stay awake for some time, but you can't avoid it forever: that's fairness.
We only need this for liveness properties, not for safety.

### Invariants

Our invariants define our safety properties.
We mathematically specify what states are impossible.
The model checker then validates that these states never manifest.

### Liveness Properties

Liveness properties define state that we must eventually see, possibly given pre-conditions.
These are harder to specify, but are occasionally critical to a specification.
The model checker then validates that these states are always reached via all possible paths.

## Revisiting Our Example

Now that we have more context on syntax and other constructs in a spec, lets take a look at a more full definition of `LeaderDetectLeaver`.

```tla
CONSTANTS
    Null,
    Members,
    Leader,
    ...
    Kicking

VARIABLES
    proposal,
    ...
    group_perceptions

Init ==
    /\ proposal = Null
    ...
    /\ group_perceptions =
        [ member \in Members |->
            IF  member = Leader
            THEN
                \* The Leader is the only inital member
                { Leader }
            ELSE
                \* Empty set means, "not in it"
                {}
        ]

LeaderDetectLeaver ==
    \* If there is an existing proposal, expelling leavers is done via GiveUp
    \* actions.
    /\ proposal = Null
    /\ \E member \in group_perceptions[Leader] :
        /\ Leader \notin group_perceptions[member]
        /\ LET new_group == group_perceptions[Leader] \ { member }
           IN
            /\ proposal' =
                [ type |-> Kicking
                , awaiting_response |-> new_group
                , kicked |-> { member.id }
                ]
            /\ UNCHANGED <<group_perceptions, ...>

Next ==
  ...
  \/ LeaderDetectLeaver
```

The `proposal` still starts as `Null` (but `Null` is now a constant, which will be set as a model value/enum when checking via TLC).
We consider a group of arbitrary size by using a constant to describe the set of all possible `Members`, and a variable, `group_perceptions`, that is a function (Map) to describe each member's belief about membership.

A Leader then checks if they have a current proposal.
If they do not, then they consider each `member` that they currently believe to be in the group.
This member is a record, that has both an `id` and a `user` property.

If the member doesn't believe the `Leader` is in the group, this means that they have deleted the queue by which the `Leader` can send the messages.
The `Leader` would likely discover this when trying to send a message to the member.
The `Leader` defines the new group, which is all the current members, but without the member that left.
The `Leader` then sets the `proposal` to a record that hold the proposal type, who needs to ack the proposal, and who is being removed.
The `kicked` field is still a set because we _can_ kick multiple members at once, even if we don't here.

This action uses the current state of `group_perceptions`, but does not change it, so we finally must specify as such.

## Common Abstractions in this Spec

### Messaging

Messaging in this specification is very simple: it is a set of messages that have ever been sent.
Senders just add a new message into the set.
Receivers simply match against messages in the set and respond to any message that matches.

Messages are not removed when received, they are instead removed randomly.
This is because we don't care about the most likely scenario: we care about all possible scenarios equally.
Removing them randomly captures all possible scenarios: the message is never delivered (immediately removed), the message is received then dropped (happy path), the message is received many times (retries and etc).

This model is pessimistic in that messages can be sent and received in any order.
It is both better to be pessimistic and in my experience protocols that guarantee order don't usually provide ordering at the application level.

Because model checking ever possible combo of every possible message ever sent is quite large, we cap the requests.
We must be careful that we don't set the cap too low, or we will miss interesting combinations of delayed and retried requests that can cause issues.

When _only_ checking safety properties, we don't even remove messages from the set, because we only care about what's _possible_.
Dropping messages only impacts liveness properties (e.i. if an important message is lost forever without retries).

### Abstract Sets

In this spec, we define abstract sets like `InviteIds`.
This is just the set of all possible invitations identifiers, but we don't really care what they are.
We don't make the distinction between all possible guids, 64-bit ints, or otherwise.
They just are: we don't care about the details.

This also lets us come up with a definition that is small and convenient when model checking.
In the case of `InviteId`, we just say it is `{ 0, 1 }` or something similar.
We can then prove our invariants are correct, under that assumption.

## Misc

### Why is TLA+ not typed?

Type systems are advantageous in that they disqualify invalid programs.
The downside of types is that they _disqualify_ valid programs.
Something like Haskell offers a very advanced type system frequently allows us to disqualify many invalid programs without too much headache in convincing the compiler not to disqualify something that is in fact valid.

With TLA+, we can eschew it all together, because we can check _any invariant we want_ at _every possible state_, including that a value belongs to a particular set (synonymous to type here).
This lets us not have to do any extra work around types, but allows us to check them frequently.
Normally, it is not possible to validate every possible state of a program; types are an alternative that do quite nicely.
But in TLA+ they are redundant.
