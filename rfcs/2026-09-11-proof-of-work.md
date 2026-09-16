# Proof of work for resource creation

## Summary

A client presents a proof of work when it asks a server to create a resource: an SMP queue, an XFTP file chunk, a notification token. The required effort is the price of the resource. The price rises with the cost of the resource and with server load, and is divided by a configured factor for a client that presented an entitlement proof in the handshake.

The proof is bound to the transport session, so it is valid on one connection to one server, and single use within it.

## Interaction

The exchange adds no round trip. The server handshake states the price and the server time, the session id is the challenge input that both sides already hold, and the client attaches a proof to the command that creates the resource.

Nothing is sent back for the price alone: it rides the messages that already exist.

## Freshness

A proof states the minute it was made for, and expires after a few minutes.

Without an expiry a client mints proofs for as long as a session lasts and spends the stock in one burst. The stock is minted at the idle price, so the rising price reaches the burst after it lands, and an hour of one machine arrives in seconds. The expiry bounds the stock to the work of one window, a few periods of the price estimator.

```
powEpoch = 4*4 OCTET    ; Word32, minutes of server time
```

The server sends its current epoch in the handshake, and the client counts minutes from it with a monotonic clock, so the clock of the device takes no part. A proof verifies while `serverEpoch - powEpoch` is within the advertised window, and one epoch ahead of the server is admitted for rounding.

The window is the burst a client may prepare: a stock of `window * mint rate`. At 5 minutes and unit effort 16, one phone core holds about 900 queue proofs, and one desktop core about 2800.

A price increase cuts the stock a second way. A proof states the effort it was made for, so every proof below the new price is rejected, and the stock of an attacker survives an increase only at the effort it paid for in advance. The two bounds compose: the stock is worth the smaller of one window of minting and the time until the next increase.

## What Tor does

