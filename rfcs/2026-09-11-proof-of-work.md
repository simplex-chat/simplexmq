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

The window is the burst a client may prepare: a stock of `window * mint rate`. At 5 minutes and a price of 16, one desktop core holds about 2800 queue proofs.

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
8. A budget for clients of earlier versions, where Tor serves them at the lowest priority. They cannot pay, so they share a number of creations per minute.

Kept from Tor: the Equi-X function, the linear effort scale, the verification formula, and the exact byte definitions of the target check.

## Cost units

Each protocol defines the unit of its own price list. The server advertises the price per unit; the client computes the effort of its request.

```
SMP:  1 unit per new queue
      1 unit per queue link data record (in NEW, or in LSET on a queue without one)
XFTP: 1 unit per 64 KB stored for 24 hours
      chunkUnits = ceil(size / 65536 * storageHours / 24)
      storageHours = min(requested hours, maximum hours of the tier); absent or 0 = the maximum
NTF:  1 unit per token registration
```

`effort = price * units`, capped at 2^32 - 1.

64 KB is the smallest chunk. The server takes chunks of 64 KB, 256 KB, 1 MB and 4 MB, and the test configuration adds 128 KB; each is a whole number of units.

## Handshake parameters

Each protocol adds one optional field to the server handshake, encoded from the version that introduces proof of work.

```
powParams = %s"0" / (%s"1" powScheme defaultPrice entPrices serverEpoch epochWindow)
powScheme = 1*1 OCTET        ; 1 = Equi-X and Blake2b
defaultPrice = tierPrice     ; without an entitlement; price 0 = proof not required
entPrices = count *entPrice
entPrice = entName tierPrice
entName = shortString        ; entitlement name, as in the entitlement proof
serverEpoch = 4*4 OCTET      ; Word32, current minute of server time
epochWindow = 1*1 OCTET      ; minutes a proof stays valid

SMP, NTF:  tierPrice = price
XFTP:      tierPrice = price storageHours
price = 4*4 OCTET            ; Word32, effort per unit
storageHours = 4*4 OCTET     ; Word32, maximum storage time of the tier
```

The server handshake precedes the client handshake that carries the entitlement proof, so every price is sent. The client applies the price of its entitlement name, and the default price when it presented no entitlement or when its name is absent from the list.

The XFTP client learns the maximum storage time of its tier from the same entry, so it computes the units of a chunk that asks for the maximum. The grant in `SIDS` stays as it is.

## Algorithm

Equi-X, by tevador, is Equihash(60,3) with two changes: the hash is HashX, and the indices are summed modulo 2^60 rather than xored.

HashX takes a seed - here the challenge - and generates a short program of integer instructions over eight 64-bit registers, which maps a 64-bit input to a 64-bit output. The program differs for every seed, so hardware built for one program serves no other. That is where the resistance to an ASIC comes from, and what narrows the distance to a GPU.

HashX runs the program in one of two modes. Compiled, it writes machine code for x86-64 or arm64 into executable memory, and hashes in under 100 nanoseconds. Interpreted, it hashes in 1-2 microseconds. Our clients take the interpreter on every platform: iOS refuses executable memory to App Store apps, GrapheneOS stops an Android app that loads code at run time, and desktop clients follow the phones. An attacker enables the compiler with one flag, `EQUIX_CTX_COMPILE`, or runs the benchmark of tevador as it is.

Solving finds eight 16-bit indices `i0..i7` with `HX(i0) + ... + HX(i7) = 0 (mod 2^60)`, under the tree conditions of Wagner's algorithm - 15 trailing zero bits on each pair, 30 on each quadruple, 60 on the sum - and an ordering condition that makes the solution canonical. The solver holds tables over 2^16 items, which is the 1.8 MiB. A solution is `8 * uint16`, so 16 bytes, and one call returns about two of them.

Verification recomputes the eight HashX values and checks the three sums. It takes 50-120 microseconds and a few kilobytes.

The protocol layer above it is the target check: a solution counts when `blake2b_32(challenge || solution) * effort <= 2^32 - 1`. Finding a solution is the constant cost; landing one in a slice of `1/effort` is the price. Expected solver calls are `effort / 2`, and expected tested solutions are `effort`.

