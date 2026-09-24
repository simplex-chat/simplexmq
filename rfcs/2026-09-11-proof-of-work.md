# Proof of work for resource creation

## Summary

A client presents a proof of work when it asks a server to create a resource: an SMP queue, an XFTP file chunk, a notification token. The required effort is the price of the resource: its cost in units multiplied by the price per unit.

The server sets one price per unit for each tier: sessions without an entitlement, and sessions of each entitlement name. The prices are independent, so a flood in one tier raises the price of that tier alone.

The proof is bound to the transport session, so it is valid on one connection to one server, and single use within it.

## Interaction

The exchange adds no round trip. The server handshake states the prices and the server time, the session id is the challenge input that both sides already hold, and the client attaches a proof to the command that creates the resource.

Nothing is sent back for the price alone: it rides the messages that already exist.

## Freshness

A proof states the minute it was made for, and expires after a few minutes.

Without an expiry a client mints proofs for as long as a session lasts and spends the stock in one burst. The stock is minted at the idle price, so a rising price reaches the burst after it lands, and an hour of one machine arrives in seconds. The expiry bounds the stock to the work of one window.

```
powEpoch = 4*4 OCTET    ; Word32, minutes of server time
```

The server sends its current epoch in the handshake, and the client counts minutes from it with a monotonic clock, so the clock of the device takes no part. A proof verifies while `serverEpoch - powEpoch` is within the advertised window, and one epoch ahead of the server is admitted for rounding.

The window is the burst a client may prepare: a stock of `window * mint rate`. At 5 minutes and a price of 16, one phone core holds about 900 queue proofs, and one desktop core about 2800.

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
4. An expiry of minutes, against the seed window of two hours in Tor. A stock of proofs is worth one window of minting, so a price increase reaches a burst that was prepared under the old price.
5. Prices set by the operator. Effort is the resource cost in units multiplied by the price per unit, and the operator sets the price. The estimator of Tor is deferred.
6. One price per tier. The server knows the tier of every session, so a flood shows in its tier, and raising that price leaves the other tiers unchanged. An attacker without a badge leaves the price of badge holders where it was; an attacker with a supporter badge leaves the price of legend holders where it was.
7. An entitlement lowers the price, and neither raises it nor removes it. A credential presents on any number of sessions without linking them, so a free tier would sell an attacker unlimited creation for the price of one badge; and a badge that could cost more than no badge would break the promise it was sold with, the promise the XFTP server keeps for storage time.

Kept from Tor: the Equi-X function, the linear effort scale, and the verification formula.

## Cost units

Each protocol defines the unit of its own price list. The server advertises the price per unit; the client computes the effort of its request.

```
SMP:  1 unit per new queue
      1 unit per queue link data record (in NEW or LSET)
XFTP: 1 unit per megabyte-day of requested storage, rounded up
      chunkUnits = ceil(size / 1048576 * storageHours / 24)
NTF:  1 unit per token registration
```

`effort = price * units`, capped at 2^32 - 1.

## Handshake parameters

Each protocol adds one optional field to the server handshake, encoded from the version that introduces proof of work.

```
powParams = %s"0" / (%s"1" powScheme defaultPrice entPrices serverEpoch epochWindow)
powScheme = 1*1 OCTET        ; 1 = Equi-X and Blake2b
defaultPrice = 4*4 OCTET     ; Word32, effort per unit without an entitlement, 0 = proof not required
entPrices = count *entPrice
entPrice = entName price
entName = shortString        ; entitlement name, as in the entitlement proof
price = 4*4 OCTET            ; Word32, effort per unit for a session of this entitlement
serverEpoch = 4*4 OCTET      ; Word32, current minute of server time
epochWindow = 1*1 OCTET      ; minutes a proof stays valid
```

The server handshake precedes the client handshake that carries the entitlement proof, so every price is sent. The client applies the price of its entitlement name, and the default price when it presented no entitlement or when its name is absent from the list.

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

```
S = packed solution         ; 8 indices, each a little-endian uint16, 16 bytes
blake2b_32 = BLAKE2b initialised with a 4-byte output length
R = the 4 bytes of blake2b_32, read big-endian
```

BLAKE2b with a 4-byte output length differs from the first 4 bytes of BLAKE2b-512, because the length is a parameter of the initial state. Both definitions follow `validate_equix_challenge` and `pack_equix_solution` in `hs_pow.c`.

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

1. `powEffort >= price of the tier of the session * units of the request` - integer comparison.
2. `powEpoch` within the epoch window of the server, and at most one epoch ahead.
3. `powCounter` is above the window of the session, or inside it and unused.
4. `R * powEffort <= 2^32 - 1` - one Blake2b of 88 bytes.
5. `equix_verify(challenge, S) == EQUIX_OK` - 50-120 microseconds.
6. The counter is marked, and the resource is created.