Tor proposal 327 and the [hspow specification](https://spec.torproject.org/hspow-spec/) define a client puzzle for onion service introduction.

- Function: Equi-X (Equihash(60,3) over HashX) with a Blake2b target check. Solution 16 bytes, solver memory 1.8 MiB, verification 50-120 microseconds.
- Effort: a 32-bit number `E`. The solution passes when `R * E <= UINT32_MAX`, where `R` is the first 32 bits of `blake2b_32(challenge || S)`. `E` is the expected number of candidate solutions tested, so cost is linear in `E`.
- Challenge: `P || ID || C || N || htonl(E)` - personalisation, service identity, a 32-byte seed from the service descriptor, a 16-byte nonce, effort.
- Freshness: the service publishes a seed in its descriptor and rotates it every 105-120 minutes, keeps the previous seed, and holds a replay cache of used `(seed, nonce)` pairs.
- Selection: verified requests enter a priority queue ordered by effort. Overfull queues discard the lower-effort half.
- Adaptation: every 300 seconds the service updates `suggested-effort` by additive increase and multiplicative decrease. Increase to `max(previous + 1, TOTAL_EFFORT / REND_HANDLED)` when the queue was congested or when a trimmed request exceeded the current effort; multiply by `2/3` when the queue stays short. The value is published in the descriptor.
- Client retry: on timeout, refetch the descriptor, then double the effort below 1000, multiply by 1.5 above it, within [8, 10000].

Tor solves a reachability problem: many clients compete for one bottleneck, so they bid and the service serves the highest bids.

## What we change

Our problem is the price of a stored resource, so the auction is replaced by a price list.

1. Threshold, not bidding. The server states the required effort; the client sends exactly that. The priority queue and its trimming are dropped. A faster device gains no priority, so the effort value describes the request rather than the device.
2. Session binding, not seeds. The challenge includes the hash of the transport session id, which both sides already hold. This removes seed generation, seed rotation, seed publication, and the two-seed overlap.
3. Single use by a counter, not by a replay cache. Each proof carries a session counter, and the server keeps the highest counter it accepted plus a 64-bit window of the counters below it. Per-session state is 16 bytes, against 16 bytes per accepted proof for a set of nonces. Tor needs the set because one seed spans many connections; a proof here is valid on one connection only.
4. An expiry of minutes, against the seed window of two hours in Tor. A stock of proofs is worth one window of minting, so the price estimator answers a burst that was prepared under the old price.
5. Price by resource, not by congestion alone. Effort is the resource cost in units multiplied by the current unit effort. Load moves the unit effort only.
6. Entitlement as a discount, never an exemption. A verified entitlement divides the unit effort by a factor configured per entitlement name. A credential presents on any number of sessions without linking them, so an exemption would sell an attacker unlimited creation for the price of one badge.

Kept from Tor: the Equi-X function, the linear effort scale, the verification formula, and the shape of the adaptation loop.

## Cost units

Each protocol defines the unit of its own price list. The server advertises the effort per unit; the client computes the effort of its request.

```
SMP:  1 unit per new queue
      1 unit per queue link data record (in NEW or LSET)
XFTP: 1 unit per megabyte-day of requested storage, rounded up
      chunkUnits = ceil(size / 1048576 * storageHours / 24)
NTF:  1 unit per token registration
```

`effort = unitEffort * units`, capped at 2^32 - 1.

## Handshake parameters

Each protocol adds one optional field to the server handshake, encoded from the version that introduces proof of work.

```
powParams = %s"0" / (%s"1" powScheme unitEffort entUnitEffort serverEpoch epochWindow)
powScheme = 1*1 OCTET      ; 1 = Equi-X and Blake2b
unitEffort = 4*4 OCTET     ; Word32, effort per unit, 0 = proof not required
entUnitEffort = 4*4 OCTET  ; Word32, effort per unit for a session with a verified entitlement
serverEpoch = 4*4 OCTET    ; Word32, current minute of server time
epochWindow = 1*1 OCTET    ; minutes a proof stays valid
```

The server handshake precedes the client handshake that carries the entitlement proof, so both values are sent. The client applies `entUnitEffort` when it presented an entitlement, and `unitEffort` otherwise.

```
entUnitEffort = ceil(unitEffort / entDiscount)
```

`entDiscount` is configured per entitlement name. The handshake states the value for the smallest configured discount, so a first command may over-pay, and the response to a priced command states the value for the entitlement of the session. `entUnitEffort` is zero only when `unitEffort` is zero.

## Algorithm

Equi-X, by tevador, is Equihash(60,3) with two changes: the hash is HashX, and the indices are summed modulo 2^60 rather than xored.

HashX takes a seed - here the challenge - and generates a short program of integer instructions over eight 64-bit registers, which maps a 64-bit input to a 64-bit output in about 100 nanoseconds on a superscalar pipeline. The program differs for every seed, so hardware built for one program serves no other. That is where the resistance to an ASIC comes from, and what narrows the distance to a GPU.

Solving finds eight 16-bit indices `i0..i7` with `HX(i0) + ... + HX(i7) = 0 (mod 2^60)`, under the tree conditions of Wagner's algorithm - 15 trailing zero bits on each pair, 30 on each quadruple, 60 on the sum - and an ordering condition that makes the solution canonical. The solver holds tables over 2^16 items, which is the 1.8 MiB. A solution is `8 * uint16`, so 16 bytes, and one call returns about two of them.

Verification recomputes the eight HashX values and checks the three sums. It takes 50-120 microseconds and a few kilobytes.

The protocol layer above it is the target check: a solution counts when `blake2b_32(challenge || solution) * effort <= 2^32 - 1`. Finding a solution is the constant cost; landing one in a slice of `1/effort` is the price. Expected solver calls are `effort / 2`, and expected tested solutions are `effort`.

## Code

```
C, the reference:  https://github.com/tevador/equix   LGPL-3.0
                   https://github.com/tevador/hashx   LGPL-3.0
Rust, the port:    arti crates equix 0.7.1, hashx 0.9.1, LGPL-3.0-only
Tor, in use:       src/ext/equix (vendored), src/feature/hs/hs_pow.c and hs_pow.h
```

The C API is four calls.

```c
equix_ctx* equix_alloc(equix_ctx_flags flags);  /* EQUIX_CTX_SOLVE | EQUIX_CTX_COMPILE, or EQUIX_CTX_VERIFY */
int equix_solve(equix_ctx* ctx, const void* challenge, size_t size, equix_solution out[8]);
equix_result equix_verify(equix_ctx* ctx, const void* challenge, size_t size, const equix_solution* sol);
void equix_free(equix_ctx* ctx);
```

A context holds the program generated for the current challenge, so each thread allocates its own: one per solver thread on the client, a small pool on the server.

`hs_pow.c` is the closest model for our code: `build_equix_challenge` and `validate_equix_challenge` are the two functions we reimplement with our own challenge, `hs_pow_solve` is the search loop, `hs_pow_verify` is the order of checks, and `hs_pow_queue_work` runs solving on the worker pool at low priority.

The licence is LGPL-3.0 for both implementations. Our library is AGPL-3.0, so linking asks nothing new of us, while a closed-source consumer of the library acquires the obligations of the LGPL for that part. Tor, under a BSD licence, answered this with an optional GPL build mode. Writing the solver from the specification removes the question, and costs the work of a careful reimplementation.

## Proof

```
proofOfWork = powEffort powEpoch powNonce powSolution
powEffort = 4*4 OCTET      ; Word32, the effort this proof was made for
powEpoch = 4*4 OCTET       ; Word32, the minute of server time this proof was made for
powNonce = powCounter powSearch
powCounter = 4*4 OCTET     ; Word32, the counter of this proof in the session
powSearch = 12*12 OCTET    ; the value the solver varies
powSolution = 16*16 OCTET  ; Equi-X solution
```

40 bytes.

```
challenge = personalisation sessionHash htonl(powEffort) htonl(powEpoch) powNonce
personalisation = 16*16 OCTET  ; "SimpleX PoW v1 " and one of %s"S" / %s"X" / %s"N"
sessionHash = 32*32 OCTET      ; sha256 of the transport session id
```

The client picks the next counter and a random search value, calls `equix_solve(challenge)`, computes `R = ntohl(blake2b_32(challenge || S))`, and accepts the solution when `R * E <= 2^32 - 1`, computed in 64 bits. Otherwise it increments the search value as a little-endian integer and repeats.

Counters are assigned in order and spent in order. A client that solves on several cores gives each core its own counter.

A proof verifies only under the protocol letter and the session hash it was made for, so it fails on another protocol, another server, and another connection.

## Commands

The proof is an optional field of the commands that create resources.

```
smpNew = %s"NEW " rcvAuthKey rcvDhKey optBasicAuth subMode optQueueReqData optNtfCreds optProofOfWork
fnew = %s"FNEW " fileInfo rcvKeys optBasicAuth fileStorageTime optProofOfWork
tnew = %s"TNEW " newNtfTkn optProofOfWork
optProofOfWork = %s"0" / (%s"1" proofOfWork)
```

A batch of transmissions carries one proof per command. Creation commands are sent to the servers of the user over a direct session, so the proxy carries none of them.

## Verification

The server checks, in this order:

1. `powEffort >= required effort for the request` - integer comparison.
2. `powEpoch` within the epoch window of the server, and at most one epoch ahead.
3. `powCounter` is above the window of the session, or inside it and unused.
4. `R * powEffort <= 2^32 - 1` - one Blake2b of 88 bytes.
5. `equix_verify(challenge, S) == EQUIX_OK` - 50-120 microseconds.
6. The counter is marked, and the resource is created.

The counter is marked on every verified proof, including one whose command then fails, so a proof pays for one attempt.

The window holds the last 64 counters, which admits the commands of one batch in any order. A counter below the window is rejected, and the client that skipped ahead loses the proofs it left behind.

Steps 1 to 4 cost about a microsecond, so a flood of malformed proofs is rejected before the Equi-X call. A session that fails verification repeatedly is closed, and the number of Equi-X verifications per session per second is capped.

## Learning the price

The price reaches the client three ways, and each of them is a message the protocol already sends.

1. The server handshake, at the start of the session. It states both prices, because the entitlement proof arrives in the client handshake that follows.
2. The response to a priced command. It states the price that applies to this session, so a client that presented an entitlement reads its own discount, and a client that paid the old price learns the new one while its command succeeds.
3. The error below, when the proof was absent, stale, or below the price.

```
powPrice = unitEffort serverEpoch  ; 8 bytes, appended to the response of a priced command
```

An increase costs one rejected command and the proof spent on it. A decrease costs nothing: the client over-pays until its next response, which states the lower price. A client that has been idle for longer than the epoch window solves at the last price it read, and pays one retry when the price moved meanwhile.

The price is public, as it is in Tor, and reading it needs one command without a proof.

## Errors and retry

A new error carries the price and the time of the server.

```
SMP:  ERR POW effort epoch
XFTP: FRErr (POW effort epoch)
NTF:  NRErr (POW effort epoch)
```

The client resets its price and epoch from the error, solves at the stated effort, and retries. Two retries are allowed for one command, which covers a price that moves again while the client solves; past that it reports that the server is busy, as it does when the effort exceeds its own maximum. Clients of earlier versions receive `AUTH`, as they do today when the basic auth of the server does not match.

A proof made for a higher effort than required is accepted, so a proof that outlives an increase stays usable while its epoch holds.

## Adaptive effort

Every 60 seconds the server updates `unitEffort` from its own pressure signals: resources created in the period against a configured budget, and storage used against the quota.

```
overBudget = created > creationBudget or used > highWater * quota
underBudget = created < creationBudget / 2 and used < lowWater * quota

overBudget:  unitEffort' = min(maxUnitEffort, max(unitEffort + 1, unitEffort * 2))
underBudget: unitEffort' = max(minUnitEffort, unitEffort * 2 / 3)
otherwise:   unitEffort' = unitEffort
```

`minUnitEffort` is the configured price of an idle server, and may be zero. Doubling reaches a defensive price within a few periods, and the `2/3` step returns to the idle price slowly. New sessions read the value from the handshake; sessions in progress read it from the error.

## Entitlement

The entitlement proof is verified once in the handshake and applies to the session, so the discount costs one verification per connection. The server configures the discount per entitlement name, alongside the storage time it already grants on XFTP.

The discount is a ratio, so the entitled price rises and falls with the load multiplier. A flood of creations under one badge raises the price for that badge as for everyone.

The discount is bounded by how a badge can be used. Proofs of one credential are unlinkable, so one badge presents on every session of a botnet at once, and the discount is the factor that badge buys. A discount of 4 to 8 keeps the badge a convenience for a person and a bounded gain for an attacker; the numbers are in the attacker table below. A higher-priced entitlement name may carry a larger discount.

This gives the badge a function on SMP and NTF, where it grants nothing today: the holder pays less CPU time, and the price of resources stays above zero for everyone.

## Costs

Equi-X on a 2017 desktop core produces about 150 candidate solutions per second; a phone core is about three times slower. Expected solving time is `effort / rate`.

```
effort   desktop core   phone core
    16          0.1 s        0.3 s
    64          0.4 s        1.3 s
   256          1.7 s        5.1 s
  1024          6.8 s       20.5 s
```

A queue at unit effort 16 costs a phone about 0.3 seconds. A 4 MB chunk stored for 48 hours is 8 units, so 128 effort, about 2.6 seconds on a phone, while the upload of the same chunk takes longer than that on most connections. A 100 MB file is 25 chunks, about 65 seconds of phone CPU spread across the upload, and about 8 seconds for a badge holder at a discount of 8.

Verification at 100 microseconds allows about 10000 proofs per second per core, which exceeds the rate at which queues are created and written to the store.

## Attacker cost

The same table read from the other side, at 150 candidate solutions per second per core:

```
unit effort   1 core      64 cores    1000 machines
         16   9 queues/s  600/s       9000/s
        256   0.6/s       38/s        600/s
       1024   0.15/s      9/s         150/s
```

The idle price is a speed bump. The defence is the increase: a flood raises `unitEffort` within a few periods, and the price that holds back a botnet also costs a phone 20 seconds per queue. Two things soften that price for ordinary users - it applies while the flood lasts, and a badge holder pays a fraction of it.

The same table for an attacker who bought one badge, presented on every machine:

```
unit effort   discount 4, 1000 machines   discount 8, 1000 machines
         16                 37000/s                    75000/s
       1024                   600/s                     1200/s
```

A discount of `d` is a botnet `d` times larger, for the price of one badge, and a badge is cheaper than any machine. So `d` is set by the amplification the server tolerates, and the price of the badge sets no bound. What keeps the amplification bounded under attack is that the increase applies to the badge holder as to everyone.

A client influences `unitEffort` only by consuming resources, which costs work, so the estimator is driven by paid-for demand.

## Client implementation

The C sources of equix and hashx are vendored under `cbits` and listed in `c-sources`, as libbbs and blst are today, and the Haskell side is a foreign import of the four calls above.

The agent solves in a worker thread. It holds few proofs ahead, sized by what the user does next rather than by the epoch window, and discards them when the epoch passes or the session ends. Solving on demand is the normal path, and the small stock covers the first commands of a burst while the rest are solved.

## Deployment

Proof of work is gated by a new version of each protocol: SMP, XFTP and NTF. Servers start with `unitEffort = 0`, which asks for nothing, and operators raise it. The existing controls - `allowNewQueues`, `allowNewFiles`, the basic auth of the server - stay as they are.

## Limits

- Proof of work prices bulk creation; it stops no one who is willing to pay. Tor states the same conclusion: the defence covers a single machine and a small botnet, and a large botnet needs another mechanism.
- Equi-X aims to narrow the gap between a CPU and a GPU, and published GPU measurements are absent. A hash-based puzzle would give an attacker with one GPU a factor of about a thousand over a phone, which is why Equi-X is chosen.
- Proofs are bound to a session, so a reconnection discards the unspent ones.
- The cost falls on the device of the user: battery and heat, most visible when a group of many members is created at once.
- Proof of work replaces no rate limit. A cap on creations per session per minute stays, and rejects the cheap part of a flood before any verification.

## Open questions

1. The price of an SMP queue against the price of stored bytes. A queue holds up to 128 messages of 16 KB for up to 21 days, and most queues stay near empty.
2. Whether `LSET` and `NKEY` are priced in the first version, or the queue alone.
3. Whether a proof is required for the first message to an unknown queue, which prices contact spam rather than storage.
4. The size of the proof stock the agent keeps, and whether it solves while the device is on battery.
