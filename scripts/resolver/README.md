# Ethereum stack for SMP names role

Reth (execution) + Nimbus (consensus) on Holesky testnet by default.

## Quickstart

```sh
cd scripts/docker/reth-nimbus
docker compose up -d
docker compose logs -f reth nimbus
```

Sync takes a few hours on Holesky, ~1 day on mainnet. When synced:

```sh
curl -s -X POST http://127.0.0.1:8545 \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'
```

Point smp-server: `[NAMES] ethereum_endpoint: http://127.0.0.1:8545`.

## How the trust bootstrap works

- **Reth** holds Ethereum state and runs the EVM. It does not decide which fork is canonical.
- **Nimbus** follows the beacon chain and tells Reth which payloads to execute.
- Nimbus needs **one trusted starting point** to break the chicken-and-egg of peer-claims. `--trusted-node-url` fetches that checkpoint once from a public beacon API; from that point on every block is verified locally against the validator set.
- The default `TRUSTED_NODE_URL` is publicnode.com (no API key, no rate limits). Replace with any beacon API you trust — only consulted once on first sync.

## Switching to mainnet

Edit `.env`:

```
NETWORK=mainnet
TRUSTED_NODE_URL=https://ethereum-beacon-api.publicnode.com
```

Then `docker compose down -v && docker compose up -d` (the `-v` wipes state so Nimbus re-bootstraps against the new network). Reth on mainnet needs ~260 GB pruned NVMe.

## Notes

- Reth's RPC is bound to `127.0.0.1:8545` only. For remote access (multiple smp-server hosts → one Reth), put Caddy + Let's Encrypt + Basic auth in front — see `plans/20260522_01_smp_public_namespaces.md` §"Operator deployment".
- Ports 30303/9000 are p2p — open on your firewall for sync.
- `jwt.hex` is generated on first run by the `jwt-init` service and shared between Reth and Nimbus via the `jwt` volume.
- To wipe state and re-sync: `docker compose down -v`.

## SNRC resolver REST API (`snrc-resolve.py`)

The companion script `snrc-resolve.py` exposes the SimpleX Namespace
Registry (SNRC) over a small JSON HTTP API. It talks to the same local
Reth + Nimbus stack described above (set `NETWORK=mainnet` in `.env`),
reading the SNRC contracts directly on Ethereum mainnet.

