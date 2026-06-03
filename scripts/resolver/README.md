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
Registry (SNRC) over a small JSON HTTP API. Same dependency surface as
`ens-lookup.py`:

```sh
pip install --break-system-packages 'eth-hash[pycryptodome]'
```

### Pointing at a Sepolia RPC

The SNRC `.testing` TLD currently lives on Sepolia (registry
`0x2f97af21ca3eb3f5311f439c05234ca94163bc33`). Pick an RPC, then run the
script:

```sh
# Option A — public RPC, no setup
SNRC_RPC=https://ethereum-sepolia-rpc.publicnode.com \
  ./scripts/resolver/snrc-resolve.py

# Option B — local Reth synced to Sepolia (set NETWORK=sepolia in .env first,
# then `docker compose up -d` and wait for sync). RPC defaults already match.
./scripts/resolver/snrc-resolve.py
```

Listens on `0.0.0.0:8000`. Override with `SNRC_PORT` / `SNRC_BIND`.

### Resolving a name

Use `foobar.testing` — a name registered on Sepolia with every field
populated for end-to-end testing (text records + multicoin addresses
across ETH/BTC/DOT/XMR):

```sh
curl -s http://127.0.0.1:8000/resolve/foobar.testing | jq .
```

```json
{
  "name": "foobar.testing",
  "nickname": "mynickname",
  "website": "https://foobar.com",
  "location": "alpha centauri",
  "simplex.contact": "https://smp16.simplex.im/a#Q_f00bar",
  "simplex.channel": "https://smp16.simplex.im/c#wsonsavos",
  "ETH": "0xC14ccEc78342e3DAf136E6C36025b397C377614e",
  "BTC": "bc1qpzht4wp64yg7z6sgl07vvrnepyux740juynfcn",
  "XMR": "46PS3HXYoH3VcGsneFCyHkfSygkp8p1hHHAMb3ePP8BuPdqSbsTcPiuH7xDmVudaq8W24EryzRYDS5Whz7ZQu8NqEpHtHQx",
  "DOT": "16P39egDdQgZjAAhGP1pUs6ik23RgBXwohNh93GH6Qmk4W9q",
  "owner": "0xc14ccec78342e3daf136e6c36025b397c377614e",
  "resolver": "0xb35a2f76379437638426acb4d9a45546acbf4f5c"
}
```

Address encoding matches each chain's canonical user-facing form:
EIP-55 mixed-case for ETH, bech32/bech32m for BTC segwit/taproot
(base58check for legacy P2PKH/P2SH), SS58 with Polkadot prefix 0 for
DOT, Monero-base58 for XMR. Unrecognised payloads fall back to
`0x`-prefixed hex.

### Health check

```sh
curl -s http://127.0.0.1:8000/health
# → {"ok": true, "rpc": "...", "registry": "..."}
```

### Switching to a different SNRC deployment

`.simplex` (mainnet) and any future deployment use the same script with
a different registry address:

```sh
SNRC_RPC=https://ethereum-rpc.publicnode.com \
SNRC_REGISTRY=0x...mainnet-ENSRegistry... \
  ./scripts/resolver/snrc-resolve.py
```
