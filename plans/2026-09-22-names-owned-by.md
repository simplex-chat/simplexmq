# Owned-by: the names an address owns

A recovered seed does not say how many of its accounts have been used. Until it
does, a restored device cannot take a fresh account without risking one its
owner already has, and cannot find the names it already holds. This adds the
question the protocol could not ask: what does this address own.

This is Workstream B of the SimpleX names v2 plan, after the Ethereum crypto
primitives. The client consumer is the wallet recovery scan in simplex-chat.

## What this delivers

```
GET /v2/owned-by/<address>?offset=N   resolver, JSON OwnedNames
ROWN <address> <offset> -> ROWND      SMP v23 (nameOwnedSMPVersion)
ownedSimplexNames                     agent, over ownedNames in the server
```

The agent returns the relay it used alongside the answer, so a caller can pass
it back as used and ask the next account elsewhere. Sending every account of a
seed to one relay would tell that relay the accounts belong to one wallet; the
scan therefore asks one account per relay, and `getNextNameServer` avoids the
hosts already used where the configured set allows. `proxiedSMPRelayVersion` is
pinned to the current version so ROWN can be proxied at all — a scan that falls
back to a direct session hands the relay its address with its IP. The pin is
necessary but not sufficient: under the default `SPMUnknown` proxy mode a
configured names server is a known host, so the scan reaches it directly, as
RSLV already does.

Enumeration is read off the ERC-721 registrar (`balanceOf`,
`tokenOfOwnerByIndex`, `labelOf`), not from registration logs: the token is the
name, so a name acquired by transfer counts. Each name is then answered with the
`NameResponse` resolving it gives, so the client that scans can list the names
and act on them without asking again — the reason the per-name cost is worth
paying. The registrar does not maintain enumeration on expiry, so a name past
its grace is still enumerated; it answers as available, naming nothing the
account holds, so it is left out while still counting towards `inUse`.

## What `inUse` actually answers

`inUse` is `holds a name now, or nonce > 0, or balance > 0`, on the one chain
the resolver is configured with. Holding a name is only one way for an account
to be in use: an account that was funded, or ever sent a transaction, is in use
with no name, and a scan that reads names alone hands out an account its owner
is already using. Within that scope the signal is sound — an EOA's balance can
only fall through its own transaction, which bumps the nonce, so "funded then
drained" still reads as used, and an EIP-7702 delegation leaves the authority's
nonce incremented, so it needs no separate code check.

It does not see:

- **Accounts holding only other tokens.** An EOA can hold ERC-20s or NFTs with
  nonce 0 and no ether. ERC-20 has no reverse index, so answering this needs
  `eth_getLogs` over Transfer topics for all history, which providers cap, or an
  external indexer. Out of scope here.
- **Accounts used on another chain.** The same key is the same address on every
  L2 and sidechain; this chain's nonce and balance stay 0.
- **History, as opposed to current state.** `balanceOf` is present ownership. A
  name registered for an account by a controller — which leaves the owner at
  nonce 0 — and later transferred away, or lapsed and re-registered by someone
  else, leaves no trace.

The cost is bounded. A name-holding account is always found, so no account that
holds a name is ever mislabelled. A missed account matters only as a gap-limit
reset: the scan can stop up to `scanGapLimit` indexes early and not reach a name
beyond that. That is recovery incompleteness, recoverable by scanning again on a
better signal, not loss. In the other direction a dust transfer marks an account
used; the indexes come from hardened derivation with no published xpub, so they
cannot be enumerated to be dusted.

## What is deliberately absent

- **No token or indexer integration**, per the limits above.
- **Nonce and balance are not carried over SMP.** The resolver reports them, and
  `OwnedNames` keeps only the names, the flag and the cursor, so a client cannot
  yet see why an account is in use.
- **No caching, and no batching.** One owned-by is a `balanceOf` per configured
  TLD, then for each name the same reads resolving it takes - roughly fifteen
  `eth_call`s - plus the nonce and balance, all issued one at a time, so it is
  forked on
  the server the same way RSLV is and nothing is memoised. The page size trades
  against both the relay's response cap and its timeout, and it bounds names per
  registrar rather than per page, so a second TLD doubles a full page.
- **Enumeration is not atomic.** `balanceOf` and each `tokenOfOwnerByIndex` are
  separate calls at `latest`, so a transfer between them can duplicate or skip an
  entry, and successive pages can straddle blocks. Pinning every call to one
  block number is the fix if it ever matters for a recovery scan.