Dependencies are declared inline (PEP 723) at the top of `snrc-resolve.py`
and in a sibling `pyproject.toml`. The simplest local run uses
[`uv`](https://docs.astral.sh/uv/):

```sh
uv run scripts/resolver/snrc-resolve.py
```

`uv` resolves and caches `eth-hash[pycryptodome]` on first run. No
virtualenv juggling, no `--break-system-packages`. If you'd rather
manage Python deps yourself:

```sh
pip install 'eth-hash[pycryptodome]>=0.7'
python scripts/resolver/snrc-resolve.py
```

### Deployed registries

| TLD        | Network          | ENSRegistry address                          |
|------------|------------------|----------------------------------------------|
| `.testing` | Ethereum mainnet | `0x03f438da0bd44da3c6c1d0392f8ba183b8b3a7a6` |
| `.simplex` | — (not deployed) | —                                            |

Each TLD is an independent ENS-shaped deployment with its own
`ENSRegistry`. The resolver dispatches by the queried name's rightmost
label, so a single instance can serve both TLDs concurrently once
`.simplex` launches.

### Running

With Reth bound to `127.0.0.1:8545` (the default Quickstart layout
above), no env vars are required — the script defaults to that RPC and
to the mainnet `.testing` registry:

```sh
./scripts/resolver/snrc-resolve.py
```

Output on startup:

```
snrc-resolve listening on 0.0.0.0:8000
  RPC = http://127.0.0.1:8545
  Registries:
    .testing  = 0x03f438da0bd44da3c6c1d0392f8ba183b8b3a7a6
    .simplex  = (not configured)
  GET /resolve/<name>   GET /health
```

Override the listen port or bind address with `SNRC_PORT` / `SNRC_BIND`.

### Running in Docker

The compose file ships a `resolver` service alongside reth and nimbus.
`docker compose up -d` builds the image from `Dockerfile` (multi-stage,
non-root, `uv`-based) and exposes the API on `127.0.0.1:8000`:

```sh
docker compose up -d resolver
docker compose logs -f resolver
curl -s http://127.0.0.1:8000/health
```

The container points `SNRC_RPC` at `http://reth:8545` (the compose-internal
DNS name) so the resolver and reth share the bridge network without
exposing reth's RPC to the host beyond loopback.

To change the host-side port, edit the LEFT side of the port mapping in
`docker-compose.yml`:

```yaml
resolver:
  ports:
    - "127.0.0.1:8000:8000"   # host:container
```

The registry address defaults to mainnet `.testing` — to override (Holesky,
a private deployment, or future `.simplex`), uncomment and set the values
in `docker-compose.yml` under the resolver service's `environment:` block.

The image declares a `HEALTHCHECK` against `/health`; `docker compose ps`
will mark the service `(healthy)` once reth is queryable.

### Resolving a name

`foobar.testing` is registered on mainnet with every text and
multicoin record populated (useful as a smoke-test target):

```sh
curl -s http://127.0.0.1:8000/resolve/foobar.testing | jq .
```

```json
{
  "name": "foobar.testing",
  "nickname": "Foo",
  "website": "https://foo.bar",
  "location": "",
  "simplexContact": [
    "https://smp16.simplex.im/a#Q_F00BA7",
    "https://smp11.simplex.im/a#Q_F00BA8"
  ],
  "simplexChannel": [],
  "eth": null,
  "btc": "bc1qpzht4wp64yg7z6sgl07vvrnepyux740juynfcn",
  "xmr": "4ANzdVJFxLtCKcBgNGkFSEA41zJFgrTX93LWt9UR6xpg7YNCsdrSV817cw2xKT8NXeS5euBBqTApS2u8kRTxMhyiDGN3Qgt",
  "dot": "139GgyEsXDyGLhmhBTPmDmGCyTvTVuLad3YjHax2PWLK6p3s",
  "owner": "0xd83bb610fbad567fb5d8755ec162881e46d1fbc9",
  "resolver": "0x80fa1903e70af03e79c73fb7feae2fb33aebae01"
}
```

`simplexContact` and `simplexChannel` are arrays so a name can advertise
multiple SMP servers for redundancy. Clients SHOULD try the URLs in
order; the first entry is the primary and the rest are fallbacks. The
on-chain text record stores them as a single comma-separated string
(`"url1,url2,url3"`); this resolver splits, trims whitespace, and drops
empty entries before returning.

All field names are lowercase-initial and contain no dots, so they map
directly onto Haskell record fields and can be consumed via aeson's
`Generic`-derived `FromJSON` without a key-rewriting layer. Equivalent
Haskell record:

```haskell
data SnrcRecord = SnrcRecord
  { name           :: Text
  , nickname       :: Text
  , website        :: Text
  , location       :: Text
  , simplexContact :: [Text]
  , simplexChannel :: [Text]
  , eth            :: Maybe Text
  , btc            :: Maybe Text
  , xmr            :: Maybe Text
  , dot            :: Maybe Text
  , owner          :: Text
  , resolver       :: Text
  } deriving (Generic, FromJSON)
```

(The on-chain text-record keys still use the ENSIP-5 dot convention —
`simplex.contact` and `simplex.channel`. Only the resolver's JSON
surface camelCases them.)

Address encoding matches each chain's canonical user-facing form:
EIP-55 mixed-case for `eth`, bech32/bech32m for `btc` segwit/taproot
(base58check for legacy P2PKH/P2SH), SS58 with Polkadot prefix 0 for
`dot`, Monero-base58 for `xmr`. Unrecognised payloads fall back to
`0x`-prefixed hex.

#### Subnames

Subnames work exactly the same. try `bar.foobar.testing`.

```sh
curl -s http://127.0.0.1:8000/health
# → {"ok": true, "rpc": "http://127.0.0.1:8545", "registries": {"testing": "0x…", "simplex": ""}}
```

### Pointing at multiple deployments

Once `.simplex` deploys, point a single resolver instance at both
registries — requests are dispatched by the rightmost label:

```sh
SNRC_REGISTRY_SIMPLEX=0x...mainnet-simplex-ENSRegistry... \
  ./scripts/resolver/snrc-resolve.py
```

Queries for a TLD with no registry configured return HTTP 400 with the
list of supported TLDs.

### Error responses

| Status | When                                                                  |
|--------|-----------------------------------------------------------------------|
| 400    | TLD not configured (`/resolve/foo.simplex` while `.simplex` is empty) or path not a fully-qualified name |
| 404    | Name has no resolver set on the registry (`ENSRegistry.resolver(node)` is zero) |
| 502    | Upstream RPC error / unreachable (Reth not running or not synced)     |
