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

Edit `.env`. The defaults work as they are; change them only if you need to:

```sh
NETWORK=mainnet                                               # default
TRUSTED_NODE_URL=https://mainnet-checkpoint-sync.attestant.io # default
```

Everything else (NAT) already has a working default in `docker-compose.yml`.
Uncomment the hints in `.env` only if you need to change one.

## 2. Run

```sh
cd scripts/resolver
docker compose up -d
docker compose logs -f reth resolver
```

Compose starts the node before the resolver; `depends_on` takes care of that.

## 3. Wait for the node to sync

```sh
docker compose logs --tail=20 reth
```

This is the slow step: about a day on mainnet. Until reth has synced, the
resolver returns `502`.

## Verify

Run the three checks below once the stack is up. The ones that need chain data
pass only after the node has synced.

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

**Point your smp-server at it:** in its `[NAMES]` section set
`resolver_endpoint: http://127.0.0.1:8000` (no auth needed for loopback).

## Ports (all loopback unless noted)

| Service | Host | Purpose |
|---|---|---|
| reth JSON-RPC | `127.0.0.1:8545` | smp-server RPC |
| reth p2p | `:30303` tcp/udp | Ethereum sync (open on firewall) |
| nimbus p2p | `:9000` tcp/udp | beacon sync (open on firewall) |
| nimbus REST | `127.0.0.1:5052` | beacon API |
| **resolver** | `127.0.0.1:8000` | SNRC REST (`/v2/resolve`, `/resolve`, `/health`) |

## Caveats

- **All images track `:latest`** (reth, nimbus). Each `docker compose pull`
  brings upstream fixes, so re-run the checks above afterwards.
- All ports bind to loopback. Expose only what you put behind a TLS reverse
  proxy.

## Teardown

```sh
docker compose down       # stop, keep all state
docker compose down -v    # also wipe volumes → full re-sync
```

`down -v` wipes the chain data (full re-sync on the next `up`).

---

## Resolver API reference

You can also run the resolver (`snrc-resolve.py`, host `127.0.0.1:8000`) on its
own for local development, without Docker, using
[`uv`](https://docs.astral.sh/uv/):

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
  "status": "registered",      // registered | grace | expired | unregistered | unknown
  "expires": 1780000000,       // Unix seconds; when the registration ends
  "graceEnds": 1787776000,     // expires + GRACE_PERIOD; last moment the owner can renew
  "reasonCode": null,          // set when the name is held back as well
  "reason": null               // set when the name is held back as well
}
```

`simplexContact` and `simplexChannel` are arrays, because a name can advertise
several SMP servers; clients try them in order. On chain each one is a single
text record with the entries joined by `;`. The resolver splits that record,
trims each entry and drops the empty ones. Addresses come back in each chain's
usual format (EIP-55, bech32, SS58, Monero base58). Subnames work the same way
(`bar.foobar.testing`).

### Registration status and expiry

A response carries `status`, `expires` and `graceEnds` whenever the resolver
read them, a successful resolve included, so a client that has just resolved a
name already knows when it expires. Both timestamps are Unix seconds, and
`null` when they could not be read.

| `status` | Meaning |
|---|---|
| `registered` | live; `expires` is when that ends |
| `grace` | lapsed, but only the previous owner may renew it, until `graceEnds` |
| `expired` | lapsed and past grace; anyone may register it |
| `unregistered` | never registered, and free to take |
| `unknown` | no `SNRC_REGISTRAR_<TLD>` configured, so status could not be read |

A reservation is orthogonal to the status: a name held back by the registry
carries `reasonCode` and `reason` whether or not it is registered.

`grace` and `expired` are told apart by the registrar's own `available(id)`
rule, `expires + GRACE_PERIOD < now`. `GRACE_PERIOD` is read from the contract
rather than assumed, and `now` is the latest block's timestamp rather than the
host clock, which the registrar compares against too, so a machine with a wrong
clock cannot misreport a registration. That rule alone is not enough: it also
holds for a name nobody ever registered (`0 + GRACE_PERIOD < now`), so a zero
expiry is what separates *never registered* from *registered and since
released*.

A subname reports the status of the 2LD above it, which is only as good as the
name it sits under.

### What a name costs

The controller's `prices()` names the price oracle, so no extra configuration is
needed beyond `SNRC_CONTROLLER_<TLD>`. A `SimplexPriceOracle` exposes its curve
through `prices()`, in US cents per year, which is the unit this API carries.

An ENS-shaped oracle exposes only `price1Letter()`..`price6Letter()`, in attoUSD
per second, and charges a premium on a lapsed name that it does not expose. A
quote from one is therefore only safe for a name that was never registered: an
`expired` name gets no price rather than one below what the registrar charges.

Deployment constants - the grace period, the oracle and its curve - are cached
for `CONSTANTS_TTL` (5 minutes), so a retune shows up within that. Per-name
values are read on every query.

**Set `SNRC_CONTROLLER_<TLD>` wherever `SNRC_REGISTRAR_<TLD>` is.** Without a
controller there is no oracle, so no name can be priced.

### Why a name is reserved

A held-back name carries `reasonCode`, the controller's reason, and `reason`, an
English sentence for a human reading this API. Clients should branch on
`reasonCode` and word it themselves, in the user's language.

| `reasonCode` | Meaning |
|---|---|
| `internal` | reserved for SimpleX |
| `trademark` | reserved to protect a trademark |
| `community` | reserved for the community |
| `unknown` | a reason added to the contract after this resolver; still reserved |

These are `SimplexController.Reason`, where 0 means not reserved. A controller
from before the enum stores a boolean, whose `true` decodes as 1, which is why
1 reads as `internal`, so nothing needs migrating.

### Querying by labelhash

A client asking whether a name is free is usually about to register it, and
whoever runs the resolver could register it first. To avoid that, send the
keccak hash of the label in ENS's `[<64 hex>]` form instead of the label:

```sh
# instead of /resolve/acme.testing
curl -s "http://127.0.0.1:8000/resolve/[$(printf acme | keccak-256sum | cut -d' ' -f1)].testing"
```

namehash is `keccak(parent || keccak(label))`, so this reaches the same node and
returns the same record. The registrar keys `nameExpires` and `reservedNames` on
the labelhash too, so the status fields do not need the label either. The
resolver learns the name only by guessing the label and hashing it.

Only the second-level label is a registry key, and it is decoded wherever it
sits: `sub.[<hash>].testing` reaches the node `sub.name.testing` does. Subname
labels stay text; a bracket label left of the 2LD is an ordinary label. Routers
from v22 send every 2LD this way, so a registrable name normally never reaches
this service.

Read the answer from `status`. A name is free on `unregistered` (404) and on
`expired` (410). Every other status means somebody holds the name. A `reasonCode`
means the registry will refuse it whatever the status says.

The hash must be keccak-256. `openssl dgst -sha3-256` and `sha3sum` compute
SHA3-256, a different function that returns 64 valid-looking hex characters
pointing at the wrong node.

The resolver lowercases the query before matching, so uppercase hex works too.
Clients that refuse raw brackets in a path can percent-encode them as `%5B` and
`%5D`.

Brackets cannot collide with a real name: they are invalid in a normalised ENS
name, and a `[<64 hex>]` label is 66 bytes against the registrar's
`maxLabelLength` of 63. A plain `0x…` label is not treated as a hash, since that
is an ordinary, registrable name.

Only 2LDs can be queried this way, as only a 2LD can be raced for: subnames are
created by the 2LD's owner. A bracket label in a subname is hashed as written,
so it points at a node nobody can own. ENS tooling accepts the bracketed form at
any depth; this resolver does not, on purpose.

This hides interest in a name and nothing else: the registration itself is
public, and commit-reveal covers that step. A short or well-known label is easy
to guess by hashing candidates, and the reveal publishes the labelhash, so an
operator who logged the query can match it to the name afterwards.

### Errors

Every non-2xx body carries two fields: `error` is a fixed code to branch on,
and `message` is a sentence for a human. Match on `error`, never on `message`,
which is free to change.

```jsonc
{"name": "nope.testing", "error": "unregistered",
 "message": "this name has never been registered",
 "status": "unregistered", "expires": null, "graceEnds": null}
