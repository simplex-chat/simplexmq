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

**Wire your smp-server:** in its `[NAMES]` section set
`resolver_endpoint: http://127.0.0.1:8000` (no auth needed for loopback).

## Ports (all loopback unless noted)

| Service | Host | Purpose |
|---|---|---|
| reth JSON-RPC | `127.0.0.1:8545` | smp-server RPC |
| reth p2p | `:30303` tcp/udp | Ethereum sync (open on firewall) |
| nimbus p2p | `:9000` tcp/udp | beacon sync (open on firewall) |
| nimbus REST | `127.0.0.1:5052` | beacon API |
| **resolver** | `127.0.0.1:8000` | SNRC REST (`/resolve`, `/health`) |

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
  "status": "registered",      // registered | grace | expired | unregistered | reserved | noResolver | unknown
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

`status`, `expires` and `graceEnds` are on every response that got far enough
to know them, including a successful resolve — so a client that has just
resolved a name already holds its expiry and needs no second request to warn
about it. `expires` and `graceEnds` are Unix timestamps in seconds; both are
`null` when unknown.

| `status` | Meaning |
|---|---|
| `registered` | live; `expires` is when that ends |
| `grace` | lapsed, but only the previous owner may renew it, until `graceEnds` |
| `expired` | lapsed and past grace — anyone may register it now |
| `unregistered` | never registered, and free to take |
| `reserved` | not registered, and held back — registration will be refused; the body carries a `reason` |
| `noResolver` | registered, but points nowhere |
| `unknown` | no `SNRC_REGISTRAR_<TLD>` configured, so status could not be read |

The split between `grace` and `expired` mirrors the registrar's own
`available(id)` rule (`expires + GRACE_PERIOD < now`), with `GRACE_PERIOD` read
from the contract rather than assumed. Note that `available(id)` alone cannot
distinguish these: it is also true for a name nobody ever registered, since
`0 + GRACE_PERIOD < now`. A zero expiry is what separates *never taken* from
*taken and since released*.

Subnames report the status of the 2LD they sit under, which is the useful
answer — a subname is only as valid as the name above it.

### Querying by labelhash

A client that asks whether a name is free is usually about to register it.
Whoever runs the resolver sees that question and could register the name first.
To avoid that, send the keccak hash of the label instead of the label itself,
written in ENS's `[<64 hex>]` form. The answer is the same:

```sh
# instead of /resolve/acme.testing
curl -s "http://127.0.0.1:8000/resolve/[$(printf acme | keccak-256sum | cut -d' ' -f1)].testing"
```

This works because namehash is `keccak(parent || keccak(label))`. Passing
`keccak(label)` gives the same node, so the resolver reads the same record —
and the registrar also keys `nameExpires` and `reservedNames` on the labelhash,
so availability needs the label no more than the record does. It learns which
name you meant only if it guesses the label and hashes it.

Read the answer by `status`: a name is free exactly when the body says
`unregistered` (a 404). Every other answer is a name somebody holds or held
recently — note that `noResolver` is also a 404, and it is a taken name.

Two practical notes. The hash must be keccak-256: `openssl dgst -sha3-256` and
`sha3sum` compute SHA3-256, a different function, and produce 64 well-formed
hex of nothing you meant. And queries are lowercased before matching, so
uppercase hex works too; strict HTTP stacks that reject raw brackets in a path
can percent-encode them (`%5B`/`%5D`) — both forms load the same name.

Brackets keep the two forms from colliding. `[` and `]` are not valid in a
normalised ENS name, and the dApp normalises before it registers, so no name
registered through it can look like this. Nothing on chain checks the character
set, but a `[<64 hex>]` label is 66 bytes and the registrar's `maxLabelLength`
is 63, so it cannot be registered directly either. ENS uses this same encoding
for a label whose preimage it does not know. A plain `0x…` label would not work
here, because that is an ordinary name anyone can register.

Only 2LDs can be queried by hash. A 2LD is what a registration buys, so it is
the only name worth hiding. Subnames are left out because nobody can race you
for one: the owner of the 2LD creates them. In a subname the resolver hashes a
`[<64 hex>]` label as written instead of decoding it, so such a query points at
a node nobody can own. (ENS tooling reads the bracketed form at any depth; this
resolver deliberately does not.)

This hides your interest in a name, and nothing more. The registration itself
is public, and the controller's commit-reveal protects that step. Guessing
stays cheap — for a short or brand-like label the hash is a speed bump, not
secrecy — and once the reveal makes the labelhash public, an operator who
logged the probe can link the two.

### Status codes

| Status | Meaning |
|---|---|
| 200 | resolved (`status` is `registered`, or `unknown` when no registrar is configured) |
| 400 | TLD not configured, or not a fully-qualified name |
| 404 | `unregistered`, `reserved` or `noResolver` — the `status` field says which |
| 410 | registration lapsed — `status` says whether the owner can still renew (`grace`) or anyone may take it (`expired`) |
| 502 | upstream RPC error / reth not synced |

### Configuring addresses

Three maps, all per TLD. The **registry** answers *who owns this node* and is
what `/resolve` reads records from. The **registrar** (ERC-721) holds
`nameExpires` / `GRACE_PERIOD`, and is what every expiry field is read from —
without one for a TLD, `/resolve` still works and reports `"status": "unknown"`.
The **controller** holds `reservedNames`, and is what the `reserved` status is
read from; without one a reserved name reads as `unregistered`.

All three default to the mainnet `.testing` deployment; `.simplex` is unset
until deployed. Note that the controller default is the **proxy**, not
`SimplexControllerImpl`: storage lives in the proxy, so the implementation
answers nothing. `deployments.mainnet.testing.json` records it under the ENS
role name `ETHRegistrarController` and `verification.mainnet.testing.json`
names it `SimplexControllerProxy` — the same address, and the one defaulted to
here.

Override per TLD via env on the `resolver` service in `docker-compose.yml`
(`SNRC_REGISTRY_<TLD>` / `SNRC_REGISTRAR_<TLD>` / `SNRC_CONTROLLER_<TLD>`), or
as env vars for the standalone script.
