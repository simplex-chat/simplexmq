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
  "owner": "0xd83b…", "resolver": "0x80fa…"
}
```

`simplexContact`/`simplexChannel` are arrays (a name can advertise multiple SMP
servers; clients try them in order). On-chain they're a single comma-separated
text record; the resolver splits/trims/drops-empties. Address encodings are
canonical per chain (EIP-55 / bech32 / SS58 / Monero-base58). Subnames work
identically (`bar.foobar.testing`).

### Status codes

| Status | Meaning |
|---|---|
| 200 | resolved |
| 400 | TLD not configured, or not a fully-qualified name |
| 404 | name has no resolver set on the registry |
| 502 | upstream RPC error / reth not synced |

### Configuring registries

Defaults to mainnet `.testing` (`0x03f438…`); `.simplex` is unset until
deployed. Override per TLD via env on the `resolver` service in
`docker-compose.yml` (`SNRC_REGISTRY_TESTING` / `SNRC_REGISTRY_SIMPLEX`), or as
env vars for the standalone script.