The counter is marked on every verified proof, including one whose command then fails, so a proof pays for one attempt.

The window holds the last 64 counters, which admits the commands of one batch in any order. A counter below the window is rejected, and the client that skipped ahead loses the proofs it left behind.

Steps 1 to 4 cost about a microsecond, so a flood of malformed proofs is rejected before the Equi-X call. A session that fails verification repeatedly is closed, and the number of Equi-X verifications per session per second is capped.

## Entitlement

SMP and NTF servers verify the entitlement proof in the handshake, as the XFTP server does. A name the server prices is verified once per session; a name it does not price is ignored without verification, and the session pays the default price. A proof that fails to verify leaves the session at the default price too.

The tier of the session is fixed at the handshake, so every command in it is priced without further work.

An entitlement lowers the price, and neither raises it nor removes it:

```
min(1, price) <= price_for_<name> <= price
```

The server exits at startup when a configured price breaks this rule, and logs each name that breaks it, as the XFTP server does when an entitlement storage time is below the default. An entitlement price equal to the default is allowed, as an equal storage time is on XFTP.

The control port sets the three prices in one command, and refuses a triple that breaks the rule. The triple is checked as a whole, so the order in which prices change plays no part.

This gives the badge a function on SMP and NTF, where it grants nothing today: the holder pays less CPU time, and a flood outside its tier leaves its price where it was.

## Learning the price

The price reaches the client three ways, and each of them is a message the protocol already sends.

1. The server handshake, at the start of the session. It states the price of every tier, because the entitlement proof arrives in the client handshake that follows.
2. The response to a priced command. It states the price of the tier of the session, so a client that paid the old price learns the new one while its command succeeds.
3. The error below, when the proof was absent, stale, or below the price. A client whose entitlement failed to verify learns here that it pays the default price.

```
powPrice = price serverEpoch  ; 8 bytes, appended to the response of a priced command
```

An increase costs one rejected command and the proof spent on it. A decrease costs nothing: the client over-pays until its next response, which states the lower price. A client that has been idle for longer than the epoch window solves at the last price it read, and pays one retry when the price moved meanwhile.

The prices are public, as the suggested effort is in Tor, and the list of priced entitlement names is public with them.

## Errors and retry

A new error carries the price and the time of the server.

```
SMP:  ERR POW price epoch
XFTP: FRErr (POW price epoch)
NTF:  NRErr (POW price epoch)
```

The client resets its price and epoch from the error, solves at the stated price, and retries. Two retries are allowed for one command, which covers a price that moves again while the client solves; past that it reports that the server is busy, as it does when the effort exceeds its own maximum. Clients of earlier versions receive `AUTH`, as they do today when the basic auth of the server does not match.

A proof made for a higher effort than required is accepted, so a proof that outlives a decrease stays usable while its epoch holds.

## Setting prices

The operator sets the prices: the configuration holds the values the server starts with, and the control port reads and changes them while it runs.

```
[PROOF_OF_WORK]
price = 16                  ; effort per unit without an entitlement, 0 = proof not required
price_for_supporter = 4     ; effort per unit with the supporter entitlement, at least 1 and at most price
price_for_legend = 2        ; effort per unit with the legend entitlement, at least 1 and at most price
epoch_window_minutes = 5
```

The keys follow `expire_files_hours_for_<name>` of the XFTP server, and on the XFTP server both keys name the same entitlements.

Control port commands, on SMP, XFTP and NTF servers:

```
pow             ; user role: the three prices, epoch window, counts of the current period per tier
pow p0 p1 p2    ; admin role: set the prices - p0 without an entitlement, p1 supporter, p2 legend
```

A change reaches new sessions through the handshake, and sessions in progress through their next response or error. It lasts until the server stops; the configuration holds the value for the next start. The XFTP and NTF control ports gain the admin role check that the SMP control port already has; both check the user role today.

The estimator of Tor is deferred. If prices set by hand prove too slow, it runs per tier on the creations of that tier, between bounds set on the control port.

## Statistics

The server counts per tier, so a flood shows in its tier, and the use of each entitlement is accounted for. Sessions without an entitlement are counted under `default`.

```
sessions            ; sessions of the tier
entFailed           ; entitlement proofs that failed to verify
proofsAccepted
effortAccepted      ; sum of the effort of accepted proofs
proofsAbsent
proofsBelowPrice
proofsStale         ; epoch outside the window
proofsReused        ; counter below the window or already marked
proofsInvalid       ; Blake2b target or Equi-X check failed
created             ; queues, chunks or tokens created
```

The counts appear in `pow` for the current period, in the stats log, and in the Prometheus metrics. They name a tier, never a session.