## Code

```
C, the reference:  https://github.com/tevador/equix   LGPL-3.0, hashx as its submodule
                   https://github.com/tevador/hashx   LGPL-3.0
Rust, the port:    arti crates equix 0.7.1, hashx 0.9.1, LGPL-3.0-only
Tor, in use:       src/ext/equix (vendored), src/feature/hs/hs_pow.c and hs_pow.h
```

The library is a git submodule at `cbits/equix`, from a fork under simplex-chat, as `cbits/libbbs` is today; hashx comes in as its nested submodule. The fork starts from tevador's repository, after a comparison with the copy in Tor for fixes. The C sources are listed in `c-sources`, and the Haskell side is a foreign import of the four calls below.

```c
equix_ctx* equix_alloc(equix_ctx_flags flags);  /* EQUIX_CTX_SOLVE | EQUIX_CTX_COMPILE, or EQUIX_CTX_VERIFY */
int equix_solve(equix_ctx* ctx, const void* challenge, size_t size, equix_solution out[8]);
equix_result equix_verify(equix_ctx* ctx, const void* challenge, size_t size, const equix_solution* sol);
void equix_free(equix_ctx* ctx);
```

A context holds the program generated for the current challenge, so each thread allocates its own: one per solver thread on the client, a small pool on the server. Clients allocate without `EQUIX_CTX_COMPILE`.

`hs_pow.c` is the closest model for our code: `build_equix_challenge` and `validate_equix_challenge` are the two functions we reimplement with our own challenge, `hs_pow_solve` is the search loop, `hs_pow_verify` is the order of checks, and `hs_pow_queue_work` runs solving on the worker pool at low priority.

