# Self-hosted SNRC stack

One `docker compose up` runs the self-hosted SimpleX Namespace (SNRC) backend
against **Ethereum mainnet** (where the `.testing` contracts live):

| # | Component | What it does |
|---|---|---|
| 1 | **reth (full) + nimbus** | self-hosted Ethereum node (full, so it keeps the logs/receipts the subgraph needs) |
| 2 | **resolver** | the REST resolver the smp-server's `[NAMES]` role queries (`snrc-resolve.py`) |
| 3 | **subgraph** | graph-node + IPFS + Postgres — auto-built, auto-deployed, rainbow table seeded; exposes a GraphQL endpoint |

The subgraph is cloned at runtime from the **private** repo
`brenzi/simplex-namespace-contract` (submodule `ens-subgraph`) using a GitHub
token — nothing is pre-vendored.

> If you only need SimpleX name resolution, the resolver (component 2) is
> enough. The subgraph (component 3) is for rich GraphQL queries — "list names
> owned by address X", human labels — consumed by a name-manager UI or your own
> queries. It shares the one reth node, so running the whole stack is simplest.

## Requirements

- **Docker** + Compose v2.
- **GitHub token** with **read** access to `brenzi/simplex-namespace-contract`
  and its `simplex-chat/ens-subgraph` submodule (only that submodule is cloned).
  Fine-grained PAT with read contents, or a classic PAT with `repo` scope.
- **≥ 1.2 TB NVMe SSD** for `reth --full` (TLC, not QLC — QLC stalls during
  sync) + **32 GB RAM**, fast multi-core CPU.
- **~1 day** for the initial reth sync. The resolver and subgraph return errors
  / stay behind until reth has caught up — that's expected.
- Firewall: open p2p ports `30303` (tcp/udp) and `9000` (tcp/udp).

## 1. Configure

Edit `.env` — only three values are required:

```sh
GITHUB_TOKEN=ghp_...                                          # required
NETWORK=mainnet                                               # default
TRUSTED_NODE_URL=https://mainnet-checkpoint-sync.attestant.io # default
```

Everything else (Postgres password, NAT) has a working default baked into
`docker-compose.yml`; uncomment the hints in `.env` only to override.

## 2. Run

```sh
cd scripts/resolver
docker compose up -d
docker compose logs -f reth subgraph-deploy
```

`depends_on` handles ordering automatically (clone source → start node → seed
rainbow table → deploy subgraph). Seeding before deploy matters: graph-node
heals ENS label hashes at index time, so the rainbow table must be populated
before indexing starts. The subgraph finishes indexing only once reth is synced.

## 3. Wait for the node to sync

```sh
docker compose logs --tail=20 reth
```

This is the long pole (~1 day on mainnet). Until reth is synced the resolver
returns `502` and the subgraph stays behind chain head.

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
curl -s http://127.0.0.1:8088/health | jq
# → {"ok": true, "rpc": "http://reth:8545", "registries": {"testing": "0x…", "simplex": ""}}
```

**3. resolver resolves a live name** (`foobar.testing` is a populated test name):
```sh
curl -s http://127.0.0.1:8088/resolve/foobar.testing | jq
# → {"name":"foobar.testing","nickname":"Foo","simplexContact":["https://smp16.simplex.im/a#…"], … }
```

**4. subgraph has caught up:**
```sh
curl -s -X POST http://127.0.0.1:8030/graphql \
  -H 'content-type: application/json' \
  -d '{"query":"{ indexingStatusForCurrentVersion(subgraphName:\"graphprotocol/ens\"){ synced chains{ latestBlock{number} chainHeadBlock{number} } } }"}' | jq
# synced: true  ⇒ caught up to chain head
```

**5. subgraph returns indexed names:**
```sh
curl -s -X POST http://127.0.0.1:8000/subgraphs/name/graphprotocol/ens \
  -H 'content-type: application/json' \
  -d '{"query":"{ registrations(first:5){ labelName expiryDate } }"}' | jq
```

**Wire your smp-server:** in its `[NAMES]` section set
`resolver_endpoint: http://127.0.0.1:8088` (no auth needed for loopback).

## Ports (all loopback unless noted)

| Service | Host | Purpose |
|---|---|---|
| reth JSON-RPC | `127.0.0.1:8545` | smp-server RPC |
| reth p2p | `:30303` tcp/udp | Ethereum sync (open on firewall) |
| nimbus p2p | `:9000` tcp/udp | beacon sync (open on firewall) |
| nimbus REST | `127.0.0.1:5052` | beacon API |
| **resolver** | `127.0.0.1:8088` | SNRC REST (`/resolve`, `/health`) |
| graph-node GraphQL | `127.0.0.1:8000` | subgraph queries |
| graph-node status | `127.0.0.1:8030` | indexing status |
| graph-node admin/WS/metrics | `127.0.0.1:8020/8001/8040` | internal |
| IPFS | `127.0.0.1:5001` | subgraph manifest store |

> The resolver is on **8088**, not 8000 — host 8000 belongs to graph-node's
> GraphQL.

## Caveats

- **reth keeps the subgraph's data.** The compose uses `reth download --full
  --resumable` (snapshot) and `reth node --full` — both confirmed present in
  the pinned image (`reth --help` lists `download`, `node --help` lists
  `--full`). `--full` retains logs/receipts back past block **25,250,870**
  (where the subgraph indexes from), so don't add receipt/log pruning.
- **All images track `:latest`** (reth, nimbus, graph-node, ipfs, postgres:18) —
  you get upstream fixes on each `docker compose pull`; re-run the verify checks
  after pulling. The rainbow-table seed (`init/rainbow-seed.sh`) is required for
  graph-node ≥ 0.30 (incl. latest), so latest is covered.
- **Change `POSTGRES_PASSWORD`** (default `let-me-in`) for non-local use. All
  ports bind to loopback; expose only what you put behind a TLS reverse proxy.

## Teardown

```sh
docker compose down       # stop, keep all state
docker compose down -v    # also wipe volumes → full re-sync + re-seed
```

`down -v` wipes the chain data (1.2 TB re-sync) and the Postgres volume (the
rainbow-table seed is lost; `rainbow-seed` re-seeds it idempotently on the
next `up`).

---

## Resolver API reference

The resolver (`snrc-resolve.py`, container `:8000` → host `:8088`) is also
runnable standalone for local dev (no Docker), via [`uv`](https://docs.astral.sh/uv/):

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