## Costs

Equi-X on a 2017 desktop core produces about 150 candidate solutions per second; a phone core is about three times slower. Expected solving time is `effort / rate`.

```
effort   desktop core   phone core
    16          0.1 s        0.3 s
    64          0.4 s        1.3 s
   256          1.7 s        5.1 s
  1024          6.8 s       20.5 s
```

A queue at a price of 16 costs a phone about 0.3 seconds. A 4 MB chunk stored for 48 hours is 8 units, so 128 effort, about 2.6 seconds on a phone, while the upload of the same chunk takes longer than that on most connections. A 100 MB file is 25 chunks, about 65 seconds of phone CPU spread across the upload, and about 8 seconds for a badge holder at a price of 2.

Verification at 100 microseconds allows about 10000 proofs per second per core, which exceeds the rate at which queues are created and written to the store.

## Attacker cost

The same table read from the other side, at 150 candidate solutions per second per core:

```
price    1 core      64 cores    1000 machines
   16    9 queues/s  600/s       9000/s
  256    0.6/s       38/s        600/s
 1024    0.15/s      9/s         150/s
```

The idle price is a speed bump. The defence is the increase in the tier the flood uses, and the statistics show which tier that is.

An attacker without a badge floods the default tier. Its price rises, and badge holders keep their prices.

An attacker who bought a badge presents it on every machine: at a price of 2, one badge on 1000 machines creates 75000 queues per second until the price of that tier is raised. The raise is paid by the holders of that badge while the flood lasts, and by no one else.

The price of a badge tier rises at most to the default price. A flood in a badge tier that the default price does not hold back needs the default raised too, so users without a badge pay that raise as well; the other badge tiers keep their prices.

## Client implementation

The C sources of equix and hashx are vendored under `cbits` and listed in `c-sources`, as libbbs and blst are today, and the Haskell side is a foreign import of the four calls above.

The agent solves in a worker thread. It holds few proofs ahead, sized by what the user does next rather than by the epoch window, and discards them when the epoch passes or the session ends. Solving on demand is the normal path, and the small stock covers the first commands of a burst while the rest are solved.

## Deployment

Proof of work is gated by a new version of each protocol: SMP, XFTP and NTF. Servers start with every price at zero, which asks for nothing, and operators raise them. The existing controls - `allowNewQueues`, `allowNewFiles`, the basic auth of the server - stay as they are.

## Limits

- Proof of work prices bulk creation; it stops no one who is willing to pay. Tor states the same conclusion: the defence covers a single machine and a small botnet, and a large botnet needs another mechanism.
- Prices change by hand, so a flood runs at the old price until an operator raises it. The expiry bounds the stock prepared before the flood; the flood that follows is priced at the new value from the next response.
- Equi-X aims to narrow the gap between a CPU and a GPU, and published GPU measurements are absent. A hash-based puzzle would give an attacker with one GPU a factor of about a thousand over a phone, which is why Equi-X is chosen.
- Proofs are bound to a session, so a reconnection discards the unspent ones.
- The cost falls on the device of the user: battery and heat, most visible when a group of many members is created at once.
- Proof of work replaces no rate limit, and the servers limit neither creations nor commands per session today. A cap on creations per session per minute would reject the cheap part of a flood before any verification.

## Open questions

1. Clients of earlier versions. A price above zero refuses their creation commands with `AUTH`, and admitting them without a proof admits any attacker who speaks the earlier version. When operators may raise prices, against the spread of the client release.
2. XFTP units without a stated storage time. The client learns the granted time only from `SIDS`, and the agent usually sends no storage time, which asks for the maximum. The client needs the maximum of its tier to compute megabyte-days: in `powParams`, or the price by size alone.
3. Service sessions. A service signs `NEW` with its service key, and a chat relay creates queues in volume. A service certificate is self-issued, so it cannot exempt a session: the default price, or a price of its own.
4. The commands priced in the first version. `NEW` and `FNEW` and `TNEW` are; `LSET`, `NKEY`, `FADD` and `SNEW` are open, and so is the first message to an unknown queue.
5. The version plan. Pricing by entitlement needs the entitlement proof in the SMP and NTF handshakes: one version for both changes, or the handshake first.
6. The numbers the implementation needs: the client maximum effort before it reports a busy server, the cap on Equi-X verifications per session per second, the failed proofs that close a session, the size of the verifier pool.
7. The licence: the LGPL code of tevador vendored under `cbits`, or a reimplementation.
8. A cap on creations per session, in this work or apart from it.
9. Client behaviour: solving on demand alone or with a small stock, the number of solver threads on a phone, solving on battery, and an agent event for the interface when solving takes longer than a second.
10. Whether a price set on the control port is written back to the configuration.