The licence is LGPL-3.0 for both implementations. Our library is AGPL-3.0, so linking asks nothing new of us, while a closed-source consumer of the library acquires the obligations of the LGPL for that part.

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
smpLSet = %s"LSET " linkId queueLinkData optProofOfWork
fnew = %s"FNEW " fileInfo rcvKeys optBasicAuth fileStorageTime optProofOfWork
tnew = %s"TNEW " newNtfTkn optProofOfWork
optProofOfWork = %s"0" / (%s"1" proofOfWork)
```

`LSET` is priced when the queue holds no link data; on a queue that holds some, it replaces the data and carries no proof. `NKEY`, `FADD` and `SNEW` are not priced. The first message to an unknown queue is out of scope.

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

The window holds the last 64 counters, which admits proofs that arrive out of order, from commands sent concurrently on one session. A counter below the window is rejected, and the client that skipped ahead loses the proofs it left behind.

Steps 1 to 3 cost less than a microsecond. Step 4 costs an attacker about `effort` Blake2b calls to pass with a random solution, so the Equi-X call in step 5 is what a forged proof buys. The server closes a session after 3 consecutive proofs that fail step 4 or step 5. An honest client checks its proof before sending it, so it never fails these steps; a stale proof or one below the price fails steps 1 to 3, which can happen to an honest client after a change of price or epoch, and closes nothing.

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

## Services

A service session creates resources without a proof when the SMP server records its service as created before a configured date. `serviceCreatedAt` of the service record holds that date, so the services that presented certificates before the release are exempt, and the rule needs no migration.

```
[PROOF_OF_WORK]
exempt_services_created_before = 2026-10-15
```

A service registered after that date pays the default price. Exempt sessions are a tier of their own in the statistics.

The date is a transition. The follow-up work gives services a certificate signed by an operator, an online certificate under an offline one as SMP servers have, issued on a certificate request from each partner; a server recognises the operators in its configuration and exempts their services. It is out of scope here.

## Clients of earlier versions

A session below the version that introduces proof of work cannot present a proof. Its creation commands draw on one budget, shared by all such sessions: a number of creations per minute, set on the control port, unlimited at first.

While an attacker uses a client of the proof-of-work version, the budget goes to clients of earlier versions and none of them notices it. When an attacker uses an earlier client, the damage is the budget. A budget of zero refuses them all; the generic lever against earlier versions stays the version range, set without a release.

A command over the budget receives a new error, `BUSY`:

```
SMP:  ERR BUSY
XFTP: FRErr BUSY
NTF:  NRErr BUSY
```

The serializer sends `BUSY` to a session of the proof-of-work version as it is, and maps it for a session of an earlier version, as it maps `BLOCKED` for sessions below `clientNoticesSMPVersion` today:

```
SMP:  BUSY -> STORE busy
NTF:  BUSY -> STORE busy
XFTP: BUSY -> TIMEOUT
```

SMP and NTF share `ErrorType`, which has no `TIMEOUT`. Among the errors an SMP or NTF server sends, the deployed agent retries only `STORE`. An asynchronous `NEW` or `JOIN` retries with a growing interval and takes the next server of the user on each attempt, so a refused client moves to a server that has budget left; the XFTP agent retries `FNEW` on `TIMEOUT`. `TNEW` returns the error to the app that called `registerNtfToken`, and the agent holds no retry loop for it. An interactive command shows the error once, and the deployed apps show `STORE busy` in their generic error alert.

The other errors mislead or stop the client: `QUOTA` is shown as a connection that reached its limit of undelivered messages, `AUTH` as a connection error of authorisation, and both end an asynchronous command. A budget of zero keeps the retries of earlier clients running at the longest interval, and a raised budget lets them through without an update.

A client of the proof-of-work version shows `BUSY` to the user: an interactive command shows it at once, and a background command shows it when its retries expire on the client.

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

The client resets its price and epoch from the error, solves at the stated price, and retries. Two retries are allowed for one command, which covers a price that moves again while the client solves; past that it reports that the server is busy, as it does when the effort exceeds 4096, its own maximum.

A proof made for a higher effort than required is accepted, so a proof that outlives a decrease stays usable while its epoch holds.

## Setting prices

The operator sets the prices: the configuration holds the values the server starts with, and the control port reads and changes them while it runs.

```
[PROOF_OF_WORK]
price = 16                  ; effort per unit without an entitlement, 0 = proof not required
price_for_supporter = 4     ; effort per unit with the supporter entitlement, at least 1 and at most price
price_for_legend = 2        ; effort per unit with the legend entitlement, at least 1 and at most price
epoch_window_minutes = 5
exempt_services_created_before = 2026-10-15
```

The keys follow `expire_files_hours_for_<name>` of the XFTP server, and on the XFTP server both keys name the same entitlements.

Control port commands, on SMP, XFTP and NTF servers:

```
pow                    ; user role: prices, budget of earlier versions, epoch window, counts of the current period per tier
pow p0 p1 p2           ; admin role: set the prices - p0 without an entitlement, p1 supporter, p2 legend
pow old <n>            ; admin role: set the budget of earlier versions, creations per minute
pow old unlimited      ; admin role: remove the budget
```

A change reaches new sessions through the handshake, and sessions in progress through their next response or error.

Prices and the budget set on the control port are saved with the server state and restored at start, so a change made during an attack survives a restart that the attack outlasts. While they differ from the configuration, the server logs a warning at stop and at start, and `pow` shows both values.

The XFTP and NTF control ports gain the admin role check that the SMP control port already has; both check the user role today.

The estimator of Tor is deferred. If prices set by hand prove too slow, it runs per tier on the creations of that tier, between bounds set on the control port.

## Statistics

The server counts per tier, so a flood shows in its tier, and the use of each entitlement is accounted for. Sessions without an entitlement are counted under `default`, exempt services under `service`, and sessions of earlier versions under `old`.

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
sessionsClosed      ; sessions closed after invalid proofs
overBudget          ; creations of earlier versions refused by the budget
created             ; queues, chunks or tokens created
```

The counts appear in `pow` for the current period, in the stats log, and in the Prometheus metrics. They name a tier, never a session.

## Costs

The rates below are estimates to be replaced by measurement on devices.

A solver call hashes 2^16 indices. Compiled, a desktop core makes about 150 candidate solutions per second, measured by tevador. Interpreted at 1-2 microseconds per hash, a call spends about 100 milliseconds hashing, so the same core makes about 15-25, and a phone core, about three times slower, about 5-8.

```
effort   desktop, compiled   phone, interpreted
     4              0.03 s                0.6 s
    16              0.1 s                 2.5 s
    64              0.4 s                10 s
   256              1.7 s                40 s
```

