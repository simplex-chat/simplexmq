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
| **resolver** | `127.0.0.1:8000` | SNRC REST (`/resolve`, `/health`) |

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
  "status": "registered",      // registered | grace | auction | expired | unregistered | reserved | noResolver | unknown
  "expires": 1780000000,       // Unix seconds; when the registration ends
  "graceEnds": 1787776000,     // expires + GRACE_PERIOD; last moment the owner can renew
  "auctionEnds": null,         // when the premium reaches zero; only on `auction`
  "premium": null,             // decimal string, attoUSD; only on `auction`
  "reasonCode": null,          // only on `reserved`
  "reason": null               // only on `reserved`
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
| `auction` | past grace, so anyone may register it — but at a premium, until `auctionEnds` |
| `expired` | lapsed, past grace, and past the auction — anyone may register it at the ordinary price |
| `unregistered` | never registered, and free to take |
| `reserved` | not registered, and held back — registration will be refused; the body carries `reasonCode` and `reason` |
| `noResolver` | registered, but points nowhere |
| `unknown` | no `SNRC_REGISTRAR_<TLD>` configured, so status could not be read |

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

### The post-grace auction

When grace ends the registrar will sell the name to anyone, but the price
oracle adds a premium that halves each day until it reaches zero. A name in
that window reports `auction` rather than `expired`, with `premium` (a decimal
string of attoUSD, because the value is a 256-bit integer that no JSON number
can hold) and `auctionEnds`.

The premium depends only on when the registration lapsed, never on the label,
so it is answerable for a labelhash query too. The base price is not: it depends
on the label's length, which a hashed query does not carry. `premium` is
therefore the surcharge alone, and a client that knows its own name adds the
base price itself.

The oracle is found through the controller's `prices()`, so no extra
configuration is needed. Its window is read from the chain rather than assumed,
because the owner can retune it; a window of zero days switches the auction off,
and every lapsed name then reports `expired` directly. The curve
(`startPremium`, `totalDays`, `endValue`) is cached for `AUCTION_PARAMS_TTL`
seconds, 5 minutes by default, since it changes only when the owner calls
`setPremium`; the decaying premium itself is read from the oracle on every
query. A retune is therefore visible within the TTL, not immediately.

**Known gap.** When the auction cannot be read at all — no controller
configured, or the oracle unreachable — the name reports `expired`, which routers
map to "available at the ordinary price". A name still inside its auction would
then be quoted at list price while the registrar charges the premium. Configure
`SNRC_CONTROLLER_<TLD>` wherever `SNRC_REGISTRAR_<TLD>` is set, and upgrade this
service before the routers that query it.

Upgrade the resolver before the router that queries it. A resolver without this
status reports a name in its auction as plain `expired`, which reads as "free at
the ordinary price" — the price the registrar actually charges is still the
premium one, so the quote is wrong until the resolver is current.

### Why a name is reserved

`reserved` carries both `reasonCode`, the controller's own reservation reason,
and `reason`, an English sentence for a human reading the REST API. Clients
should branch on `reasonCode` and word it themselves, so the wording follows the
user's language rather than the server's.

| `reasonCode` | Meaning |
|---|---|
| `unspecified` | reserved, with no reason recorded on chain |
| `trademark` | reserved to protect a trademark |
| `publicInterest` | reserved in the public interest |
| `offensive` | reserved as an offensive name |
| `internal` | reserved for SimpleX |
| `premium` | reserved as a premium name |

A controller deployed before reservation reasons existed stores a plain boolean,
whose `true` reads back as `unspecified`, so nothing needs migrating. A code
this resolver does not know also reads as `unspecified` — the name stays
reserved either way.

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

Only the second-level label is a registry key, so only it is decoded — but it is
decoded wherever it sits, so `sub.[<hash>].testing` reaches the node
`sub.name.testing` does. Subname labels are needed as text to walk down to the
record and are never hashed; a bracket label to the left of the 2LD is an
ordinary label and is hashed as written. SMP routers from v22 send every 2LD
this way, so in normal operation a registrable name never reaches this service.

Read the answer from `status`. A name is free when the body says
`unregistered` (a 404), and also when it says `expired` or `auction` (a 410) —
though `auction` costs a premium on top. Every other status means somebody holds
the name or the registry holds it back. Watch out for `noResolver`: it is also a
404, but the name is taken.

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
`reserved`, `grace`, `auction`, `expired`, `noResolver`, `noSuchRoute` and
`upstreamError`. When the registration is what went wrong, `error` and `status`
hold the same value, so one field is enough to read.

`upstreamError` says only which exception type the RPC call raised. The text
goes to the resolver's log instead, because `SNRC_RPC` can carry a provider key
and urlopen puts the URL it failed on into the message.

### Status codes

| Status | Meaning |
|---|---|
| 200 | resolved (`status` is `registered`, or `unknown` when no registrar is configured) |
| 400 | TLD not configured, or not a fully-qualified name |
| 404 | `unregistered`, `reserved` or `noResolver` — the `status` field says which |
| 410 | registration lapsed — `status` says whether the owner can still renew (`grace`), anyone may take it at a premium (`auction`), or anyone may take it at the ordinary price (`expired`) |
| 502 | upstream RPC error / reth not synced |

### Configuring addresses

The resolver reads three contracts, each configured per TLD.

The **registry** answers who owns a node, and `/resolve` reads the records from
it. The **registrar** (ERC-721) holds `nameExpires` and `GRACE_PERIOD`, which
is where every expiry field comes from. With no registrar for a TLD, `/resolve`
still works and reports `"status": "unknown"`. The **controller** holds
`reservedNames`, which is where the `reserved` status comes from. With no
controller, a reserved name reads as `unregistered`.

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