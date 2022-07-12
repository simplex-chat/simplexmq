# TLA+ Crash Course

This guide is both opinionated and imprecise, but aims to be a warp speed introduction to TLA+ in the context of the specifications here.

TLA+ is a specification language ideal for modeling distributed systems.
The goal is to specify possible (a) starting states(s), and define next state transitions.
We do this mathematically, where everything is made of boolean expressions.

Given that things are mathematical, everything is immutable.
Variables don't "change," so much as variables have a current state `x`, and they have a _next_ state `x'`.
When writing specs, both `x` and `x'` are immutable values, but the prime lets us define the step from here to there.
Specifying a next value for a variable is still a boolean expression (e.i. `x' = 1`), just one that we always expect to be true.

Non-determinism is expressed simply by OR expressions.
For example `x' = 1 \/ x' = 2` will explore these two different possibilities distinctly.

From here we can define invariants and properties that can then be model checked.
The model checker examines every possibility (over the constrained model) and validates them.

There are two types of properties: safety and liveness.
Safety properties are things that _must not_ happen.
Liveness properties are things that _must eventually_ happen.
The latter is harder to specify, but occasionally quite important.

## Syntax

### Simple (Haskell) Translations

Despite its foreign look at first (or have a math background), there are many easy translations to Haskell:

  - `/\` is `&&` (think '/\nd').
  - `\/` is `||`
  - `~` is `not`
  - `==` and `=` are backwards
  - `/=` is still `/=`
  - `\A x \in xs : f(x)` is `all $ fmap f xs`
  - `\E x \in xs : f(x)` is `any $ fmap f xs`
  - `<<x, y, ..., z>>` is `(x, y, ..., z)` or `[x, y, ..., z]`
  - `{ x, y, ..., z}` is `Set.fromList [ x, y, ..., z ]`
  - `{ x \in xs : f(x) }` is `filter f xs`
  - `{ f(x) : x \in xs }` is `Set.map f xs`
  - `[ x |-> a, y |-> b, ..., z |-> c ]` is `MyRecord { x = a, y = b, ..., z = c }`
  - `[ r EXCEPT !.x = a, !.y = b, ..., !.z = c ]` is `r { x = a, y = b, ..., z = c }`
  - `[ r EXCEPT ![x] = a ]` is `Map.adjust (const a) x r`
  - `CHOOSE x \in xs : f(x)` is `head $ filter f xs`
  - `CHOOSE x \in xs : f(x)` is `head $ filter f xs`
  - `LAMBDA a, b : ...` is `\a b -> ...`
  - `x \notin xs` is `Set.notMember x xs`
  - `xs \subset ys` is `Set.isSubsetOf xs ys`
  - `CASE` acts more like guards

### Little Equivalence

#### Bulleted Lists

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

### Type Sets

```tla
MemberSet == [ user : Users, id : InviteIds \union { Nothing } ]
```

### Initialized Functions

Functions act more or less like `Map k`, where `k` is some set..
We can initialize one with all values defined by whatever we'd like:

```tla
[ x \in k |-> f(x) ]
```

### Liveness Operators

These are both more advanced and less important, but `[]` means "always," and `<>` means "eventually."
This means that `~[]` is "never."

So Rick Astley is `~[]GonnaGiveYouUp`.

A normal song `<>Ends`, but the Song That Never Ends `[]<>Sings("this is the song that never ends.")`.

## Anatomy of a Spec

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

### Variables

Variables are all the values that will change over the course of time.

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
