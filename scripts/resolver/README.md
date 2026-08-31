# Self-hosted SNRC stack

One `docker compose up` runs the self-hosted SimpleX Namespace (SNRC) backend
against **Ethereum mainnet** (where the `.testing` contracts live):

| # | Component | What it does |
|---|---|---|
| 1 | **reth + nimbus** | self-hosted Ethereum node (`--minimal` — enough for the resolver's `eth_call` at chain head) |
| 2 | **resolver** | the REST resolver the smp-server's `[NAMES]` role queries (`snrc-resolve.py`) |

## Requirements

- **Docker** + Compose v2.
- **≥ 300 GB NVMe SSD** for `reth --minimal` (~260 GB on mainnet; TLC, not QLC
  — QLC stalls during sync) + **32 GB RAM**, fast multi-core CPU.
- **~1 day** for the initial reth sync. The resolver returns errors until reth
  has caught up — that's expected.
- Firewall: open p2p ports `30303` (tcp/udp) and `9000` (tcp/udp).

## 1. Configure

Edit `.env` — the defaults work as-is; override only if needed:

```sh
NETWORK=mainnet                                               # default
TRUSTED_NODE_URL=https://mainnet-checkpoint-sync.attestant.io # default
```

Everything else (NAT) has a working default baked into `docker-compose.yml`;
uncomment the hints in `.env` only to override.

## 2. Run

```sh
cd scripts/resolver
docker compose up -d
docker compose logs -f reth resolver
```

`depends_on` handles ordering automatically (start node → start resolver).

## 3. Wait for the node to sync

```sh
docker compose logs --tail=20 reth
```

This is the long pole (~1 day on mainnet). Until reth is synced the resolver
returns `502`.

## Verify

Run these once the stack is up (the node-dependent ones pass after sync):

**1. reth is reachable and reporting a block:**
```sh
curl -s -X POST http://127.0.0.1:8545 \
  -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' | jq
```

**2. resolver is healthy:**
```sh
curl -s http://127.0.0.1:8000/health | jq
# → {"ok": true, "rpc": "http://reth:8545", "registries": {"testing": "0x…", "simplex": ""}}
```

**3. resolver resolves a live name** (`foobar.testing` is a populated test name):
```sh
curl -s http://127.0.0.1:8000/resolve/foobar.testing | jq
# → {"name":"foobar.testing","nickname":"Foo","simplexContact":["https://smp16.simplex.im/a#…"], … }
```

**4. resolver answers the reverse lookup:**
```sh
curl -s http://127.0.0.1:8000/owned-by/0x69a6000000000000000000000000000000002d32 | jq '.names'
# → [{"name":"foobar.testing","status":"registered","expires":1780…, …}]
```

**Wire your smp-server:** in its `[NAMES]` section set
`resolver_endpoint: http://127.0.0.1:8000` (no auth needed for loopback).

## Ports (all loopback unless noted)

| Service | Host | Purpose |
|---|---|---|
| reth JSON-RPC | `127.0.0.1:8545` | smp-server RPC |
| reth p2p | `:30303` tcp/udp | Ethereum sync (open on firewall) |
| nimbus p2p | `:9000` tcp/udp | beacon sync (open on firewall) |
| nimbus REST | `127.0.0.1:5052` | beacon API |
| **resolver** | `127.0.0.1:8000` | SNRC REST (`/resolve`, `/owned-by`, `/health`) |

## Caveats

- **All images track `:latest`** (reth, nimbus) — you get upstream fixes on each
  `docker compose pull`; re-run the verify checks after pulling.
- All ports bind to loopback; expose only what you put behind a TLS reverse proxy.

## Teardown

```sh
docker compose down       # stop, keep all state
docker compose down -v    # also wipe volumes → full re-sync
```

`down -v` wipes the chain data (full re-sync on the next `up`).

---

## Resolver API reference

The resolver (`snrc-resolve.py`, host `127.0.0.1:8000`) is also runnable
standalone for local dev (no Docker), via [`uv`](https://docs.astral.sh/uv/):

```sh
uv run scripts/resolver/service/snrc-resolve.py  # defaults to local reth + mainnet .testing
```

### Response shape

```jsonc
{
  "name": "foobar.testing",
  "nickname": "Foo", "website": "https://foo.bar", "location": "",
  "simplexContact": ["https://smp16.simplex.im/a#…", "https://smp11…"],  // primary first, fallbacks after
  "simplexChannel": [],
  "eth": null, "btc": "bc1q…", "xmr": "4ANz…", "dot": "139G…",
  "owner": "0xd83b…", "resolver": "0x80fa…",
  "status": "registered",      // registered | grace | expired | unregistered | noResolver | unknown
  "expires": 1780000000,       // Unix seconds; when the registration ends
  "graceEnds": 1787776000      // expires + GRACE_PERIOD; last moment the owner can renew
}
```

`simplexContact`/`simplexChannel` are arrays (a name can advertise multiple SMP
servers; clients try them in order). On-chain they're a single comma-separated
text record; the resolver splits/trims/drops-empties. Address encodings are
canonical per chain (EIP-55 / bech32 / SS58 / Monero-base58). Subnames work
identically (`bar.foobar.testing`).

### Registration status and expiry

`status`, `expires` and `graceEnds` are on every response that got far enough to
know them, including a successful resolve — so a client that has just resolved a
name already holds its expiry and needs no second request to warn about it.
`expires` and `graceEnds` are Unix timestamps in seconds; both are `null` when
unknown.

| `status` | Meaning |
|---|---|
| `registered` | live; `expires` is when that ends |
| `grace` | lapsed, but only the previous owner may renew it, until `graceEnds` |
| `expired` | lapsed and past grace — anyone may register it now |
| `unregistered` | never registered, and free to take |
| `reserved` | not registered, and held for a brand — registration will be refused |
| `noResolver` | registered, but points nowhere |
| `unknown` | no `SNRC_REGISTRAR_<TLD>` configured, so status could not be read |

Which HTTP code carries each, and what every other input does, is in
[Every case](#every-case-and-what-comes-back) at the end.

The split between `grace` and `expired` mirrors the registrar's own
`available(id)` rule (`expires + GRACE_PERIOD < now`), with `GRACE_PERIOD` read
from the contract rather than assumed. Note that `available(id)` alone cannot
distinguish these: it is also true for a name nobody ever registered, since
`0 + GRACE_PERIOD < now`. A zero expiry is what separates *never taken* from
*taken and since released*.

Subnames report the status of the 2LD they sit under, which is the useful
answer — a subname is only as valid as the name above it.

### Asking without naming the name

A client checking whether a name is free is usually about to register it, so
the question itself is worth front-running. Substitute the label's keccak hash
for the label and the answer is identical:

```sh
# instead of /resolve/acme.testing
curl -s http://127.0.0.1:8000/resolve/0x$(printf acme | keccak-256sum | cut -d' ' -f1).testing
```

namehash is defined as `keccak(parent || keccak(label))`, so supplying
`keccak(label)` yields the same node — and the registrar keys both
`nameExpires` and `reservedNames` on the labelhash, so status needs nothing
else. Whoever runs the resolver sees a hash and learns which name you are
interested in only if they already guessed it.

The two forms cannot be confused: a hashed label is `0x` and 64 hex characters,
66 in total, and the registrar caps real labels well below that. Only the
leftmost label may be hashed, and only for a 2LD.

Registration is still a public act — this hides the *interest*, not the
eventual registration, and the commit-reveal in the controller is what protects
the registration itself.

### Errors

Every non-2xx body carries a stable `error` code to branch on and a human
`message`, alongside the subject (`name` or `address`):

```jsonc
{"name": "alice.testing", "error": "unregistered",
 "message": "this name has never been registered",
 "status": "unregistered", "expires": null, "graceEnds": null}
```

Codes: `tldNotConfigured`, `notFullyQualified`, `unregistered`, `reserved`,
`grace`, `expired`, `noResolver`, `badAddress`, `badOffset`,
`noRegistrarConfigured`, `unauthorized`, `noSuchRoute`, `upstreamError`. For a name whose registration
is the problem, the code equals `status`.

### Status codes

| Status | Meaning |
|---|---|
| 200 | resolved; `status` is `registered` |
| 400 | TLD not configured, or not a fully-qualified name |
| 404 | never registered (`unregistered`), or registered with no resolver set (`noResolver`) |
| 410 | registration has lapsed — `status` says whether it is still renewable |
| 401 | `Authorization` missing or wrong, when a secret is configured |
| 502 | upstream RPC error / reth not synced |

### `GET /owned-by/<address>`

Every name an Ethereum address holds, across every configured TLD.

```jsonc
{
  "address": "0x69a6…",
  "names": [
    {"name": "foobar.testing", "tld": "testing", "labelhash": "0x…",
     "expires": 1780000000, "graceEnds": 1787776000, "status": "registered"},
    {"name": "lapsed.testing", "tld": "testing", "labelhash": "0x…",
     "expires": 1750000000, "graceEnds": 1757776000, "status": "grace"}
  ],
  "truncated": false,
  "checkedTlds": ["testing"]
}
```

Read from the ERC-721 registrar (`balanceOf` → `tokenOfOwnerByIndex` →
`nameExpires` → `labelOf`), so it needs no log scan and includes names acquired
by transfer as well as by registration. `labelOf` is the plaintext label
recorded write-once at registration, so a token id turns back into a name
without an off-chain index; a token whose label was never recorded is returned
with `"name": null` and its `labelhash`, rather than being dropped.

**Lapsed names are listed, not filtered**, with the same `status` vocabulary as
`/resolve` — a wallet scanning a key is exactly the caller who needs to be told
a name has lapsed and can still be renewed. Filter on `status == "registered"`
for the live set only. Enumeration is deliberately not maintained on expiry (the
registrar documents this), which is why `status` rather than presence is the
thing to read.

`truncated` is `true` when an address holds more than `SNRC_MAX_OWNED` names
(default 256) in one TLD, so a caller can tell a short list from a complete one.
Requires `SNRC_REGISTRAR_<TLD>`; with none configured the endpoint answers 400
rather than an empty list.

### Configuring addresses

Two maps, both per TLD. The **registry** answers *who owns this node* and is
what `/resolve` reads; it defaults to mainnet `.testing`, with `.simplex` unset
until deployed. The **registrar** is the ERC-721 that can be asked the reverse
and when a name expires — it is what `/owned-by` and every expiry field are
read from. Without a registrar for a TLD, `/resolve` still works and reports
`"status": "unknown"`, and `/owned-by` answers 400. The **controller** holds `reservedNames`, and is what the `reserved` status is
read from; without one for a TLD, a reserved name reads as `unregistered`.

Note that the controller address is the **proxy**, not `SimplexControllerImpl`:
storage lives in the proxy, so the implementation answers nothing.
`deployments.mainnet.testing.json` records it under the ENS role name
`ETHRegistrarController` and `verification.mainnet.testing.json` names it
`SimplexControllerProxy` — the same address, and the one defaulted to here.

| Variable | Purpose |
|---|---|
| `SNRC_REGISTRY_<TLD>` | ENS registry; resolution |
| `SNRC_REGISTRAR_<TLD>` | ERC-721 registrar; `/owned-by`, expiry and status |
| `SNRC_CONTROLLER_<TLD>` | SimplexController; the `reserved` status |
| `SNRC_MAX_OWNED` | names per `/owned-by` page (default 256) |

Set them on the `resolver` service in `docker-compose.yml`, or as env vars for
the standalone script.

### Hardening

The script binds `127.0.0.1` by default; `docker-compose.yml` sets `0.0.0.0`
because it must listen on the container bridge, and publishes the port to host
loopback only. Anything beyond loopback wants `SNRC_AUTH_BEARER` (or
`SNRC_AUTH_BASIC`, `user:password`) — the header is compared in constant time,
and it is the header the smp-server's `HttpResolver` already sends. Unset means
no check.

`SNRC_CACHE_TTL` (default 15s) memoises `eth_call` by target and calldata, which
matters because one `/resolve` is 15 upstream calls and one `/owned-by` page can
be hundreds; set it to `0` to disable. `SNRC_MAX_RPC_BYTES` (default 2 MiB)
refuses an oversized JSON-RPC response rather than reading it.

`/health` reports the RPC URL and both address maps, so **do not expose it** —
a hosted RPC URL usually carries the provider key in its path. 502 bodies name
the exception type only, and the detail goes to the log, for the same reason.

`http.server` is a development server. This deployment is loopback-only and
that is the posture it is written for; anything public wants a real server in
front of it.

## Every case, and what comes back

Every input either endpoint can be given, and the exact answer. Written out
because the interesting cases are the ones that are hard to reach on purpose —
a name in its grace period, a token whose label predates label recording — and
a caller has to handle them without having seen one.

Timestamps are Unix seconds. `status`, `expires` and `graceEnds` are present on
every `/resolve` response that got as far as looking the name up — `null` where
not knowable — so a client can read them without checking for the key first.
The two 400s below are the exception: they fail on the request itself, before
any lookup, and carry none of the three.

### `GET /resolve/<name>`

| Situation | HTTP | `status` | Body |
|---|---|---|---|
| Live name with records | 200 | `registered` | full record; `expires` is when it ends, `graceEnds` when it would stop being renewable |
| Live name, no text records set | 200 | `registered` | full record; text fields `""`, link arrays `[]`, coin fields `null` |
| Live subname (`bar.foo.testing`) | 200 | `registered` | its own records, with the expiry of the 2LD `foo.testing` above it |
| Registered, resolver never set | 404 | `noResolver` | `expires`, `graceEnds`, `error` — held, but points nowhere |
| Lapsed, still in grace | 410 | `grace` | `expires` (when it lapsed), `graceEnds` (last moment its owner can renew) |
| Lapsed, past grace | 410 | `expired` | same fields; anyone may register it now |
| Never registered | 404 | `unregistered` | `expires` and `graceEnds` are `null` |
| Reserved for a brand | 404 | `reserved` | not registered and not registrable; overrides `unregistered` and `expired` |
| Queried by labelhash (`0x…64hex.testing`) | as the label | as the label | identical answer; the label is never sent |
| TLD has no registry configured | 400 | — | `error: tldNotConfigured`, plus `configuredTlds` |
| TLD has no *registrar* configured | 200 / 404 | `unknown` | resolves as it otherwise would; expiry cannot be read, so `expires` and `graceEnds` are `null` |
| Not fully qualified (`alice`) | 400 | — | `error` naming the expected form |
| RPC unreachable or node unsynced | 502 | — | `error: upstreamError`; the detail goes to the log, not the body |

A name in grace still has its records on chain — expiry is lazy — but the
resolver answers 410 rather than serving them, so a stale name cannot be
resolved by accident. Read `expires` from that response to say when it lapsed.

### `GET /owned-by/<address>`

Answers 200 with a `names` array in every case where the address is well formed
and a registrar is configured; the interesting variation is per entry.

| Situation | HTTP | Result |
|---|---|---|
| Address holds live names | 200 | one entry each, `status` `registered` |
| Address holds a name in grace | 200 | entry with `status` `grace` and `graceEnds` — the renewal reminder case |
| Address holds a name past grace | 200 | entry with `status` `expired`; still listed, because the holder is who needs to know |
| Address holds nothing | 200 | `names: []` — an answer, not an error |
| Token whose label was never recorded | 200 | entry with `"name": null` and its `labelhash`; the token is real, the name is not recoverable from chain state |
| Address holds more than `SNRC_MAX_OWNED` in a TLD | 200 | one page, `truncated: true` and `nextOffset` to resume from |
| Several TLDs configured | 200 | all of them merged, sorted by TLD then name; `checkedTlds` says which were asked |
| Malformed address | 400 | `error: badAddress`; no RPC call is made |
| Negative or non-numeric `?offset=` | 400 | `error: badOffset` |
| `?offset=` past the end | 200 | `names: []` and `nextOffset: null` |
| No registrar configured for any TLD | 400 | `error: noRegistrarConfigured`, `configuredTlds: []` — distinct from "holds nothing" |
| RPC unreachable or node unsynced | 502 | `error: upstreamError`; the detail goes to the log, not the body |

Names are **not** filtered by expiry. Enumeration on the registrar is
maintained on transfer, mint and burn but deliberately not on expiry, so a
lapsed name stays enumerable until someone re-registers it — and that is
exactly the name its holder needs to be told about. Filter on
`status == "registered"` for the live set.