```

The codes are `tldNotConfigured`, `notFullyQualified`, `unregistered`,
`expired`, `noSuchRoute` and `upstreamError`. When the registration is what went
wrong, `error` and `status` hold the same value, so one field is enough to read.

`upstreamError` says only which exception type the RPC call raised. The text
goes to the resolver's log instead, because `SNRC_RPC` can carry a provider key
and urlopen puts the URL it failed on into the message. It is also the answer
when a registrar, controller or oracle address has no contract behind it: the
empty reply is refused rather than read as zero, which would make every name
look free.

### Status codes

| Status | Meaning |
|---|---|
| 200 | resolved (`status` is `registered` or `grace`, or `unknown` when no registrar is configured) |
| 400 | TLD not configured, or not a fully-qualified name |
| 404 | `unregistered` |
| 410 | `expired`: lapsed and past grace, so anyone may take it |
| 502 | upstream RPC error / reth not synced |

### Configuring addresses

The resolver reads three contracts, each configured per TLD.

The **registry** answers who owns a node, and `/resolve` reads the records from
it. The **registrar** (ERC-721) holds `nameExpires` and `GRACE_PERIOD`, which
is where every expiry field comes from. With no registrar for a TLD, `/resolve`
still works and reports `"status": "unknown"`. The **controller** holds
`reservedNames`, which is where `reasonCode` comes from. With no controller a
held-back name reads as not reserved, and no name can be priced.

All three default to the mainnet `.testing` deployment. `.simplex` is unset
until it is deployed.

The controller default is the **proxy**, not `SimplexControllerImpl`. Storage
lives in the proxy, so the implementation address answers nothing. The two
deployment files use different names for that proxy:
`deployments.mainnet.testing.json` records it under the ENS role name
`ETHRegistrarController`, and `verification.mainnet.testing.json` calls it
`SimplexControllerProxy`. Both are the same address, and it is the one used
here.

To override any of them, set `SNRC_REGISTRY_<TLD>`, `SNRC_REGISTRAR_<TLD>` or
`SNRC_CONTROLLER_<TLD>` on the `resolver` service in `docker-compose.yml`, or
as env vars when you run the script directly.