A queue at a price of 4 costs a phone about 0.6 seconds, and a queue at 16 about 2.5 seconds. A 4 MB chunk stored for 48 hours is 128 units; at an XFTP price of 1 it costs a phone about 20 seconds, while the upload of the same chunk takes seconds to minutes. The prices of the configuration examples assume compiled solving, and fall with this table.

The client maximum of 4096 effort is about 10 minutes on a phone.

Verification at 100 microseconds allows about 10000 proofs per second per core, which exceeds the rate at which queues are created and written to the store.

## Attacker cost

An attacker solves on desktops with the compiler, at 150 candidate solutions per second per core:

```
price    1 core      64 cores    1000 machines
    4    37/s        2400/s      37000/s
   16    9/s         600/s       9000/s
  256    0.6/s       38/s        600/s
```

A desktop core of the attacker solves 20-30 times faster than a phone core of a user: three times from the hardware, and the rest from the compiler. The gap sets how high a price can rise before users feel it.

The idle price is a speed bump. The defence is the increase in the tier the flood uses, and the statistics show which tier that is.

An attacker without a badge floods the default tier. Its price rises, and badge holders keep their prices.

An attacker who bought a badge presents it on every machine: at a price of 2, one badge on 1000 machines creates 75000 queues per second until the price of that tier is raised. The raise is paid by the holders of that badge while the flood lasts, and by no one else.

The price of a badge tier rises at most to the default price. A flood in a badge tier that the default price does not hold back needs the default raised too, so users without a badge pay that raise as well; the other badge tiers keep their prices.

## Client implementation

The agent solves on demand, in one solver ordered by `NetworkRequestMode`: `NRMInteractive` work first, then `NRMBackground`. A solver call takes about 100 milliseconds on a phone, so background work yields between calls when interactive work arrives.

Creation outside the actions of the user - connections to the members of a group - is background work, and background solving has a budget of CPU time per hour. Past it, background creations wait, and the asynchronous commands that carry them retry them later. A group of many members cannot turn the device into a miner.

The solver keeps no stock. A proof is discarded when its epoch passes or its session ends.

## Deployment

Proof of work comes in the same version as the entitlement proof in the handshake: SMP version 23 and NTF version 4. XFTP carries the entitlement proof from version 4, which is released, so proof of work comes in XFTP version 5. Servers start with every price at zero, which asks for nothing, and operators raise them. The existing controls - `allowNewQueues`, `allowNewFiles`, the basic auth of the server - stay as they are.

## Limits

- Proof of work prices bulk creation; it stops no one who is willing to pay. Tor states the same conclusion: the defence covers a single machine and a small botnet, and a large botnet needs another mechanism.
- Prices change by hand, so a flood runs at the old price until an operator raises it. The expiry bounds the stock prepared before the flood; the flood that follows is priced at the new value from the next response.
- Phones solve with the interpreter and attackers with the compiler, which gives an attacker 20-30 times a phone per core. Equi-X narrows the gap between a CPU and a GPU, which published measurements leave open; a hash-based puzzle would give one GPU a factor of about a thousand over a phone.
- Proofs are bound to a session, so a reconnection discards the unspent ones.
- The cost falls on the device of the user: battery and heat, most visible when a group of many members is created at once.
- Proof of work replaces no rate limit, and the servers limit neither creations nor commands per session today. A cap on creations per session is out of scope.

## Open questions

1. HashX against a fixed hash. Our clients interpret and an attacker compiles, which the estimates put at about 8 times on one core. A fixed hash - Equihash(60,3) over SipHash - removes that factor, and gives a GPU the same program for every challenge, so it runs thousands of instances in step, as the Equihash miners do; that factor is unmeasured. The measurements that decide it: interpreted solving on a mid-range Android phone and an iPhone, compiled against interpreted on one desktop core, and an estimate of a GPU solver for the fixed hash.
2. The client maximum: 4096 effort is about 10 minutes on a phone. A maximum in seconds, from the rate the device measures, holds the same wait on every device.
3. The budget of background solving, in CPU seconds per hour.
4. Whether agents of releases older than the deployed one treat `STORE` and `TIMEOUT` as temporary, as the deployed agent does.

## Follow-up

Certificates for services signed by an operator, with the requests of partners, as described under Services.
